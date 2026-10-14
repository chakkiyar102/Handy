#ifndef apple_speech_bridge_h
#define apple_speech_bridge_h

#include <stddef.h>

// C-compatible declarations for the Apple SpeechAnalyzer (macOS 26+) bridge

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char* text;          // Only valid when success = 1
    int success;         // 0 for failure, 1 for success
    char* error_message; // Only valid when success = 0
} AppleSpeechResponse;

// 1 when SpeechAnalyzer/SpeechTranscriber can run on this device, else 0
int apple_speech_is_available(void);

// Comma-separated base language codes the transcriber supports ("en,fr,...").
// Free with apple_speech_free_string.
char* apple_speech_supported_languages(void);

// Resolve `language` to a locale and make sure its on-device assets are
// installed (downloads them on first use). `text` holds the resolved locale.
AppleSpeechResponse* apple_speech_prepare(const char* language);

// Transcribe mono float samples in [-1, 1] at `sample_rate`. Blocks until done.
// `context_words` is a newline-separated list of custom words to bias toward.
AppleSpeechResponse* apple_speech_transcribe(const float* samples, size_t count, int sample_rate, const char* language, const char* context_words);

// Live streaming. `callback` receives (user, committed, tentative) on a
// background thread for every result; it never fires after finish/cancel
// returns. start returns NULL and sets *error_out (free with
// apple_speech_free_string) on failure. finish and cancel free the session.
typedef void (*AppleSpeechTextCallback)(void* user, const char* committed, const char* tentative);
void* apple_speech_stream_start(const char* language, const char* context_words, AppleSpeechTextCallback callback, void* user, char** error_out);
void apple_speech_stream_feed(void* session, const float* samples, size_t count);
AppleSpeechResponse* apple_speech_stream_finish(void* session);
void apple_speech_stream_cancel(void* session);

void apple_speech_free_response(AppleSpeechResponse* response);
void apple_speech_free_string(char* value);

#ifdef __cplusplus
}
#endif

#endif /* apple_speech_bridge_h */
