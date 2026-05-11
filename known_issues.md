# Known Issues

A running log of bugs that took non-trivial work to root-cause, so future-you
(or a future AI agent) doesn't re-debug them from scratch.

---

## 1. AVAudioEngine tap closure SIGTRAPs on iPadOS 26 — Swift 6 actor isolation

### Symptom

The app crashes the instant the user taps the mic in **Quiz — Voice answer**.
There is no error message in the UI. The crash happens before any audio buffer
ever reaches the recognizer (no transcript, no "no speech detected" — just a
hard kill).

The crash produces an `.ips` report on the iPad at
`/var/mobile/Library/Logs/CrashReporter/AIQuiz-*.ips`, syncs to the Mac via
Xcode → Window → Devices and Simulators → "View Device Logs", and lands at
`~/Library/Developer/Xcode/DeviceLogs/<device>/AIQuiz-*.ips`.

The faulting thread in the report is named `RealtimeMessenger.mServiceQueue`
and the stack trace is unambiguous:

```
EXC_BREAKPOINT (SIGTRAP)
libdispatch.dylib      _dispatch_assert_queue_fail
libdispatch.dylib      dispatch_assert_queue
libswift_Concurrency   _swift_task_checkIsolatedSwift
libswift_Concurrency   swift_task_isCurrentExecutorWithFlagsImpl
AIQuiz                 closure #1 in STTService.startListening(…)
AVFAudio               AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform
AVFAudio               CADeprecated::RealtimeMessenger::_PerformPendingMessages
```

### Root cause

`STTService` is annotated `@MainActor`. Closures defined inside `@MainActor`
methods inherit `@MainActor` isolation in Swift 6 strict-concurrency mode.

`AVAudioEngine` invokes the audio tap callback on its own dispatch queue
(`AVAudioNodeTap::TapMessage::RealtimeMessenger`), NOT on the main actor. The
Swift 6 runtime injects `swift_task_checkIsolatedSwift` at the top of any
inherited-`@MainActor` closure to verify "am I really on the main actor?" —
that assertion fails on the audio thread, calls `dispatch_assert_queue_fail`,
and SIGTRAPs the process.

The same issue affects `SFSpeechRecognizer.recognitionTask(with:resultHandler:)`
— its result handler is also invoked off the main actor.

### Symptom variants that confused the diagnosis

- **No `.ips` files appearing in `~/Library/Logs/DiagnosticReports/`**. iOS only
  syncs crash reports to that Mac path on a clean termination; the SIGTRAP
  produces reports on the device that you have to pull explicitly (Xcode →
  Window → Devices and Simulators → "View Device Logs"). They end up in
  `~/Library/Developer/Xcode/DeviceLogs/<device>/`.
- The "Siri and Dictation are disabled" error from `SFSpeechRecognizer` is a
  separate, unrelated issue (fix: enable Siri or Dictation in iOS Settings).
  It can appear before the crash and red-herring you into thinking the audio
  pipeline is broken.
- Connecting AirPods mid-debug introduced a real route-change crash too, but
  we briefly assumed it was the same bug. It wasn't.

### The fix

Declare closures that run on audio threads or recognizer callbacks with an
**explicit `@Sendable` function type**. That breaks the inherited `@MainActor`
isolation and the runtime check is no longer injected:

```swift
// In STTService.startListening (which is @MainActor):

// Capture non-Sendable state inside an @unchecked Sendable box.
let requestRef = RequestRef(request)

// Type the closure as @Sendable — this severs inherited @MainActor.
let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
    requestRef.value?.append(buffer)
}
inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)

// Same pattern for the recognition task callback:
let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
    // …work that pulls Sendable scalars (text, isFinal) out of result, then
    // hops to @MainActor via Task { @MainActor in … } for any UI updates.
}
recognizer.recognitionTask(with: request, resultHandler: resultHandler)
```

The supporting boxes (in `STTService.swift`):

```swift
private final class RequestRef: @unchecked Sendable {
    var value: SFSpeechAudioBufferRecognitionRequest?
    init(_ v: SFSpeechAudioBufferRecognitionRequest) { self.value = v }
}

private final class WeakSelfBox: @unchecked Sendable {
    weak var value: STTService?
    init(_ v: STTService) { self.value = v }
}
```

### Pitfalls if you change this code

- **Don't** assign the closure to an `AVAudioNodeTapBlock` alias or a `var`
  without the `@Sendable` qualifier. Without it, the compiler still infers
  `@MainActor` from the enclosing method and the crash returns.
- **Don't** capture `self` or any `@MainActor`-isolated value directly inside
  the tap or result-handler closures. Capture through the Sendable boxes.
- **Don't** put `DebugLog.log(...)` (which writes to a file) inside the tap
  closure. The audio thread is real-time; file I/O on it can stall the
  CoreAudio watchdog and produce a different kill with no useful report.
- **Don't** call `setPreferredInput()` or use `mode: .measurement` unless you
  have a clear reason. They each triggered different audio-route crashes
  during this investigation.

### Deferred work that depended on this code path

The spoken **"hint"** voice command (originally specced in §3.1 and §3.3) was
removed during the streaming-vs-file-based investigation. Re-adding it just
requires extending the tap-block / recognition handler to also scan for the
"hint" keyword in partial transcripts and fire a callback. The `@Sendable`
wrapping pattern above applies to that callback too.

### Related branches and tags

- Tag `record-then-transcribe` (commit `78ef467`) — file-based fallback using
  `AVAudioRecorder` + `SFSpeechURLRecognitionRequest`. No streaming, no
  isolation problem, no live transcript. Keep as the conservative model.
- Tag `live-transcription` (commit `8e6c0d4`, on `main`) — the working
  streaming version with the `@Sendable` fix.

### How to recognise this bug if it comes back

1. App crashes immediately on first mic tap, no transcript shown.
2. `~/Library/Developer/Xcode/DeviceLogs/<device>/AIQuiz-*.ips` shows
   `EXC_BREAKPOINT` on a thread whose queue contains `RealtimeMessenger`.
3. The stack trace includes `_swift_task_checkIsolatedSwift` and one of our
   `STTService.startListening` closures.

That combination is this bug. Re-apply the `@Sendable` fix.
