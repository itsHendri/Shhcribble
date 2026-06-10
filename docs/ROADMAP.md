# Shhhcribble — Roadmap & Sprint Backlog

> Forward sprint plan, derived from the competitor audit. The findings + the local-vs-cloud LLM decision live in [`COMPETITIVE-REFERENCE.md`](COMPETITIVE-REFERENCE.md). Work sprints top-down, **one feature per branch** off `shhhcribble/main` per CLAUDE.md.

---

## Current state (2026-06, v1.6.0 build 7)

- **Shipped:** Phase-1 polish/reliability (v1.5.1); on-device Apple FM transcript cleanup (v1.6.0); first-AirPods warm-up + mic-route crash fixes — all reflected in CLAUDE.md.
- **`TranscriptCleaner.swift`** is fully wired: `FoundationModels` `LanguageModelSession` + `@Generable CleanedTranscript`, `@available(macOS 26)` + `SystemLanguageModel.default.availability` gating, **no timeout (deliberate)**, `FillerWordFilter` as universal fallback, `prewarm()` at launch, Settings toggle that disables + explains when unavailable.
- **Pref keys:** `selectedParakeetModel`, `selectedHotkeyID`, `transcriptCleanupEnabled`, `transcriptionHistory` (cap 10). Orphaned-but-harmless: `fillerFilterEnabled`, `activationMode`, `audioDuckingEnabled`.
- **Sparkle auto-update:** code done + merged (Sprint 1); release pending Developer ID cert.
- **Not built yet** (this backlog): Personal Dictionary, Modes/per-app, file transcription, history search/SQLite, notes.

---

## Sprint 0 — Validate the shipped cleanup (quick warm-up)

Cleanup shipped without the originally-planned quality prototype. Small validation pass before building more on top.
- Run ~10 filler-heavy real transcripts through cleanup; eyeball quality + note failure modes.
- If quality dips, retune the instruction prompt in `TranscriptCleaner.swift` — it's load-bearing; re-prototype before changing (per CLAUDE.md).
- Decide on a **"revert to raw transcript" affordance** (Wispr Flow logs every cleanup in a `Polish` table and makes it undoable). Keep or skip.
- **Acceptance:** a documented quality read; prompt left as-is or deliberately retuned.

## Sprint 1 — Sparkle auto-update *(FIRST)* — ✅ CODE DONE, release pending cert

**Status (2026-06-09):** Sparkle integrated + wired + locally validated (full update path proven via localhost loopback), merged to `main` (`1c89dc1`). Signing story settled: **Developer ID + notarization required** (ad-hoc won't ship). Only the cert-gated release remains — cut a notarized **v1.6.1** baseline once the Developer ID cert is in place (see CLAUDE.md "Release workflow" + Sparkle decision). The released v1.6.0 is pre-Sparkle/un-notarized, so the auto-update baseline must be a new Sparkle-enabled release.

Removes the manual-DMG release friction. Both competitors ship auto-update.
- Add Sparkle (SPM); `SUFeedURL` + `SUPublicEDKey` in `Info.plist`.
- Generate + securely store EdDSA signing keys (**never in repo**).
- Host `appcast.xml` + DMGs on GitHub Releases (where releases already live).
- Wire `SPUStandardUpdaterController`; add "Check for Updates…" to the menu-bar menu.
- **Gotcha to resolve first:** verify Sparkle validates with the current non-sandboxed app + ad-hoc "Sign to Run Locally" signing — likely needs a real Developer ID cert (+ notarization) for the updater to accept the download. Settle the signing story before wiring.
- Update CLAUDE.md release workflow (signing/notarization + appcast generation step).
- **Acceptance:** a built `vX` updates itself to `vX+1` in-app on a test machine.

## Sprint 2 — Personal Dictionary

Custom phrase→replacement (names, jargon). Universal competitor feature; a common Parakeet miss; composes with cleanup.
- Data model: ordered `[DictionaryEntry{phrase, replacement, caseSensitive}]` in `ModelManager` (UserDefaults JSON to start; moves to SQLite in Sprint 5). New pref `dictionaryEntries`.
- Settings UI: add / edit / delete / reorder list (new section in `SettingsView.swift`, reuse `InlineWarning` styling where useful).
- Apply as a substitution pass on the **raw transcript BEFORE** cleanup + filler, so the LLM sees corrected terms. Whole-word, case-aware.
- Edge cases: punctuation-adjacent matches, multi-word phrases, overlapping entries.
- Update CLAUDE.md pref table + note the ordering (dictionary → cleanup → filler).
- **Acceptance:** dictate a name Parakeet mangles → it's corrected in the pasted output.

## Sprint 3 — Modes / per-app formatting *(design spike first)*

SuperWhisper's killer feature: dictation formatted for the destination (code vs email vs chat).
- **DESIGN SPIKE (first task):** workshop the minimum mode set (default/code was rejected once). Decide the axes (prose / code-literal-punctuation / chat / email) and the per-mode cleanup prompt.
- Mode data model — reference SuperWhisper's shape: `name`, `prompt`, `literalPunctuation`, `activationApps[]` (see `COMPETITIVE-REFERENCE.md`).
- Mode selection: menu-bar quick-pick + Settings.
- Per-mode cleanup: pass the mode's prompt into `TranscriptCleaner`.
- **Follow-on (separate sprint, only once modes exist): per-app activation** — auto-select a mode from `NSWorkspace.shared.frontmostApplication` (already captured in `endRecording()`).
- **Acceptance:** switching mode changes cleanup formatting; later, the frontmost app auto-selects the mode.

## Sprint 4 — File transcription

Drag an audio/video file → transcribe. SuperWhisper does this via `CFBundleDocumentTypes`.
- `CFBundleDocumentTypes` (`public.audio` / `public.movie`) in `Info.plist`; handle open-with + drag-onto-dock.
- Decode file to `[Float]` (`AVAudioFile`), feed `TranscriptionEngine.transcribe` (engine already handles arbitrary samples).
- Output UX (decide): save `.txt` beside the file / copy to clipboard / open a result window.
- Progress UI for long files (chunked).
- **Acceptance:** drop a 1-min `m4a` → get a transcript.

## Sprint 5 — History upgrade (SQLite + search)

Cap-10 UserDefaults JSON → durable, searchable. Both competitors use SQLite.
- Migrate history to GRDB (SuperWhisper uses GRDB) or `SQLite`; migrate existing JSON entries.
- Drop the 10-cap; add search + per-row copy (Copy.ai pattern) + export.
- Promote history from menu-submenu to a window if it grows (Superhuman two-pane list/detail optional).
- Move `dictionaryEntries` (Sprint 2) into the same DB.
- **Acceptance:** 100+ entries searchable; per-row copy works; survives relaunch.

---

## Phase B (later, dedicated) — Notes / sticky-notes + iOS sync

The companion **Scribble iOS** app vision. Its own multi-sprint phase; starts with a design session. Same Apple ID → CloudKit private DB.
- **B0 Design session:** does dictation feed notes? sticky-note lifecycle (pin / dismiss / persist)? shared CloudKit schema with the iOS app.
- **B1** CloudKit container shared with iOS Scribble app (same developer team); schema + sync.
- **B2** Desktop sticky-note UI (floating `NSPanel`s? menu-bar notes list?).
- **B3** Sync + conflict handling; offline behaviour.
- **Acceptance:** a note created on iPhone appears as a desktop sticky, and vice-versa.

---

## Dropped / settled (don't resurface)

- **Translate-to-English** — impossible on Parakeet/FluidAudio (transcription-only). Would need a Whisper engine.
- **URL scheme `shhhcribble://`** — cut (niche for a hotkey-first app); re-add only if Shortcuts/automation becomes a real ask.
- **Bundled local llama.cpp** — fights the lean-native identity; revisit only if macOS-26 adoption stalls.
- **Input picker, warm engine, pasteboard restore, noResult state** — see `COMPETITIVE-REFERENCE.md` "Already resolved".

## Conventions (per CLAUDE.md)

One feature per branch off `shhhcribble/main`; build + AirPods/Spotify smoke test before committing; update CLAUDE.md when a change adds a load-bearing decision or pref key; **commit only when asked**.

**Default process:** sprints now run via the **autonomous development loop** (see CLAUDE.md "Autonomous development loop") — backlog order **2 → 4 → 5**; Sprint 3 (Modes) and Phase B (Notes) stay human-gated (design first). Each change passes the loop's QC gates (build + CI + adversarial review + CHANGELOG update); the AirPods/Spotify hardware smoke test stays a human gate.

**Candidate features to weigh (not committed):** voice syntax (say "bullet"/"heading" → markdown — cheap, composes with cleanup); revisit streaming transcription (deferred commit `6509cd7`) for live-preview lag; Siri-Shortcut capture for Phase B handoff; a privacy-transparency badge.

## Verification (every sprint)

- Build + tests: `xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' test`.
- Smoke test: AirPods + Spotify playing → record → transcript lands, music resumes clean.
- Tail logs: `log stream --predicate 'subsystem == "com.shhhcribble.app"'`.
