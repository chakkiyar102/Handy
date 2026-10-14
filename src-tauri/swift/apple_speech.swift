import AVFoundation
import Dispatch
import Foundation
import Speech

// MARK: - Apple SpeechAnalyzer bridge (macOS 26+)
// Compiled via the Cargo build script for Apple Silicon targets. Every entry
// point is synchronous for the C caller: async work runs in a Task and the
// calling (non-main) Rust thread waits on a semaphore.

private typealias ResponsePointer = UnsafeMutablePointer<AppleSpeechResponse>

// DictationTranscriber, not SpeechTranscriber: it is tuned for short
// push-to-talk utterances and formats punctuation like system dictation.
@available(macOS 26.0, *)
private typealias Transcriber = DictationTranscriber

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

private struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func blocking<T>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.value = .success(try await work())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private func makeResponse(_ result: Result<String, Error>) -> ResponsePointer {
    let ptr = ResponsePointer.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResponse(text: nil, success: 0, error_message: nil))
    switch result {
    case .success(let text):
        ptr.pointee.text = strdup(text)
        ptr.pointee.success = 1
    case .failure(let error):
        ptr.pointee.error_message = strdup(error.localizedDescription)
    }
    return ptr
}

@available(macOS 26.0, *)
private func baseCode(_ locale: Locale) -> String? {
    locale.language.languageCode?.identifier
}

/// Map a Handy language code to a supported transcriber locale. A bare code
/// ("en") prefers the user's own region (en-IN for an Indian system locale),
/// then whatever the framework considers equivalent. `supportedLocale(equivalentTo:)`
/// can return locales the transcriber does not actually support (e.g. "hi" ->
/// hi-IN on SpeechTranscriber), so every candidate is checked against
/// `supportedLocales`.
@available(macOS 26.0, *)
private func resolveLocale(_ code: String) async -> Locale? {
    let current = Locale.current
    let wanted = (code.isEmpty || code == "auto") ? (baseCode(current) ?? "en") : code
    let supported = await Transcriber.supportedLocales
    let bcp47 = { (l: Locale) in l.identifier(.bcp47).lowercased() }
    let lookup = { (id: String) in supported.first(where: { bcp47($0) == id.lowercased() }) }

    let requested = Locale(identifier: wanted)
    var candidates = [requested.identifier(.bcp47)]
    if !(wanted.contains("-") || wanted.contains("_")), let region = current.region?.identifier {
        candidates.insert("\(wanted)-\(region)", at: 0)
    }
    // It can also hop languages ("yue" -> zh-HK), so only take same-language picks.
    if let equivalent = await Transcriber.supportedLocale(equivalentTo: requested),
        baseCode(equivalent) == baseCode(requested)
    {
        candidates.append(equivalent.identifier(.bcp47))
    }
    for id in candidates {
        if let match = lookup(id) {
            return match
        }
    }
    return supported.first(where: { baseCode($0) == baseCode(requested) })
}

/// Install the locale's assets if needed. Installing reserves the locale, and
/// only `maximumReservedLocales` (5 on an M1) may be reserved at once, so on
/// failure release the oldest other reservation and retry once.
@available(macOS 26.0, *)
private func ensureAssets(_ transcriber: Transcriber, locale: Locale) async throws {
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed:
        return
    case .unsupported:
        throw BridgeError(message: "Apple Speech does not support \(locale.identifier(.bcp47))")
    default:
        break
    }
    let install = {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
    do {
        try await install()
    } catch {
        let reserved = await AssetInventory.reservedLocales
        guard reserved.count >= AssetInventory.maximumReservedLocales,
            let oldest = reserved.first(where: { $0 != locale })
        else { throw error }
        _ = await AssetInventory.release(reservedLocale: oldest)
        try await install()
    }
}

@available(macOS 26.0, *)
private func prepareTranscriber(
    _ code: String,
    reporting: Set<Transcriber.ReportingOption> = [.frequentFinalization]
) async throws -> Transcriber {
    guard let locale = await resolveLocale(code) else {
        throw BridgeError(message: "Apple Speech does not support language '\(code)'")
    }
    // .shortDictation plus frequentFinalization: same text, but results come
    // back final instead of as a lone volatile result.
    let transcriber = Transcriber(
        locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
        reportingOptions: reporting, attributeOptions: [])
    try await ensureAssets(transcriber, locale: locale)
    return transcriber
}

@available(macOS 26.0, *)
private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if buffer.format == format {
        return buffer
    }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
        throw BridgeError(message: "Cannot convert audio to \(format)")
    }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        throw BridgeError(message: "Failed to allocate converted audio buffer")
    }
    var consumed = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if consumed {
            inputStatus.pointee = .endOfStream
            return nil
        }
        consumed = true
        inputStatus.pointee = .haveData
        return buffer
    }
    if status == .error {
        throw conversionError ?? BridgeError(message: "Audio conversion failed")
    }
    return output
}

@available(macOS 26.0, *)
private func transcribe(
    _ samples: [Float], sampleRate: Double, code: String, contextWords: [String]
) async throws -> String {
    let transcriber = try await prepareTranscriber(code)

    guard
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
            interleaved: false),
        let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else {
        throw BridgeError(message: "Failed to allocate audio buffer")
    }
    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }

    let targetFormat =
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? inputFormat
    let buffer = try convert(input, to: targetFormat)

    // Undocumented: short-form dictation can end on a volatile result that is
    // never promoted to final, so keep the trailing volatile text too.
    let collector = Task {
        var finalized = ""
        var pending = ""
        for try await result in transcriber.results {
            if result.isFinal {
                finalized += String(result.text.characters)
                pending = ""
            } else {
                pending = String(result.text.characters)
            }
        }
        return finalized + pending
    }

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    continuation.yield(AnalyzerInput(buffer: buffer))
    continuation.finish()

    let analyzer = makeAnalyzer(transcriber)
    do {
        try await prime(analyzer, format: targetFormat, contextWords: contextWords)
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        collector.cancel()
        throw error
    }
    let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    return finishSentence(text, locale: transcriber.selectedLocales.first)
}

/// Dictation drops the final full stop when an utterance ends without a strong
/// sentence cue. Add one to the final text if it ends mid-word and reads like a
/// sentence. Languages with their own (or no) sentence terminator are left alone.
// ponytail: naive heuristic (>= 4 words, ends in a letter/digit); tune the
// threshold or the language list if it misfires on short commands.
@available(macOS 26.0, *)
private func finishSentence(_ text: String, locale: Locale?) -> String {
    let skipped: Set<String> = ["zh", "yue", "ja", "th", "hi"]
    guard let last = text.last, last.isLetter || last.isNumber,
        text.split(whereSeparator: \.isWhitespace).count >= 4,
        !skipped.contains(locale.flatMap(baseCode) ?? "")
    else { return text }
    return text + "."
}

/// A fresh analyzer per utterance: reused ones carry context across utterances
/// and finished ones fail silently. `.lingering` keeps the model in memory
/// between calls, so setup stays ~50-130 ms.
@available(macOS 26.0, *)
private func makeAnalyzer(_ transcriber: Transcriber) -> SpeechAnalyzer {
    SpeechAnalyzer(
        modules: [transcriber],
        options: .init(priority: .userInitiated, modelRetention: .lingering))
}

@available(macOS 26.0, *)
private func prime(_ analyzer: SpeechAnalyzer, format: AVAudioFormat, contextWords: [String])
    async throws
{
    try await analyzer.prepareToAnalyze(in: format)
    // Biases recognition toward the user's custom words (DictationTranscriber
    // only; Apple caps it at ~100 short phrases).
    if !contextWords.isEmpty {
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(contextWords.prefix(100))
        try await analyzer.setContext(context)
    }
}

// MARK: - Live streaming

/// One push-to-talk utterance streamed frame by frame. Results are pushed to
/// the C callback as (committed, tentative) text; no callback fires after
/// `finish` or `cancel` returns.
@available(macOS 26.0, *)
private final class StreamSession: @unchecked Sendable {
    let analyzer: SpeechAnalyzer
    let locale: Locale?
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let inputFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    var collector: Task<String, Error>!

    init(
        analyzer: SpeechAnalyzer, locale: Locale?,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        inputFormat: AVAudioFormat, targetFormat: AVAudioFormat
    ) {
        self.analyzer = analyzer
        self.locale = locale
        self.continuation = continuation
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
    }

    func feed(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0,
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        input.floatChannelData![0].update(from: base, count: samples.count)
        if let buffer = try? convert(input, to: targetFormat) {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }
}

public typealias AppleSpeechTextCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafePointer<CChar>
) -> Void

@available(macOS 26.0, *)
private func startStream(
    code: String, contextWords: [String], callback: AppleSpeechTextCallback,
    user: UnsafeMutableRawPointer?
) async throws -> StreamSession {
    let transcriber = try await prepareTranscriber(
        code, reporting: [.volatileResults, .frequentFinalization])
    guard
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    else { throw BridgeError(message: "Failed to create audio format") }
    let targetFormat =
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? inputFormat

    let analyzer = makeAnalyzer(transcriber)
    try await prime(analyzer, format: targetFormat, contextWords: contextWords)

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let session = StreamSession(
        analyzer: analyzer, locale: transcriber.selectedLocales.first,
        continuation: continuation, inputFormat: inputFormat, targetFormat: targetFormat)
    // Dictation volatiles are cumulative within a segment, so committed is the
    // finals so far and tentative the latest volatile.
    session.collector = Task {
        var finalized = ""
        var pending = ""
        for try await result in transcriber.results {
            if result.isFinal {
                finalized += String(result.text.characters)
                pending = ""
            } else {
                pending = String(result.text.characters)
            }
            finalized.withCString { c in pending.withCString { t in callback(user, c, t) } }
        }
        return finalized + pending
    }
    try await analyzer.start(inputSequence: stream)
    return session
}

// MARK: - C entry points

@_cdecl("apple_speech_is_available")
public func appleSpeechIsAvailable() -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    return 1
}

@_cdecl("apple_speech_supported_languages")
public func appleSpeechSupportedLanguages() -> UnsafeMutablePointer<CChar>? {
    guard #available(macOS 26.0, *) else { return strdup("") }
    let result = blocking {
        var seen = Set<String>()
        return await Transcriber.supportedLocales
            .compactMap { baseCode($0) }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
    return strdup((try? result.get())?.joined(separator: ",") ?? "")
}

@_cdecl("apple_speech_prepare")
public func appleSpeechPrepare(_ language: UnsafePointer<CChar>) -> UnsafeMutablePointer<AppleSpeechResponse> {
    let code = String(cString: language)
    guard #available(macOS 26.0, *) else {
        return makeResponse(.failure(BridgeError(message: "Apple Speech requires macOS 26 or later")))
    }
    return makeResponse(blocking {
        let transcriber = try await prepareTranscriber(code)
        return transcriber.selectedLocales.first?.identifier(.bcp47) ?? code
    })
}

@_cdecl("apple_speech_transcribe")
public func appleSpeechTranscribe(
    _ samples: UnsafePointer<Float>?,
    _ count: Int,
    _ sampleRate: Int32,
    _ language: UnsafePointer<CChar>,
    _ contextWords: UnsafePointer<CChar>
) -> UnsafeMutablePointer<AppleSpeechResponse> {
    let code = String(cString: language)
    let words = String(cString: contextWords).split(separator: "\n").map(String.init)
    guard #available(macOS 26.0, *) else {
        return makeResponse(.failure(BridgeError(message: "Apple Speech requires macOS 26 or later")))
    }
    guard let samples, count > 0 else {
        return makeResponse(.success(""))
    }
    let copy = Array(UnsafeBufferPointer(start: samples, count: count))
    return makeResponse(blocking {
        try await transcribe(copy, sampleRate: Double(sampleRate), code: code, contextWords: words)
    })
}

@_cdecl("apple_speech_stream_start")
public func appleSpeechStreamStart(
    _ language: UnsafePointer<CChar>,
    _ contextWords: UnsafePointer<CChar>,
    _ callback: AppleSpeechTextCallback,
    _ user: UnsafeMutableRawPointer?,
    _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutableRawPointer? {
    let code = String(cString: language)
    let words = String(cString: contextWords).split(separator: "\n").map(String.init)
    guard #available(macOS 26.0, *) else {
        errorOut.pointee = strdup("Apple Speech requires macOS 26 or later")
        return nil
    }
    // The raw pointer only crosses into the Task; Rust keeps it alive until
    // finish/cancel returns.
    let userBits = Int(bitPattern: user)
    switch blocking({
        try await startStream(
            code: code, contextWords: words, callback: callback,
            user: UnsafeMutableRawPointer(bitPattern: userBits))
    }) {
    case .success(let session):
        return Unmanaged.passRetained(session).toOpaque()
    case .failure(let error):
        errorOut.pointee = strdup(error.localizedDescription)
        return nil
    }
}

@_cdecl("apple_speech_stream_feed")
public func appleSpeechStreamFeed(
    _ session: UnsafeMutableRawPointer, _ samples: UnsafePointer<Float>?, _ count: Int
) {
    guard #available(macOS 26.0, *), let samples else { return }
    let session = Unmanaged<StreamSession>.fromOpaque(session).takeUnretainedValue()
    session.feed(UnsafeBufferPointer(start: samples, count: count))
}

@_cdecl("apple_speech_stream_finish")
public func appleSpeechStreamFinish(_ session: UnsafeMutableRawPointer)
    -> UnsafeMutablePointer<AppleSpeechResponse>
{
    guard #available(macOS 26.0, *) else {
        return makeResponse(.failure(BridgeError(message: "Apple Speech requires macOS 26 or later")))
    }
    let session = Unmanaged<StreamSession>.fromOpaque(session).takeRetainedValue()
    return makeResponse(blocking {
        session.continuation.finish()
        do {
            try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            session.collector.cancel()
            throw error
        }
        let text = try await session.collector.value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return finishSentence(text, locale: session.locale)
    })
}

@_cdecl("apple_speech_stream_cancel")
public func appleSpeechStreamCancel(_ session: UnsafeMutableRawPointer) {
    guard #available(macOS 26.0, *) else { return }
    let session = Unmanaged<StreamSession>.fromOpaque(session).takeRetainedValue()
    _ = blocking {
        session.continuation.finish()
        await session.analyzer.cancelAndFinishNow()
        // Wait out the collector so no callback can fire after we return.
        _ = try? await session.collector.value
    }
}

@_cdecl("apple_speech_free_response")
public func appleSpeechFreeResponse(_ response: UnsafeMutablePointer<AppleSpeechResponse>?) {
    guard let response else { return }
    free(response.pointee.text)
    free(response.pointee.error_message)
    response.deallocate()
}

@_cdecl("apple_speech_free_string")
public func appleSpeechFreeString(_ value: UnsafeMutablePointer<CChar>?) {
    free(value)
}
