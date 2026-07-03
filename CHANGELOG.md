# Changelog

All notable changes to Shhhcribble are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Shhhcribble began life as **FieldWhisperer** (first commit 2026-04-09) and was
> renamed to **Shhhcribble** on 2026-04-23.

## [Unreleased]

### Added
- **Sparkle auto-update** (2.x): in-app "Check for Updates…" menu item, automatic
  background checks, EdDSA-signed `appcast.xml` on GitHub Releases, and a Developer
  ID signing + notarization pipeline in `Distribution/` (`create-dmg.sh`,
  `generate-appcast.sh`).
- `CHANGELOG.md`, GitHub Actions CI build gate, and an autonomous development-loop
  process documented in `CLAUDE.md`.
- XCTest unit-test target (`ShhhcribbleTests`) wired into the Xcode project with a
  shared scheme; CI now runs `xcodebuild test` (build + unit tests) on every push/PR.
- **Personal Dictionary**: ordered phrase→replacement substitutions (whole-word,
  per-entry case sensitivity) applied to the raw transcript before AI cleanup /
  filler filtering, so corrected names and jargon reach the LLM and the paste.
  Managed in Settings (add / edit / delete / reorder); stored under the new
  `dictionaryEntries` pref.

### Fixed
- First dictation on cold AirPods captured silence ("No speech detected") — the
  recording "go" signal now waits for the mic route to warm up.
- Crash when starting a recording before the mic route was ready.
- Floating recording pill could flicker, vanish, or appear blank when a recording
  started shortly after the previous one closed — the panel's deferred window
  removal is now cancellable, and the spinner/"Copied!" states re-present
  themselves if the panel was hidden. The soundwave bars also rest while
  off-screen instead of animating continuously.
- Quick-tapping and speaking immediately on cold AirPods could yield "No speech
  detected" (the words land in the unrecoverable mic warm-up window). A "Waking
  mic… wait to speak" placeholder now appears when the route is still cold,
  signalling the user to wait; it never shows on the warm path.
- Pressing the hotkey right after launch, while the model was still loading,
  silently dropped the recording with feedback only in the menu bar. A near-cursor
  "Getting ready — try again in a moment" pill now explains why nothing happened.
- A fast second hotkey press (or Escape) as a recording ended could double-paste,
  duplicate a history entry, or slip past Escape-cancel — `endRecording()` now
  leaves the recording state before it awaits, so re-entrant events are ignored.
- The floating pill could appear on the wrong display on multi-monitor setups; it
  now shows on the display under the pointer.

### Changed
- Completion-sound playback is now logged (`os.Logger`, category `sound`) and its
  `play()` result checked, so a silent failure is diagnosable.
- **Sparkle auto-update temporarily detached from the build** (pending a Developer
  ID cert) so the app can be installed directly from a plain ad-hoc DMG again. The
  SPM package, product dependency, and framework link were removed from the Xcode
  project; the Sparkle Swift code and Info.plist feed keys are preserved behind
  `#if canImport(Sparkle)` for one-step re-enable. The "Check for Updates…" menu
  item is hidden while detached.

> Not yet released. Becomes the first notarized, Sparkle-enabled build (planned **v1.6.1**).

## [1.6.0] - 2026-06-03

### Added
- On-device transcript cleanup via Apple FoundationModels (macOS 26 + Apple
  Intelligence), with `FillerWordFilter` as the universal fallback.

## [1.5.1] - 2026-06-02

### Changed
- Phase-1 polish and reliability improvements. _(Version bumped but never published as a release.)_

## [1.5.0] - 2026-05-21

### Added
- Smart activation: **hold = push-to-talk, quick tap = toggle** (no activation-mode setting).

### Changed
- Music now always pauses while recording (Spotify + Apple Music); removed the toggle.

## [1.4.0] - 2026-05-11

### Added
- Pause music while recording for Spotify and Apple Music (via AppleScript).

### Changed
- Resumed publishing GitHub releases.

## [1.3.0] - 2026-04-23

First public release (as Shhhcribble; formerly FieldWhisperer).

### Added
- Hold-hotkey dictation → on-device transcription (NVIDIA Parakeet V3 via FluidAudio)
  → paste into the focused field.
- Carbon `RegisterEventHotKey` hotkey (no Input Monitoring permission), customizable preset.
- Live-preview floating pill with completion sound.
- Always-on filler-word filter; transcription history (cap 10, persisted).
- Escape-to-cancel during recording.
- AX-first text insertion with Cmd+V fallback and clipboard restore.
- "No speech detected" state for empty transcriptions.
- About version sourced from `Info.plist`.

### Changed
- Replaced WhisperKit with Parakeet V3 (FluidAudio).
- Renamed FieldWhisperer → Shhhcribble.

[Unreleased]: https://github.com/itsHendri/Shhhcribble/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/itsHendri/Shhhcribble/releases/tag/v1.6.0
[1.5.0]: https://github.com/itsHendri/Shhhcribble/releases/tag/v1.5.0
[1.4.0]: https://github.com/itsHendri/Shhhcribble/releases/tag/v1.4.0
[1.3.0]: https://github.com/itsHendri/Shhhcribble/releases/tag/v1.3.0
