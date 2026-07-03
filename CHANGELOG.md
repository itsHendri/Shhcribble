# Changelog

All notable changes to Shhhcribble are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Shhhcribble began life as **FieldWhisperer** (first commit 2026-04-09) and was
> renamed to **Shhhcribble** on 2026-04-23.

## [Unreleased]

### Added
- **On-device AI summaries (Transcription Studio Summary tab).** For any transcript,
  generate a short neutral summary plus extracted **action items** on demand, fully
  on-device via Apple FoundationModels — nothing leaves the Mac. A **Generate summary**
  button appears when Apple Intelligence is available (with a **Regenerate** and
  **Copy summary** action once one exists); when it isn't, the tab shows an
  `InlineWarning` with the reason instead of a dead button. New `TranscriptSummarizer`
  mirrors the `TranscriptCleaner` recipe (`@Generable` structured output, `<transcript>`
  delimiter framing to resist prompt injection, greedy sampling). Summaries persist in
  the SQLite store (new `summary` / `actionItems` / `summaryGeneratedAt` columns via a
  `PRAGMA user_version` v1 migration). On-demand only — no new setting or pref key.
- **File transcription (Transcription Studio, first cut).** Transcribe audio *and*
  video files — via a new **"Transcribe File…"** menu item (file picker) or Finder
  **"Open With → Shhhcribble"** (`CFBundleDocumentTypes` + `application(_:openFiles:)`).
  Multi-select is handled as a sequential queue (no files dropped); video audio is
  extracted with `AVAssetExportSession`; large files use FluidAudio's memory-safe
  disk-backed path automatically. File transcripts run the same pipeline as dictation
  (Personal Dictionary → AI cleanup or filler) and are copied to the clipboard, saved
  as `<name>.txt` beside the source, and added to the library — **never auto-pasted**.
- **Transcriptions window.** A three-pane environment (Home / Transcriptions rail →
  searchable list unifying dictation + file transcripts → tabbed detail) with Copy /
  Save `.txt` / Reveal in Finder and delete. The Summary tab is scaffolded for a
  later on-device-AI summary feature. **Clicking the menu-bar icon opens this window**
  (see Changed); it also auto-focuses when a file finishes. The rail carries
  Transcribe File / Settings / Quit, the Home tab shows engine status + the dictation
  hint, and the title bar shows the app icon in front of the name. Destructive actions
  (per-row delete, Clear All) require confirmation.
- **SQLite-backed transcript store** (`TranscriptStore`) replacing the cap-10
  UserDefaults history — durable, searchable (case-insensitive over title + text),
  and keeps the raw transcript alongside the cleaned text. Uses the system
  `libsqlite3` (no external dependency, no embedded framework).
- `CHANGELOG.md`, GitHub Actions CI build gate, and an autonomous development-loop
  process documented in `CLAUDE.md`.
- XCTest unit-test target (`ShhhcribbleTests`) wired into the Xcode project with a
  shared scheme; CI now runs `xcodebuild test` (build + unit tests) on every push/PR.
- **Personal Dictionary**: ordered phrase→replacement substitutions (whole-word,
  per-entry case sensitivity) applied to the raw transcript before AI cleanup /
  filler filtering, so corrected names and jargon reach the LLM and the paste.
  Managed in Settings (add / edit / delete / reorder); stored under the new
  `dictionaryEntries` pref.

### Changed
- Transcription history moved from the cap-10 UserDefaults JSON to the SQLite
  `TranscriptStore` (existing history migrated in on first launch; the old key is
  left untouched for rollback).
- **Menu bar is now window-first.** Clicking the menu-bar icon (either button) opens
  the Transcriptions window instead of a dropdown menu; all actions that lived in the
  dropdown — recent transcripts, Settings, Quit, engine status, Transcribe File — now
  live in the window. (The old click-a-recent-item-to-paste shortcut and the Sparkle
  "Check for Updates" item went with the dropdown; the latter returns when Sparkle is
  re-attached.)

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
- **Sparkle auto-update integrated but detached from the build** (pending a
  Developer ID cert): this build ships as a plain ad-hoc DMG with no in-app
  updater, so it still updates by downloading a new DMG. The Sparkle SPM package,
  product dependency, and framework link are removed from the Xcode project; the
  Sparkle Swift code, the `Distribution/` signing pipeline, and the Info.plist
  feed keys are preserved behind `#if canImport(Sparkle)` for one-step re-enable
  once the cert is in place. The "Check for Updates…" menu item is hidden while
  detached.

> Not yet released; in progress as **v1.7.0** (`Info.plist` bumped to 1.7.0 /
> build 8). Ships as a plain ad-hoc DMG — Sparkle auto-update stays detached until
> a Developer ID cert is available; the notarized, Sparkle-enabled release remains
> a separately-planned later build.

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
