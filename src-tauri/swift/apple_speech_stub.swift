import Foundation

// Stub implementation when the SDK predates SpeechAnalyzer (macOS 26).
// Compiled via the Cargo build script; reports the engine as unavailable.

@_cdecl("apple_speech_is_available")
public func appleSpeechIsAvailable() -> Int32 {
    return 0
}

@_cdecl("apple_speech_supported_languages")
public func appleSpeechSupportedLanguages() -> UnsafeMutablePointer<CChar>? {
    return strdup("")
}

private func unavailable() -> UnsafeMutablePointer<AppleSpeechResponse> {
    let ptr = UnsafeMutablePointer<AppleSpeechResponse>.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResponse(text: nil, success: 0, error_message: nil))
    ptr.pointee.error_message = strdup(
        "Apple Speech is not available in this build (SDK requirement not met).")
    return ptr
}

@_cdecl("apple_speech_prepare")
public func appleSpeechPrepare(_ language: UnsafePointer<CChar>) -> UnsafeMutablePointer<AppleSpeechResponse> {
    return unavailable()
}

@_cdecl("apple_speech_transcribe")
public func appleSpeechTranscribe(
    _ samples: UnsafePointer<Float>?,
    _ count: Int,
    _ sampleRate: Int32,
    _ language: UnsafePointer<CChar>,
    _ contextWords: UnsafePointer<CChar>
) -> UnsafeMutablePointer<AppleSpeechResponse> {
    return unavailable()
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
