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
/// then whatever the framework considers equivalent.
@available(macOS 26.0, *)
private func resolveLocale(_ code: String) async -> Locale? {
    let current = Locale.current
    let wanted = (code.isEmpty || code == "auto") ? (baseCode(current) ?? "en") : code
    let supported = await Transcriber.supportedLocales
    let bcp47 = { (l: Locale) in l.identifier(.bcp47).lowercased() }

    if wanted.contains("-") || wanted.contains("_") {
        let requested = Locale(identifier: wanted)
        if let match = supported.first(where: { bcp47($0) == bcp47(requested) }) {
            return match
        }
        return await Transcriber.supportedLocale(equivalentTo: requested)
    }

    if let region = current.region?.identifier {
        let regional = "\(wanted)-\(region)".lowercased()
        if let match = supported.first(where: { bcp47($0) == regional }) {
            return match
        }
    }
    if let match = await Transcriber.supportedLocale(equivalentTo: Locale(identifier: wanted)) {
        return match
    }
    return supported.first(where: { baseCode($0) == wanted })
}

@available(macOS 26.0, *)
private func prepareTranscriber(_ code: String) async throws -> Transcriber {
    guard let locale = await resolveLocale(code) else {
        throw BridgeError(message: "Apple Speech does not support language '\(code)'")
    }
    let transcriber = Transcriber(locale: locale, preset: .shortDictation)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
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
private func transcribe(_ samples: [Float], sampleRate: Double, code: String) async throws -> String {
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

    // Short dictation presets can end on a volatile result that is never
    // promoted to final, so keep the trailing volatile text too.
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

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    do {
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        collector.cancel()
        throw error
    }
    return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
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
    _ language: UnsafePointer<CChar>
) -> UnsafeMutablePointer<AppleSpeechResponse> {
    let code = String(cString: language)
    guard #available(macOS 26.0, *) else {
        return makeResponse(.failure(BridgeError(message: "Apple Speech requires macOS 26 or later")))
    }
    guard let samples, count > 0 else {
        return makeResponse(.success(""))
    }
    let copy = Array(UnsafeBufferPointer(start: samples, count: count))
    return makeResponse(blocking {
        try await transcribe(copy, sampleRate: Double(sampleRate), code: code)
    })
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
