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

### Fixed
- First dictation on cold AirPods captured silence ("No speech detected") — the
  recording "go" signal now waits for the mic route to warm up.
- Crash when starting a recording before the mic route was ready.

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
