//! Apple SpeechAnalyzer (macOS 26+) on-device transcription via the Swift
//! bridge in `swift/apple_speech.swift`. Every call blocks the calling thread.

use std::ffi::{c_void, CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

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
        context_words: *const c_char,
    ) -> *mut AppleSpeechResponse;
    fn apple_speech_stream_start(
        language: *const c_char,
        context_words: *const c_char,
        callback: extern "C" fn(*mut c_void, *const c_char, *const c_char),
        user: *mut c_void,
        error_out: *mut *mut c_char,
    ) -> *mut c_void;
    fn apple_speech_stream_feed(session: *mut c_void, samples: *const f32, count: usize);
    fn apple_speech_stream_finish(session: *mut c_void) -> *mut AppleSpeechResponse;
    fn apple_speech_stream_cancel(session: *mut c_void);
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

/// Transcribe 16 kHz mono samples, biasing recognition toward `custom_words`.
pub fn transcribe(
    audio: &[f32],
    language: &str,
    custom_words: &[String],
) -> Result<String, String> {
    let language = CString::new(language).map_err(|e| e.to_string())?;
    let words = CString::new(custom_words.join("\n")).map_err(|e| e.to_string())?;
    take_response(unsafe {
        apple_speech_transcribe(
            audio.as_ptr(),
            audio.len(),
            16_000,
            language.as_ptr(),
            words.as_ptr(),
        )
    })
}

type TextCallback = Box<dyn Fn(&str, &str) + Send + Sync>;

extern "C" fn on_text(user: *mut c_void, committed: *const c_char, tentative: *const c_char) {
    // Never unwind across the FFI boundary.
    let _ = std::panic::catch_unwind(|| {
        let callback = unsafe { &*(user as *const TextCallback) };
        let committed = unsafe { CStr::from_ptr(committed) }.to_string_lossy();
        let tentative = unsafe { CStr::from_ptr(tentative) }.to_string_lossy();
        callback(&committed, &tentative);
    });
}

/// A live transcription of one utterance. `on_text(committed, tentative)` runs
/// on a background thread for every result. Dropping without `finish` cancels.
pub struct Stream {
    session: *mut c_void,
    callback: *mut TextCallback,
}

// The Swift session is internally synchronized; feed/finish only ever come
// from the single stream worker thread that owns this handle.
unsafe impl Send for Stream {}

impl Stream {
    pub fn start(
        language: &str,
        custom_words: &[String],
        on_text_cb: impl Fn(&str, &str) + Send + Sync + 'static,
    ) -> Result<Self, String> {
        let language = CString::new(language).map_err(|e| e.to_string())?;
        let words = CString::new(custom_words.join("\n")).map_err(|e| e.to_string())?;
        let callback: *mut TextCallback = Box::into_raw(Box::new(Box::new(on_text_cb)));
        let mut error: *mut c_char = ptr::null_mut();
        let session = unsafe {
            apple_speech_stream_start(
                language.as_ptr(),
                words.as_ptr(),
                on_text,
                callback as *mut c_void,
                &mut error,
            )
        };
        if session.is_null() {
            drop(unsafe { Box::from_raw(callback) });
            let message = if error.is_null() {
                "Unknown error".to_string()
            } else {
                let message = unsafe { CStr::from_ptr(error) }
                    .to_string_lossy()
                    .into_owned();
                unsafe { apple_speech_free_string(error) };
                message
            };
            return Err(message);
        }
        Ok(Self { session, callback })
    }

    /// Queue 16 kHz mono samples. Non-blocking.
    pub fn feed(&self, audio: &[f32]) {
        unsafe { apple_speech_stream_feed(self.session, audio.as_ptr(), audio.len()) }
    }

    /// Flush the stream and return the final text. Blocks until done.
    pub fn finish(mut self) -> Result<String, String> {
        let session = std::mem::replace(&mut self.session, ptr::null_mut());
        take_response(unsafe { apple_speech_stream_finish(session) })
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        if !self.session.is_null() {
            unsafe { apple_speech_stream_cancel(self.session) };
        }
        // finish/cancel guarantee no callback runs after they return.
        drop(unsafe { Box::from_raw(self.callback) });
    }
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
        assert_eq!(transcribe(&vec![0.0; 16_000], "en", &[]).unwrap(), "");

        let stream = Stream::start("en", &[], |_, _| {}).unwrap();
        stream.feed(&vec![0.0; 16_000]);
        assert_eq!(stream.finish().unwrap(), "");
        // Dropping an unfinished stream cancels it.
        drop(Stream::start("en", &[], |_, _| {}).unwrap());
    }
}
