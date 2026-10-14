# Apple SpeechAnalyzer engine: research notes

Scope: the macOS 26 `SpeechAnalyzer` engine (`src-tauri/swift/apple_speech.swift`, `src-tauri/src/apple_speech.rs`).
Test machine: Apple M1, macOS 26.5.2, Command Line Tools only (SDK 26.1, Speech module 3505.11.1), system locale `en_IN`.

Labels used below:
- **[verified]**: reproduced locally with throwaway harnesses (`scratchpad/research/h.swift`, `both.swift`). The audio is the macOS `say` voice, so it is synthetic, and every sample was a single run.
- **[doc]**: stated in Apple documentation or the SDK `.swiftinterface`.
- **[unverified]**: inference or a third-party claim I did not reproduce.

Apple's docs pages are rendered with JavaScript. The text quoted here came from the JSON behind them, for example `https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json`.

Heads-up **[verified]**: the current docs mention `AnalyzerInputConverter`, `CaptureInputSequenceProvider`, `AssetInputSequenceProvider` and `Options.ignoresResourceLimits`. None of these exist in the CLT 26.1 SDK interface, so the bridge can't use them until the SDK is updated.

---

## 1. SpeechTranscriber or DictationTranscriber, and which preset

**Recommendation:** Keep `DictationTranscriber`. Replace `.shortDictation` with a custom preset: `contentHints: [.shortForm]`, `transcriptionOptions: [.punctuation]`, `reportingOptions: [.frequentFinalization]`. That returns the same text with `isFinal == true`, so the "keep the trailing volatile" workaround becomes a fallback rather than the main path. If a missing final period matters, add a small post-process step. Don't run both transcribers on every call.

Evidence:
- **Presets decoded [verified]** (printed at runtime):
  - `phrase` = `[shortForm]`, no punctuation.
  - `shortDictation` = `[shortForm]` + `[punctuation]`, no reporting options.
  - `progressiveShortDictation` = `shortDictation` + `[volatileResults, frequentFinalization]`.
  - `longDictation` = no hints + `[punctuation]`.
  - `SpeechTranscriber.transcription` = all option sets empty. Punctuation is built in; `SpeechTranscriber` has no `.punctuation` option.
- **Non-final-only results [verified, undocumented]:** `shortDictation` (shortForm with no reporting options) returns one `isFinal=false` result. Three variants give byte-identical text with `isFinal=true`:
  - shortForm + `frequentFinalization`
  - no hints
  - `longDictation`
  - I found no Apple doc or forum post describing this. The WWDC sample's pattern (`finalizeAndFinishThroughEndOfInput()` finalizes volatile results) suggests it is a quirk. Keep the fallback that uses the trailing volatile text.
- **Quality on four clips [verified]:**

  | Clip | Dictation (any preset) | SpeechTranscriber `.transcription` |
  |---|---|---|
  | times / currency | "3:30 AM … ₹12,500" (no final period) | "330 AM, … 12,500 rupees." |
  | 3 sentences | correct punctuation, "I push" | correct, "I pushed" |
  | "Send the report to the team" | no period | period |
  | names (Kissflow, Dharsan, Tauri, ping) | "ki flow … paying person about to" | "Kiss Flow Tracker and ping Tarsan about Tauri." |

  Dictation leaves out the final period when the utterance ends without a strong sentence cue. The `[shortForm]` hint is not the cause: the no-hint variant behaves the same. Inside a reused analyzer, Dictation *did* add the period on the second and third utterances, so prior context drives it (see §2). `SpeechTranscriber` handled the names better in this sample, but `contextualStrings` closes much of that gap for Dictation (§6).
- **Getting both strengths [verified]:** One `SpeechAnalyzer(modules: [dictation, speech])` runs both transcribers on a single input. The best format is still 16 kHz Int16. It took about 0.28–0.52 s against about 0.18–0.39 s for Dictation alone, and you could take Dictation's text plus SpeechTranscriber's final punctuation. That is a lot of complexity for one character. A cheaper heuristic is to append "." when the Dictation output ends in a letter or digit and has at least about 4 words **[unverified quality]**.
- **[doc]** `DictationTranscriber`: "uses the same speech-to-text machine learning models as system dictation … compatible with older devices". It supports `contextualStrings` and custom language models. `SpeechTranscriber`: "appropriate for normal conversation and general purposes"; check `isAvailable`. WWDC25 session 277 positions Dictation as the fallback for languages and devices `SpeechTranscriber` doesn't cover ([video](https://developer.apple.com/videos/play/wwdc2025/277/)).
- **Prior art [verified by reading source]:** VoiceInk ([NativeAppleTranscriptionService.swift](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Infrastructure/Providers/Transcription/AppleSpeech/NativeAppleTranscriptionService.swift)) and FluidVoice ([AppleSpeechAnalyzerProvider.swift](https://github.com/altic-dev/FluidVoice/blob/main/Sources/Fluid/Services/AppleSpeechAnalyzerProvider.swift)) both use `SpeechTranscriber` with empty options and a fresh analyzer on every call. [KiroCrew StreamTranscribe.swift](https://github.com/kirodotdev/KiroCrew/blob/main/src/kiro_crew/apple_speech/StreamTranscribe.swift) lets you choose either transcriber, and uses Dictation with `[.punctuation]` on purpose, with no `etiquetteReplacements` because that option masks profanity.

## 2. Per-call setup cost and analyzer lifetime

**Recommendation:** Keep one new analyzer and transcriber per utterance. Reusing an analyzer mixes context between utterances and breaks `SpeechTranscriber`. Make two changes to cut latency:
- Create the analyzer with `SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)`.
- Call `prepareToAnalyze(in: Int16 16k)` when push-to-talk *starts*, so the warm-up overlaps the user's speech. The streaming design in §3 does this naturally.

Evidence:
- **Fresh per call vs reused [verified]:**
  - Fresh per call, warm, assets installed: 0.09–0.29 s for 1.5–5.5 s clips (Dictation).
  - One reused analyzer (`analyzeSequence` + `finalize(through:)` per utterance): 0.055–0.24 s.
  - `prepareToAnalyze` itself: about 0.05 s.
  - So setup costs roughly 50–130 ms per call. That is minor next to the about 8 s first-ever asset install.
- **Reuse side effects [verified]:**
  - In a reused Dictation analyzer, later utterances gained final periods: "₹12,500." and "Send the report to the team." Context carries over.
  - A reused `SpeechTranscriber` produced junk ("Thanks a lot.... The meeting … 12,500.....") and lost the third utterance entirely.
  - Separate push-to-talk clips are not one continuous stream, so don't reuse.
- **Lifetime pitfalls [verified]:**
  - After `finalizeAndFinishThroughEndOfInput()`, `analyzeSequence` on the same analyzer returns `nil`, and `start(inputSequence:)` returns without throwing. Neither one produces results. The analyzer fails *silently*, so you can't detect it through errors.
  - **[doc]** (SpeechAnalyzer "Finish analysis"): "Most methods won't do anything … the analyzer won't accept different input sequences or modules. Module result streams terminate."
  - **[doc]** "When the analyzer or its modules' result streams throw an error, the analysis session becomes finished."
  - **[doc]** "The analyzer can only analyze one input sequence at a time."
  - **[doc]** Ending your `AsyncStream` alone does *not* finish the session. Without a `finish*` call, the result streams never end, so the collector task hangs.
- **[doc]** Improve responsiveness: "call `prepareToAnalyze(in:)` after setting its modules … To delay or prevent unloading … select a ModelRetention option". The options are:
  - `whileInUse` (default): released when the analyzer is deallocated.
  - `lingering`: "keeps the models in memory for a time so that they can be reused by another compatible analyzer session".
  - `processLifetime`: keeps them until the process exits.

  `lingering` fits Handy's idle-unload philosophy. **[doc, WWDC]** The model runs outside the app's memory space.
- **[doc]** Transcriber instances "can share the same backing engine instances and models, so long as the transcribers are configured similarly." That makes a fresh transcriber per call cheap.

## 3. Streaming into Handy's live preview

**Recommendation:** Add an Apple branch in `run_stream_worker`. Use a stateful Swift session handle and a C callback that pushes `(committed, tentative)`. Use the `progressiveShortDictation` options, plus `contextualStrings`. **[verified]** Volatile text arrives per word in real time, and the final text lands about 0.08–0.11 s after the audio ends. That means near-zero latency after release, against about 0.2–0.4 s for batch.

Measured with real-time 100 ms chunks **[verified]**:
- Dictation volatiles are *cumulative* within a segment: "I", "I push the fix", … then one F with the whole text.
- `SpeechTranscriber.progressiveTranscription` finalizes each sentence ("F [I pushed the fix this morning.]", then a new volatile "Can you review…").
- In both cases, `committed = concat(finals)` and `tentative = latest volatile`. That maps one-to-one onto `StreamTextEvent { committed, tentative }`.
- KiroCrew reports that `volatileResults` *without* `frequentFinalization`/`fastResults` batches everything until the end. **[verified partly]** Here `progressiveLongDictation` (volatileResults only) still streamed live for Dictation. Keep `frequentFinalization` anyway.

How Handy streams today (`src-tauri/src/managers/transcription.rs`):
- `StreamRouter::feed` sends VAD-passed 16 kHz frames as `StreamCmd::Feed` to `run_stream_worker`.
- The worker bails out to `drain_until_finalize` when `self.engine.loaded()` is `None`. That always happens for `OnnxEngine::AppleSpeech`, so Apple gets no live preview today and falls back to batch.
- `finalize_stream` applies `post_process_transcription_text` (fuzzy custom words, fillers).

FFI shape. Swift owns a `final class Session` that holds the continuation, analyzer and collector task, passed to Rust as `Unmanaged` → `OpaquePointer`:

```c
typedef void (*apple_speech_text_cb)(void *user, const char *committed, const char *tentative);
void *apple_speech_stream_start(const char *lang, const char *context_words /* \n-joined */,
                                apple_speech_text_cb cb, void *user, char **error_out);
void  apple_speech_stream_feed(void *s, const float *pcm, size_t n);   // non-blocking
AppleSpeechResponse *apple_speech_stream_finish(void *s);              // blocking; frees s
void  apple_speech_stream_cancel(void *s);                             // cancelAndFinishNow; frees s
```

- `start`:
  - Resolve the locale (§5).
  - Build a `DictationTranscriber` with `[.shortForm]`, `[.punctuation]`, `[.volatileResults, .frequentFinalization]`.
  - Build the `AnalysisContext` (§6) and `SpeechAnalyzer(modules:, options: .init(priority: .userInitiated, modelRetention: .lingering))`.
  - `try await prepareToAnalyze(in:)`, then `setContext`, then `start(inputSequence: stream)`.
  - Spawn the collector task. On each result it updates `finalized`/`pending` and calls `cb(user, finalized, pending)`.
  - Block only until `start` returns, using the existing `blocking{}` helper. The setup is about 50 ms, and frames queue on the Rust channel in the meantime.
- `feed`:
  - Convert f32 to Int16 directly; same rate, so no `AVAudioConverter` is needed.
  - Then `continuation.yield(AnalyzerInput(buffer:))`. This is synchronous and does not block.
  - VAD has already removed silent gaps. Leaving `bufferStartTime` nil makes the timeline contiguous, which matches what batch sees.
- `finish`: `continuation.finish()`, then `finalizeAndFinishThroughEndOfInput()`, then await the collector and return `finalized + pending`. Keep the volatile fallback.
- **Callbacks vs polling:**
  - Use callbacks. Results arrive asynchronously on a Swift executor thread, and the preview needs them right away.
  - Polling would need another thread and a shared buffer.
  - In Rust, `user` is a `Box<Arc<dyn Fn(&str,&str) + Send + Sync>>` that wraps `emit_stream_text(&app_handle, …)` (plus `PreviewScript` if desired). It is freed after `finish`/`cancel` returns. The callback must not panic across FFI, so wrap it in `catch_unwind`.
- **Rust worker:**
  - In `run_stream_worker`, before the `self.engine.loaded()` check, look for `matches!(*self.lock_onnx(), Some(OnnxEngine::AppleSpeech))`. If it matches, run `run_apple_stream(rx, language, custom_words)`.
  - That function maps `Feed` → `feed`, `Finalize(reply)` → `finish` → `reply.send(Ok(Some(FinalizedStreamText{…})))`, and `Cancel` → `cancel`.
  - `finalize_stream` stays unchanged.
  - On a start error, `drain_until_finalize(rx)` falls back to batch.

## 4. Hand-written `@_cdecl` vs swift-rs / swift-bridge

**Recommendation:** Keep the hand-written `@_cdecl` bridge. It matches `apple_intelligence.swift`, builds with plain `swiftc` + `libtool` under Command Line Tools, and the API surface is small (5 functions today, about 4 more for streaming).

- **[verified]** CLT ships SwiftPM 6.2.1 (`swift build` works), so swift-rs, which builds a SwiftPM package, *would* build here. It would still add a `Package.swift` layout, a second Swift build path alongside `build.rs`'s `swiftc` invocations, and the CLT/SDK special-casing that `build.rs` already handles (`is_command_line_tools_only`).
- **[unverified]** Neither swift-rs nor swift-bridge removes the main difficulty: bridging Swift `async` and actors to a blocking or callback C ABI. You would still write the `Task` + semaphore code and the callback trampolines by hand.
- An off-the-shelf crate exists: [doom-fish/speech-rs](https://github.com/doom-fish/speech-rs). It provides SwiftPM-built `SpeechAnalyzer` bindings, but has 7 stars and is young. It's useful as a reference, but adopting it isn't worth it.

## 5. Locale handling

**Recommendation:** Resolve the locale in this order:
1. Exact BCP-47 match in `supportedLocales`.
2. `<lang>-<system region>` if it is supported.
3. `supportedLocale(equivalentTo:)`.

Then **re-check that the result is in `supportedLocales` and that `AssetInventory.status(forModules:) != .unsupported`**. The current bridge returns the `equivalentTo` result without checking it. Use `status(forModules:)` rather than `installedLocales` to decide whether a download is needed. On a reservation-limit error, release the oldest entry in `reservedLocales` and retry.

Evidence (all **[verified]** with `Locale.current = en_IN`):
- **Supported locales:**
  - `DictationTranscriber.supportedLocales` has **54** locales.
  - `SpeechTranscriber.supportedLocales` has **30**, a strict subset of Dictation's.
  - Dictation only: ar-SA ca-ES cs-CZ da-DK el-GR fi-FI he-IL hi-IN hr-HR hu-HU id-ID ms-MY nb-NO nl-BE nl-NL pl-PL ro-RO ru-RU sk-SK sv-SE th-TH tr-TR uk-UA vi-VN.
  - Shared: de-AT/CH/DE, en-AU/CA/GB/IE/IN/NZ/SG/US/ZA, es-CL/ES/MX/US, fr-BE/CA/CH/FR, it-CH/IT, ja-JP, ko-KR, pt-BR/PT, yue-CN, zh-CN/HK/TW.
  - Dictation base codes: ar ca cs da de el en es fi fr he hi hr hu id it ja ko ms nb nl pl pt ro ru sk sv th tr uk vi yue zh (33).
- **`supportedLocale(equivalentTo:)` results:**

  | Input | Dictation | SpeechTranscriber |
  |---|---|---|
  | en | en-IN | en-IN |
  | en-Latn-US | en-US | en-US |
  | hi | **hi-IN** | **hi-IN**, even though hi-IN is *not* in SpeechTranscriber's supported list and its status is `.unsupported` (bug) |
  | yue | **zh-HK** (not yue-CN) | **zh-HK** |
  | zh / zh-Hans | zh-CN | zh-CN |
  | pt | pt-PT | pt-PT |
  | es | es-US | es-US |
  | es-419 | es-CL | es-CL |
  | no / nb | nb-NO | nb-NO |
  | ta-IN, xx | nil | nil |

  **[doc]**: when there is no exact match, it returns "a supported (and by preference already-installed) locale that shares the same LanguageCode … This may result in an unexpected transcription, such as between 'color' and 'colour' … provide a way for the user to correct the locale." So bare "en" lands on en-IN partly because en-IN is installed, not only because of the system region. A user in the US with en-GB installed could get en-GB.
- **`installedLocales` is misleading [verified]:** `DictationTranscriber.installedLocales` lists en-US, but `AssetInventory.status` for a Dictation en-US module is `.supported` (not installed). `SpeechTranscriber.installedLocales` lists 9 en-* locales. Use `status(forModules:)`.
- **Reservations [verified]:** `AssetInventory.maximumReservedLocales = 5`, and `reservedLocales = [en-IN]`.
  - The bridge never calls `reserve`, so `assetInstallationRequest`/`downloadAndInstall` appears to reserve implicitly **[unverified inference]**.
  - **[doc]** `reserve(locale:)` throws "if the number of locales would exceed `maximumReservedLocales`". The limit "may vary between devices according to storage space".
  - WWDC25 used the older names `allocatedLocales`/`deallocate`. The SDK names are `reservedLocales` / `reserve(locale:)` / `release(reservedLocale:)`.
  - FluidVoice releases every reserved locale on teardown, and VoiceInk reserves explicitly before each use.
- **Handy UI:** Handy's language list for this engine should come from Dictation (33 base codes). Expose regional variants (en-GB/en-US/en-IN, pt-BR/pt-PT, zh-TW) as explicit choices, because bare codes resolve unpredictably.

## 6. Custom vocabulary (`custom_words`)

**Recommendation:** Feed `settings.custom_words` (up to 100, short phrases) into `AnalysisContext.contextualStrings[.general]` for `DictationTranscriber`. It works and costs nothing measurable. Keep Handy's fuzzy `apply_custom_words` post-pass as well, because contextual strings only bias recognition and can't rescue words that sound very different. It has no effect on `SpeechTranscriber`, which is another reason to stay with Dictation.

Evidence:
- **Dictation, with vs without context [verified]:**
  - "ki flow" became "**Kissflow**".
  - "parakeet and moonshine with whisper.CPP" became "**Parakeet and Moonshine with whisper.cpp**".
  - Unchanged: "Abraham" (Abhiram) and "paying person about to" (ping Dharsan about Tauri).
  - Passing context at init (`SpeechAnalyzer(inputSequence:modules:analysisContext:)`) and calling `setContext(_:)` before `start` gave identical results.
- **SpeechTranscriber [verified]:** the same strings changed nothing ("Kiss Flow", "parakeet", "Abiram").
- **[doc]** `contextualStrings`:
  - "With the DictationTranscriber module, you can use this property to specify short custom phrases … Keep phrases relatively brief, limiting them to one or two words … Limit the total number of phrases across all tags to no more than 100."
  - For pronunciations, provide a custom language model via `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)`. That needs `SFSpeechLanguageModel.prepareCustomLanguageModel` training data, which is heavier **[unverified here]**.
- **API sketch:**

```swift
let ctx = AnalysisContext()
ctx.contextualStrings[.general] = Array(words.filter { !$0.isEmpty }.prefix(100))
let analyzer = SpeechAnalyzer(modules: [transcriber], options: opts)
try await analyzer.setContext(ctx)          // or pass analysisContext: at init
try await analyzer.start(inputSequence: stream)
```

FFI: add a `const char *context_words` parameter (`\n`-joined) to `apple_speech_transcribe` and `apple_speech_stream_start`. On the Rust side, pass `settings.custom_words.join("\n")` from `transcribe_onnx` and the stream branch.
