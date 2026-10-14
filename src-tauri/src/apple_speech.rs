//! Apple SpeechAnalyzer (macOS 26+) on-device transcription via the Swift
//! bridge in `swift/apple_speech.swift`. Every call blocks the calling thread.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

#[repr(C)]
struct AppleSpeechResponse {
    text: *mut c_char,
    success: c_int,
    error_message: *mut c_char,
}

extern "C" {
    fn apple_speech_is_available() -> c_int;
    fn apple_speech_supported_languages() -> *mut c_char;
    fn apple_speech_prepare(language: *const c_char) -> *mut AppleSpeechResponse;
    fn apple_speech_transcribe(
        samples: *const f32,
        count: usize,
        sample_rate: c_int,
        language: *const c_char,
    ) -> *mut AppleSpeechResponse;
    fn apple_speech_free_response(response: *mut AppleSpeechResponse);
    fn apple_speech_free_string(value: *mut c_char);
}

pub fn is_available() -> bool {
    unsafe { apple_speech_is_available() == 1 }
}

/// Base language codes ("en", "fr", …) the on-device transcriber supports.
pub fn supported_languages() -> Vec<String> {
    let ptr = unsafe { apple_speech_supported_languages() };
    if ptr.is_null() {
        return Vec::new();
    }
    let list = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    unsafe { apple_speech_free_string(ptr) };
    list.split(',')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

fn take_response(ptr: *mut AppleSpeechResponse) -> Result<String, String> {
    if ptr.is_null() {
        return Err("Null response from Apple Speech".to_string());
    }
    let response = unsafe { &*ptr };
    let read = |p: *mut c_char| {
        (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    };
    let result = if response.success == 1 {
        Ok(read(response.text).unwrap_or_default())
    } else {
        Err(read(response.error_message).unwrap_or_else(|| "Unknown error".to_string()))
    };
    unsafe { apple_speech_free_response(ptr) };
    result
}

/// Make sure the on-device assets for `language` are installed, downloading
/// them on first use. Returns the resolved locale (e.g. "en-IN").
pub fn prepare(language: &str) -> Result<String, String> {
    let language = CString::new(language).map_err(|e| e.to_string())?;
    take_response(unsafe { apple_speech_prepare(language.as_ptr()) })
}

/// Transcribe 16 kHz mono samples.
pub fn transcribe(audio: &[f32], language: &str) -> Result<String, String> {
    let language = CString::new(language).map_err(|e| e.to_string())?;
    take_response(unsafe {
        apple_speech_transcribe(audio.as_ptr(), audio.len(), 16_000, language.as_ptr())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the real FFI + link path. Skips on machines without the engine.
    #[test]
    fn silence_round_trips_through_bridge() {
        if !is_available() {
            return;
        }
        assert!(supported_languages().iter().any(|l| l == "en"));
        assert_eq!(transcribe(&vec![0.0; 16_000], "en").unwrap(), "");
    }
}
