# Shhhcribble — Competitive Reference (2026-06, re-reviewed 2026-07)

> Durable reference so we don't re-run the competitor audit each time. Findings from **static analysis of the installed app bundles, prefs, and on-disk SQLite/JSON state** — not marketing pages. SuperWhisper **v2.14.0**, Wispr Flow **1.5.433**. The **2026-07 re-review** adds **FluidVoice** (open-source, `github.com/altic-dev/FluidVoice`) and **Granola** (Phase B research), and re-confirms capabilities inside our own FluidAudio dependency — see "2026-07 re-review — delta" and "Verified capabilities in our current stack" below.

---

## 2026-07 re-review — delta since 2026-06

**Wispr Flow — no material change.** Still 1.5.433, still ~497 MB Electron, still cloud-only ASR with Sentry + PostHog + Supabase + S3. Nothing new worth adopting. The one durable idea — Wispr's **Polish table** (every LLM cleanup logged + **undoable / revert-to-raw**), which maps to Sprint 0's open "revert to raw transcript" question — was already noted in the 2026-06 audit. Re-reviewed, unchanged.

**SuperWhisper — Modes design captured for Sprint 3.** Still v2.14.0. The Modes section below now carries a **minimal 8-field mode** design suitable for our MVP.

**New competitors this round:**
- **FluidVoice** (`github.com/altic-dev/FluidVoice`) — open-source macOS dictation built on the **same FluidAudio/Parakeet stack we use**. **GPLv3 → reference-only; we copy zero code** (patterns may inform clean rewrites). Has file transcription, streaming live-preview, history + engagement stats (streaks / words-today / time-saved), keyboard-layout virtualization, and vocabulary boosting fed from a personal dictionary. Mining it surfaced the **context-biasing** capability documented below.
- **Granola** (AI notepad) — inspected for **Phase B** (Notes). Electron + SQLCipher (AES-256, key in Keychain) + Y.js CRDT + **custom cloud backend**. Data model: `documents` (umbrella) + `document_panels` (sections) + `ydocs` (CRDT snapshots) + FTS5 search. **Transferable idea: separate raw capture from the AI-enhanced note, with note versions.** Avoid their custom backend — our CloudKit plan stands. (A `ShhhcribbleiOS` DerivedData folder exists locally — possibly a pre-existing iOS target; confirm before Phase B.)

## Verified capabilities in our current stack (FluidAudio 0.13.6)

Already present in the FluidAudio version we ship (pinned `0.13.6`, revision `57551cd9`) — verified by reading the checked-out source, not marketing. All are **parked candidates**, not scheduled.

- **Custom-vocabulary context biasing** — public API: `SlidingWindowAsrManager.configureVocabularyBoosting(...)`, `CustomVocabularyContext`, `CustomVocabularyTerm`, `VocabularyRescorer`, `ContextBiasingConstants`, `CustomVocabularyContext.loadWithCtcTokens`. Would let **Personal Dictionary** terms bias the ASR *at recognition time* so Parakeet transcribes names/jargon correctly on the first pass — a differentiator no competitor matches at the ASR layer, fully on-device. **Why it's a spike:** it lives on `SlidingWindowAsrManager` (+ a CTC rescorer model), whereas we currently use plain `AsrManager` (`AsrManager(config: .default)` + `transcribe(_:source:)` in `TranscriptionEngine.swift`). Adopting it changes the transcription pipeline and adds a model download. Touches the transcription path but **not** `AudioRecorder`.
- **Streaming ASR** — `StreamingEouAsrManager` / `StreamingChunkSize` are public (also Nemotron + Qwen3 streaming). Matches our deferred commit `6509cd7`; would fix the 3 s live-preview lag. Still needs an AirPods canary on the VP-free path before adoption.
- **25-language batch transcription** — Parakeet TDT v3 supports 25 European languages per FluidAudio's README; we hard-code English-only. Multi-language is a model capability we already ship, gated only by our own cleanup/UI assumptions.
- **File transcription is nearly free** — `AsrManager` exposes public `transcribe(_ url: URL, source:)` and `transcribeDiskBacked(_ url:)`, so **Sprint 4** may not need manual `AVAudioFile` decode. Integration point: `TranscriptionEngine.swift`.

## Constraints / corrections (2026-07)

- **Repo has no LICENSE file** → Shhhcribble is currently *all-rights-reserved*. Housekeeping item; pick a license deliberately before any open-source-adjacent decision. (A research agent wrongly asserted "Apache 2.0" — it is not.)
- **FluidVoice is GPLv3.** Study patterns/architecture; **do not copy** code, data models, or logic. Any adopted idea must be a clean first-principles rewrite.

---

## Side-by-side

| | **SuperWhisper** | **Wispr Flow** | **Shhhcribble** |
|---|---|---|---|
| Stack | Native Swift, macOS 13.3+ | Electron, macOS 12+ | Native Swift, macOS 14+ |
| Bundle size | 133 MB | 497 MB (140 MB asar) | ~30 MB |
| ASR engine | WhisperKit (Argmax) **+ Parakeet V3** | Cloud-only | Parakeet V3 (FluidAudio) |
| Local LLM | **llama.cpp + GGML**, 6 families (Llama 3.2, Mistral, Phi-2, DeepSeek-R1, GPT-OSS, Ministral) | None bundled | None |
| Cloud LLM | 8 via own proxy (Gemini 3/3.1, Grok 4.1, GPT-5.2/5.3/5.4, **Claude Sonnet 4.6**) | All cloud | None |
| Storage | GRDB SQLite + JSON modes in `~/Documents/superwhisper/` | `flow.sqlite` (14 tables) | UserDefaults only |
| Auto-update | **Sparkle** (`appcast.xml`) | **Squirrel** | None (manual DMG) |
| Telemetry | Sentry | Sentry | **None** |
| Localization | English | **30+ languages** | English |
| URL scheme | `superwhisper://` | `wispr-flow://` | None |
| Entitlements | `audio-input`, `apple-events` | JIT, unsigned-mem, library-validation off, camera, audio | `audio-input`, `apple-events`, accessibility (non-sandboxed) |

---

## SuperWhisper's killer feature: the Modes system

A mode lives at `~/Documents/superwhisper/modes/*.json` and carries:

- `activationApps[]`, `activationSites[]` — **auto-switch by frontmost bundle ID / URL** (this is "per-app activation")
- `prompt`, `promptExamples[]`, `contextTemplate`
- `contextFromActiveApplication`, `contextFromClipboard`, `contextFromSelection`
- `languageModelID`, `voiceModelID`
- `realtimeOutput`, `script` / `scriptEnabled`
- `translateToEnglish`, `literalPunctuation`, `autocapitalizeInsert`, `diarize`, `useSystemAudio`

Ships **`bundled_app_info.json`** — a **686-app catalog** mapping apps → one of **43 text-input formats** (top: `configuration_settings` 98, `file_path` 67, `plaintext` 53, `chat_message` 51, `design_parameters` 43, `code` 30, `terminal_command` 28, `email` 15, `sql` 6, `swift` 2, `applescript` 1…). So dictating into Cursor formats as `code`; into Mail as `email`; into Slack as `chat_message`. Plus `agent-hook` (Swift Mach-O) + `claude-hook` (shell) for an extensible agent runtime.

## Wispr Flow is a productivity suite, not just dictation

`flow.sqlite` — 14 tables:
- **History** (51 columns): `asrText` / `formattedText` / `editedText` tiers, `audio` + `screenshot` BLOBs, `axText` + `axHTML` (full accessibility context captured per dictation), `e2eLatency`, `formattingDivergenceScore`, `fallbackAsrText` / `fallbackFormattedText` (failover pipeline), `toneMatchedText`, `numDictionaryReplacements`, `personalizationStyleSettings`.
- **Dictionary**: `phrase`, `replacement`, `frequencyUsed`, `isSnippet`, `isStarred`, `teamDictionaryId` (collaborative).
- **Polish**: every LLM cleanup logged + **undoable** (`polishInitialText`, `polishedText`, `polishUndone`, `instruction`, `usedProvider`, `modelVersion`, `diffCount`, `feedback`).
- **FlowLensHistory** (agent chat), **Notes / NoteVersions / NoteImages**, **Meetings / MeetingVersions**, **CalendarEvents** (with conference URLs), **Links** (clipboard URL tracker).
- `config.json` defines ~20 distinct error-notification states (`MicDisconnected`, `MicAccessTimeout`, `NoClamshellBuiltInMic`, `WeeklyWordsLimitReached`…).

---

## LLM cleanup — decision record

**Decision: Apple Foundation Models, prototype-first. `FillerWordFilter` stays the universal fallback. Do NOT bundle local llama.cpp.**

- SuperWhisper hedges (local llama.cpp **and** 8 cloud models) only because it supports macOS 13.3+ / Intel and can't rely on Apple's on-device model. We target macOS 14+ and accept gating cleanup on 26+.
- Apple FM = **zero bundle weight, zero cost, zero config, zero API keys** — preserves the no-cloud / no-telemetry pitch neither competitor can claim. Bundling GGML would 4–5× our ~30 MB and fight the lean-native identity.
- **Progressive enhancement**: `FillerWordFilter` for everyone; FM cleanup for the eligible ~15–25% of users.
- **Honest risk** (unmeasured): Apple's 3B cleanup quality. First task of the sprint is a throwaway quality prototype before any UI is built.
- Eligibility (verified): macOS 26+, Apple Silicon, Apple Intelligence enabled, supported region (China mainland excluded; EU OK), supported system language, not MDM-disabled. Runtime gate: `SystemLanguageModel.default.availability` → `.available` / `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`.

---

## Deliberately NOT copying (privacy / focus as differentiators)

- Wispr Flow's notes/meetings/calendar/agent-chat *suite* — scope creep that diluted their dictation core. (Our planned notes track is deliberately narrower.)
- **Telemetry / Sentry** — zero-telemetry is a real differentiator.
- User accounts / sign-in.
- **Input device picker** — CLAUDE.md explicitly forbids; route-change handlers heal automatically.
- Persistent on-disk recording archive — privacy concern.

## What Shhhcribble already wins on

- **Smart activation** (tap=toggle, hold=PTT, no setting) — neither competitor has this; both make you pick a mode.
- **VP-free AirPods reliability + fresh-engine-per-recording** — load-bearing decisions; competitors don't show this care.
- **Music-pause via AppleScript** — SuperWhisper bundles `MediaRemoteAdapter.framework`, which (per our 2026-05-06 testing) returns false on macOS 26. We picked the correct path.
- **~30 MB native bundle** vs 133 MB / 497 MB.
- **Zero telemetry, zero cloud, zero accounts.**

---

## Dropped ideas (with reason)

- **Translate-to-English** — *not possible with our engine.* FluidAudio/Parakeet V3 is transcription-only — no translate task, no language hint (verified v0.13.6 source). SuperWhisper's flag works only via WhisperKit. Would require adding a whole Whisper engine.
- **Bundled local llama.cpp** — heavy, fights lean-native identity. Revisit only if macOS 26 adoption stalls.

---

## Already resolved (don't re-propose)

Settled by CLAUDE.md or already shipped — listed so a future audit doesn't resurface them:

- **Input-device picker** — forbidden (route-change handlers heal automatically).
- **Warm engine across recordings** — anti-pattern; fresh-engine-per-recording is load-bearing.
- **Pasteboard restore after paste** — shipped (`TextInserter` clipboard snapshot + restore).
- **`noResult` / honest empty-transcription state** — shipped (`showNoResult()` / `.noResult` pill).
- **Streaming transcription** (`StreamingEouAsrManager`) — a known deferred feature (commit `6509cd7`); needs an AirPods canary on the VP-free path before adoption. Not near-term.
