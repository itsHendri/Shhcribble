# Shhhcribble — project context for Claude

This file is the single source of truth for "what Claude should know before touching this repo." Skim it at the start of every session.

---

## What this app is

A menu-bar-only macOS voice-to-text utility. Hold the hotkey → speak → release → transcribed text pastes into the focused field. Runs entirely on-device via [FluidAudio](https://github.com/FluidInference/FluidAudio) + NVIDIA Parakeet V3 (CoreML). No cloud, no API keys.

**Target OS:** macOS 14+ (tested on 26 Tahoe). **Xcode:** 15+. **Language:** Swift.

---

## Directory map

```
Shhhcribble/
├── App/
│   ├── main.swift                ← NSApplicationMain bootstrap
│   └── AppDelegate.swift         ← Owns all subsystems; recording state machine
├── Audio/
│   ├── AudioRecorder.swift       ← AVAudioEngine lifecycle — FRAGILE, read class doc before editing
│   └── MusicPauser.swift         ← Pauses/resumes media via private MediaRemote.framework
├── HotKey/
│   └── HotKeyMonitor.swift       ← Carbon RegisterEventHotKey (no Input Monitoring needed)
├── Transcription/
│   ├── TranscriptionEngine.swift ← FluidAudio AsrManager wrapper
│   ├── ModelManager.swift        ← Static registry: models, hotkeys, prefs, history
│   └── FillerWordFilter.swift    ← Regex strip of "um", "uh", etc.
├── TextInsertion/
│   └── TextInserter.swift        ← AX direct insert → Cmd+V fallback → clipboard fallback
├── UI/
│   ├── SoundwavePanel.swift      ← Floating NSPanel (nonactivating)
│   ├── SoundwaveView.swift       ← SwiftUI pill animation
│   ├── MenuBarController.swift   ← NSStatusItem + menu rebuilds
│   ├── SettingsView.swift        ← Settings form (SwiftUI)
│   └── SettingsWindowController.swift
└── Resources/
    ├── Info.plist                ← CFBundleShortVersionString is the single source of truth for the About string
    ├── Shhhcribble.entitlements
    ├── Assets.xcassets/
    ├── PrivacyInfo.xcprivacy
    └── shhhcribble-scribble-sound.mp3
```

`Distribution/` — packaging (`create-dmg.sh`, `set-dmg-layout.py`).

---

## Load-bearing decisions (don't relitigate without reading why)

### AudioRecorder: fresh AVAudioEngine per recording, no voice processing
**Why:** `stop()` reallocates the engine instance on every call, so `start()` always binds to the current default input device. Hardware re-binding is "free" — a rebooted AirPods reconnect, a Continuity Mic swap, a sleep/wake cycle all heal themselves on the next hotkey press without any explicit listener. Pays ~100–200 ms cold-start per recording for bulletproof lifecycle.

`setVoiceProcessingEnabled` is **never** called. Empirically verified on macOS 14+ (confirmed on Tahoe 26, session 2026-04-23): plain HAL I/O delivers AirPods mic audio cleanly at 24 kHz stereo Float32 without any AUVoiceIO opt-in. The historical "AirPods tap is silent without VP" guidance was macOS 13-era and is false today. Do not reintroduce VP-for-Bluetooth as an AirPods fix — doing so ruins AirPods playback, corrupts concurrent calls/music, and generates notification storms that break mid-recording route handling (see Lessons learned).

### AudioRecorder: mid-recording route changes rebuild the engine
`handleConfigurationChange()` fires on `AVAudioEngineConfigurationChangeNotification`. It tears the tap down, reallocates the engine, and restarts against the new input format, preserving samples across the transition. No debounce. Empirically verified 2026-04-23 that the notification arrives at normal human-speed cadence on a VP-free code path (four events across a 37 s recording with two AirPods↔Mac switches, no burst, no dropouts). If VP is ever reintroduced, the notification storm it generates *will* deadlock this handler — see Deferred features below.

### Transcription pipeline: single batch model + 3 s polling live preview
One FluidAudio `AsrManager` loaded with Parakeet V3 (~494 MB). Final transcription runs once on `stop()`. The lozenge's live-preview text comes from a `liveTranscriptionTask` in AppDelegate that re-runs the full batch model against the growing sample buffer every 3 seconds. Simpler than a streaming manager and avoids format-assumption bugs on the VP-free AirPods path. Trade-off: live preview lags 1.5–3 s behind the speaker and CPU cost scales with recording length — acceptable for typical sub-30 s usage.

### TextInserter: AX-first, Cmd+V fallback, clipboard restore on both
1. Snapshot current pasteboard contents.
2. Write transcription to clipboard (universal failsafe).
3. Try AX direct insert (`AXUIElementSetAttributeValue` on `kAXSelectedTextAttribute`). Success returns `.accessibilityInserted`.
4. On AX failure or if `targetPid` is non-Finder, send Cmd+V via `postToPid`. Success returns `.pastedViaKeyboard`.
5. Both success paths `scheduleClipboardRestore` with a 2 s delay, `NSPasteboard.changeCount`-gated so any manual copy during the window isn't clobbered.
6. Only `.copiedToClipboard` (no target PID / Finder) leaves transcription on the clipboard indefinitely — no auto-paste was attempted, so the user needs to ⌘V themselves.

The 2 s window is deliberate: gives the user time to visually confirm the paste and to manually ⌘V if the target app silently dropped the Cmd+V event (Electron hosts occasionally do). After that, prior clipboard is restored so URL/code-snippet/phone-number workflows don't get clobbered.

### UI state machine: optimistic `.copied`, no `.transcribing` pill
On hotkey release, `endRecording()` fires `playCompletionSound()` *and* flips the lozenge straight to `.copied` — no intermediate "Transcribing…" state. The 1 s auto-hide timer starts immediately, so the pill disappears within ~1.3 s regardless of how long the batch transcribe takes. Paste happens silently whenever the engine finishes.

If the result is empty, `showNoResult()` re-presents the pill in a neutral `.noResult` state ("No speech detected", muted `waveform.slash`, 1 s auto-hide) — distinct from the red `.error` state reserved for real failures (transcription threw, permission denied, no mic). Both re-presenters handle the case where the initial hide timer has already fired.

Close timings (post-hotkey-release dwell is ~1.22 s total): `showCopied` and `showNoResult` auto-hide 1.0 s, `showError` 1.6 s, hide spring 0.22 s, `orderOut` 0.3 s.

### Pause-music-while-recording via AppleScript (Spotify + Apple Music)
On record-start, `MusicPauser` AppleScripts each known music app: "are you running and currently playing? If yes, pause." Tracks which apps it paused. On record-end (success, cancel, error, app quit), AppleScripts each tracked app to resume. Always on — not a user-facing setting (the `pauseMusicEnabled` pref and its Settings toggle were removed; the orphaned `audioDuckingEnabled` UserDefaults key is harmless).

**Coverage scope:** Spotify and Apple Music only. YouTube and other browser-tab audio are NOT paused. User accepted this trade-off (Spotify is the dominant case). Adding browser-tab JS injection on top is possible without changing the Spotify path if it ever becomes painful.

**Why AppleScript (third iteration):** v1 (`AudioDucker` via Core Audio system volume) worked on built-in speakers but failed on AirPods due to the asynchronous Bluetooth volume bridge — reads returned stale values, compounding errors across recordings. v2 (`MusicPauser` via private `MediaRemote.framework`) was theoretically AirPods-clean because it sidesteps the audio system, but `MRMediaRemoteGetNowPlayingApplicationIsPlaying` returns `false` on macOS 26 even when Spotify and YouTube are actively playing — Apple progressively locked down MediaRemote starting in macOS 15.4. Confirmed via unified-log diagnostics 2026-05-06. AppleScript is the deterministic alternative — slightly more permission friction (one TCC prompt per app first time) but it actually works.

**Why not send media keys unconditionally:** unconditional Play on resume would start music the user had paused themselves before recording. AppleScript's `if player state is playing` check before pausing means we only resume what we paused — predictable, no surprises.

**TCC permission:** First time the user records while Spotify (or Music) is open, macOS prompts "Shhhcribble wants to control 'Spotify'." Approve once → works forever. The reason string lives in `Info.plist` under `NSAppleEventsUsageDescription`. App is *not* sandboxed (see [Shhhcribble.entitlements](Shhhcribble/Resources/Shhhcribble.entitlements) for why), so no `com.apple.security.scripting-targets` entry needed.

**Resume timing — transport-aware fixed delay:** On Bluetooth outputs (AirPods), `scheduleResumeAfterOutputSettles()` waits 2100 ms before resuming. That covers the full HFP→A2DP codec transition plus AirPods' buffer flush — anything shorter leaves an audible "muffled bleed" as the last HFP-quality frames play out before A2DP fully takes over. On non-Bluetooth outputs we use 700 ms — no codec switch, just chime/paste breathing room. The branch is gated by `kAudioDevicePropertyTransportType`. Cancel / error / quit paths skip this entirely and resume synchronously (no chime there to coexist with).

**Why fixed delay and not a Core Audio listener:** an earlier iteration registered a `kAudioDevicePropertyNominalSampleRate` listener intending to resume the instant the codec switched, with the 2100 ms as a safety timeout. Verified via unified-log diagnostics 2026-05-06 that the listener *never fires* on AirPods in practice — the system swaps the default output device between A2DP and HFP virtual devices during the codec switch, leaving our listener attached to one that's no longer current by the time the switch completes. So the timeout was the actual mechanism every recording, the listener was dead weight, and removing it simplified the code without changing behavior. **Don't reintroduce the listener** without a different signal that actually fires (e.g. `kAudioHardwarePropertyDefaultOutputDevice` change events), and even then only if you can prove it gives meaningfully earlier resumes than the fixed delay.

**Diagnostics:** `MusicPauser` logs every pause/resume through `os.Logger(subsystem: "com.shhhcribble.app", category: "pauser")` at `.notice` level (and `.error` on AppleScript failures, including TCC denials — error code -1743). Tail with: `/usr/bin/log stream --predicate 'subsystem == "com.shhhcribble.app"'`.

**Don't relitigate:** don't try `MRMediaRemoteGetNowPlayingInfo` as a "maybe it works where IsPlaying didn't" fallback — we already chose deterministic AppleScript over private-API gambling.

### Carbon hotkeys (not CGEventTap)
`RegisterEventHotKey` doesn't require Input Monitoring permission and is never auto-disabled by macOS. Downside: fixed list of presets, no arbitrary chords. Fine.

### Escape-to-cancel during recording
Global `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` installed only while `state == .recording` (see `AppDelegate.escapeMonitor`). Keycode 53 routes to `cancelRecording()` — stops engine, discards samples, hides the panel, skips transcription and paste. Monitor is torn down on end / cancel / error so Escape isn't swallowed elsewhere.

**Requires Accessibility permission to fire.** Global keyboard monitors are gated on AX trust, and `xcodebuild` invalidates AX on every rebuild (new binary signature), so Escape silently stops working after a rebuild until you remove + re-add Shhhcribble in System Settings → Privacy → Accessibility.

### Smart activation: hold duration auto-selects the mode
There is no activation-mode setting. `AppDelegate` measures how long the hotkey is held between keyDown and keyUp. A hold ≥ 500 ms (`holdThreshold`) is read as push-to-talk — releasing the hotkey stops and transcribes. A quick tap (< 500 ms) is read as toggle — recording stays on until the next tap stops it. The keyDown→keyUp branch logic lives in the `HotKeyMonitor` closures; `recordingStartedByKeyDownAt` stores the start timestamp and is cleared on end/cancel/error. The old `ModelManager.ActivationMode` enum and `activationMode` pref were removed (the orphaned `"activationMode"` UserDefaults key is harmless). Edge case: if `beginRecording()` is delayed past keyUp (first-run mic-permission prompt), a long hold falls through to toggle behavior — accepted, cold start is ~100–200 ms vs the 500 ms threshold.

### About version reads from Info.plist
`CFBundleShortVersionString` is the single source of truth. Settings → About reads it dynamically; no hardcoded string to bump.

### History persisted via UserDefaults, cap 10
Survives relaunch via JSON-encoded `[TranscriptionEntry]` under `"transcriptionHistory"`. Cap chosen for menu readability.

### Hidden picker labels in Settings
Section headers already name each setting; inline `Picker("Model", ...)` labels duplicated them visually. Every picker uses `.labelsHidden()`.

---

## Deferred features (skipped during the reboot, documented for future)

These commits exist in the repo's git history (reachable via SHA even after branch cleanup) and represent known-working implementations worth porting if the triggering symptom ever appears.

### Electron AX bypass — commit `9883097`
Electron hosts (Claude.app, Slack, VS Code, Cursor, Discord, Spotify) expose an `AXTextArea` whose `kAXSelectedTextAttribute` reports as settable and whose `AXUIElementSetAttributeValue` returns `.success` — but the underlying `contenteditable` silently drops the write. The commit adds a static bundle-ID denylist to `TextInserter` that routes known Electron hosts straight to Cmd+V, skipping the lying AX insert. **Port if:** transcription starts silently dropping in any Electron host. Currently works correctly without it (paste tested in Claude.app and Slack on the v1.3.0 line).

### Streaming transcription via Parakeet EOU 160 ms chunks — commit `6509cd7`
FluidAudio ships a `StreamingEouAsrManager` that produces partial transcripts at ~160 ms cadence instead of the 3 s polling loop. **Port if:** the 3 s live-preview lag becomes a real user complaint. **Requires a careful AirPods canary** — the streaming code was originally authored on top of VP-enabled captures and may have format assumptions (16 kHz mono vs. AirPods' native 24 kHz stereo) that need verifying on our VP-free pipeline. Also adds a second model download (EOU 120 M) and a streaming→batch empty-result fallback (`df37b66`).

### 300 ms `AVAudioEngineConfigurationChange` debounce — commit `fbf7a69`
Only required deadlock protection **if VP-for-BT is ever reintroduced** — VP toggling during AirPods codec renegotiation generates notification storms that the current single-restart handler cannot coalesce (measured at ~1520 VP error lines in a single session 2026-04-22). On the VP-free path, empirically unnecessary. If VP comes back for any reason, this debounce must come back with it.

---

## Lessons learned (anti-patterns to avoid)

- **Never run a second `AudioRecorder` while the main one is idle.** Two engines sharing the voice-processing lifecycle deadlock the main thread on the `AVAudioEngineConfigurationChange` notification handler. Spindump: `AVAudioEngine dealloc → dispatch_sync_f_slow`. Broke the v2 onboarding mic-test step; deleted it. Onboarding itself is also skipped in v1.3.0.
- **Never reintroduce the input-device picker.** Abandoned in v2 for lifecycle bugs (users pinned to a disconnected device → silent recordings). Route-change handlers do the right thing automatically.
- **Never enable voice processing for Bluetooth inputs.** On modern macOS the tap delivers high-quality AirPods audio without any AUVoiceIO opt-in. Forcing VP destroys output audio (music + calls go scratchy), causes trailing-frame loss, and pins AirPods in HFP for 30+ seconds after recording ends. Historical CLAUDE.md guidance to the contrary is macOS 13-era and wrong on macOS 14+. Confirmed 2026-04-22 after a full day of experiments.
- **Never keep the engine warm across recordings.** Warm-engine-within-transport pins AirPods in HFP indefinitely, turning the app into a continuous Bluetooth microphone session. Fresh-per-recording is the load-bearing pattern; `stop()` must reallocate `engine = AVAudioEngine()`. Confirmed via reproducible user test 2026-04-22.
- **Never pre-allocate a reusable `AVAudioPCMBuffer` sized from input-format-at-prepare-time.** On AirPods' variable stereo buffers, the pre-sized buffer silently truncates — transcription comes back with trailing words clipped. Allocate per-callback from `buffer.frameLength * ratio`.
- **Don't bundle features into one big PR.** The v2.2.0 "onboarding + input picker + launch sound + launch-at-login + Escape-to-cancel + brand gradient" merge caused a system-wide keyboard lockup that took the whole thing down. One feature per branch, build + verify in isolation.
- **Don't touch `AudioRecorder` unless you have to.** This file has been the single point of failure for every AirPods-related incident. Device pinning, custom tap formats, lifecycle changes — all high-risk. If you're reading this before editing it, you should probably not be editing it.
- **Fresh Xcode builds invalidate Accessibility grants.** Every clean build produces a new binary signature; TCC treats it as a different app. If Escape-to-cancel or auto-paste "stops working" after a rebuild, first step: remove Shhhcribble from System Settings → Privacy → Accessibility and re-add the freshly built binary.

---

## Pref keys (UserDefaults, domain `com.shhhcribble.app`)

| Key | Type | Default | What it does |
|---|---|---|---|
| `selectedParakeetModel` | String | `"parakeet-v3"` | Which FluidAudio model variant to load |
| `selectedHotkeyID` | String | `"optSpace"` | Which preset hotkey is active |
| `fillerFilterEnabled` | Bool | `true` | Strip um/uh/hmm before pasting |
| `transcriptionHistory` | Data (JSON) | `[]` | Last 10 transcriptions |

---

## Release workflow

1. Bump `CFBundleShortVersionString` in `Shhhcribble/Resources/Info.plist` (semver major.minor.patch).
2. Bump `CFBundleVersion` (monotonic integer).
3. Verify with `xcodebuild -scheme Shhhcribble -configuration Debug build`.
4. Smoke test: record on AirPods with music playing → transcript lands, music stays clean. Settings → About shows the new version.
5. `bash Distribution/create-dmg.sh` → `~/Desktop/Shhhcribble.dmg`.
6. Commit: `Bump version to X.Y.Z`. Push to `shhhcribble/main`.
7. Tag and publish a GitHub release with the DMG attached:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   gh release create vX.Y.Z ~/Desktop/Shhhcribble.dmg --title "Shhhcribble vX.Y.Z" --notes-file <notes.md>
   ```
   README points users to the Releases page for downloads, so the DMG attachment is what end-users actually consume.

---

## Branches

One branch: `shhhcribble/main`. Push work directly; no v2-line tag churn, no experimental branches kept around on origin. If a future feature needs isolated experimentation, branch locally from `main`, merge when stable, delete the local branch. Don't push WIP branches to origin without a reason.

---

## When adding a feature

1. Branch off `shhhcribble/main` locally.
2. Keep scope small — one feature per branch.
3. Build + verify + smoke-test with AirPods + music playing before committing anything else on top.
4. Update CLAUDE.md when the change introduces a new load-bearing decision or pref key.
5. Merge to `main`, delete the feature branch.
