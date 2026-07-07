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

## Sprint 2 — Personal Dictionary — ✅ code complete (2026-06-10)

**Status:** implemented via the autonomous loop; lands on `main` with the commit that carries this note (all QC gates passed at commit time). `PersonalDictionary.swift` (whole-word lookaround substitution, sequential in-order application, verbatim replacements), `dictionaryEntries` pref, Settings add/edit/delete/reorder UI, `PersonalDictionaryTests`. ⚠ hardware smoke test PENDING (paste-path change) — the acceptance dictation test is part of that human gate.

Custom phrase→replacement (names, jargon). Universal competitor feature; a common Parakeet miss; composes with cleanup.
- Data model: ordered `[DictionaryEntry{phrase, replacement, caseSensitive}]` in `ModelManager` (UserDefaults JSON to start; moves to SQLite in Sprint 5). New pref `dictionaryEntries`.
- Settings UI: add / edit / delete / reorder list (new section in `SettingsView.swift`, reuse `InlineWarning` styling where useful).
- Apply as a substitution pass on the **raw transcript BEFORE** cleanup + filler, so the LLM sees corrected terms. Whole-word, case-aware.
- Edge cases: punctuation-adjacent matches, multi-word phrases, overlapping entries.
- Update CLAUDE.md pref table + note the ordering (dictionary → cleanup → filler).
- **Acceptance:** dictate a name Parakeet mangles → it's corrected in the pasted output.

## Sprint 3 — Modes / per-app formatting *(design spike first)*

SuperWhisper's killer feature: dictation formatted for the destination (code vs email vs chat). **Still design-gated (human).**
- **DESIGN SPIKE (first task):** workshop the minimum mode set (default/code was rejected once). Decide the axes (prose / code-literal-punctuation / chat / email) and the per-mode cleanup prompt.
- **De-risked (2026-07):** the SuperWhisper deep-dive lands a **minimal 8-field mode** — `key, name, activationApps[], prompt, promptExamples[], language, description, languageModelID` — with `activationApps[]` matched against `NSWorkspace.frontmostApplication` (**already captured in `endRecording()`**) and the mode `prompt` fed into the existing `TranscriptCleaner`. Their 686-app → 43-format catalog is **not** needed for MVP. See `COMPETITIVE-REFERENCE.md` "SuperWhisper's killer feature".
- Mode data model — reference SuperWhisper's shape: `name`, `prompt`, `literalPunctuation`, `activationApps[]` (see `COMPETITIVE-REFERENCE.md`).
- Mode selection: menu-bar quick-pick + Settings.
- Per-mode cleanup: pass the mode's prompt into `TranscriptCleaner`.
- **Follow-on (separate sprint, only once modes exist): per-app activation** — auto-select a mode from `NSWorkspace.shared.frontmostApplication` (already captured in `endRecording()`).
- **Acceptance:** switching mode changes cleanup formatting; later, the frontmost app auto-selects the mode.

## Sprint 4 — Transcription Studio (file transcription + windowed environment) *(BUILDING — design session 2026-07-03)*

**Widened from "drag a file → transcript" into a program** (design session 2026-07-03 — approved plan `~/.claude/plans/planning-session-for-sprint-functional-otter.md`). File transcription is the wedge into a **Granola-style windowed environment** (rail → searchable list → tabbed detail) unifying dictation + file transcripts. **SQLite pulled forward from Sprint 5. Formally enters Phase B** (the Notes design gate — cleared with the human this session). Result UX is a **window, not auto-paste** (competitor/Mobbin norm; a blind paste of a long transcript is wrong).

**Locked decisions:** invocation = "Transcribe File…" menu item + Finder "Open With" (`CFBundleDocumentTypes`; drag-onto-Dock impossible under `LSUIElement`); media = audio + video (`AVAssetExportSession` audio extraction — video is *not* free, all FluidAudio decode uses `AVAudioFile`) + sequential multi-file batch; pipeline = respect `transcriptCleanupEnabled` toggle, no length cap, store raw + cleaned; playback deferred; English v1.

**De-risk (verified 2026-07-03):** `AsrManager.transcribe(_ url:)` **auto-routes** to `transcribeDiskBacked` above ~30 s (no manual branching); public `transcriptionProgressStream` gives determinate progress; `ASRResult` = `.text`/`.duration`/`.confidence`.

**Sprint 4 first branch (building now):** thin `libsqlite3` `TranscriptStore` + history migration · `FileTranscriber` + coordinator (serializes against the shared `AsrManager`) · `CFBundleDocumentTypes` + `application(_:openFiles:)` + menu items · Transcriptions **window** (text-only tabbed detail, Summary tab *scaffolded*) · dictation history repointed to the store.
**Phased out:** Summary generation (on-device FoundationModels + versions) → **4b**; editable Notes + move `dictionaryEntries` to SQLite → **4c**; CloudKit/iOS sync → **Phase B**.
**Build guards:** no new embedded dynamic framework (protects the ad-hoc DMG); file path never auto-pastes / never touches `AudioRecorder`/routing/`MusicPauser`/`TextInserter` → **no AirPods smoke test triggered.**
- **Acceptance:** drop a 1-min `m4a` (menu picker *and* Finder Open With) → transcript in the window, `.txt` beside the source, text on the clipboard.

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
- **Granola insight (2026-07):** Granola's model separates **raw capture from the AI-enhanced note** (+ note versions) — worth borrowing as the note data-model shape. Avoid their custom cloud backend; CloudKit private DB stays our sync path. (See `COMPETITIVE-REFERENCE.md` Granola notes.)
- **Confirm first:** a `ShhhcribbleiOS` DerivedData folder exists locally — there may already be an iOS target scaffolded. Verify state before B1.
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

**Default process:** sprints now run via the **autonomous development loop** (see CLAUDE.md "Autonomous development loop") — backlog order **2 ✅ → 4 (next) → 5**; Sprint 3 (Modes) and Phase B (Notes) stay human-gated (design first). Each change passes the loop's QC gates (build + CI + adversarial review + CHANGELOG update); the AirPods/Spotify hardware smoke test stays a human gate.

**Candidate features to weigh (not committed):** voice syntax (say "bullet"/"heading" → markdown — cheap, composes with cleanup); Siri-Shortcut capture for Phase B handoff; a privacy-transparency badge.

**Parked candidates from the 2026-07 competitive re-review** (documented, not scheduled — see [`COMPETITIVE-REFERENCE.md`](COMPETITIVE-REFERENCE.md) "Verified capabilities in our current stack"):
- **Personal Dictionary → ASR context biasing** — feed dictionary terms into FluidAudio's `SlidingWindowAsrManager.configureVocabularyBoosting` / `CustomVocabularyContext` so Parakeet gets names/jargon right *at recognition time*, not just via post-hoc substitution. **Spike-gated + load-bearing:** changes the dictionary mechanism, swaps `AsrManager` → `SlidingWindowAsrManager`, and adds a CTC rescorer model download (transcription-path change; not `AudioRecorder`). Highest strategic value of the batch — no competitor matches it at the ASR layer.
- **Multi-language transcription** — Parakeet TDT v3 already supports 25 European languages in the model we ship; we hard-code English. **Decision-gated:** changes the "English primary" assumption and needs cleanup/FoundationModels language handling.
- **Revert-to-raw / undoable cleanup** — Wispr's Polish-table idea; closes Sprint 0's open "revert to raw transcript" question. Cheap, honest, on-brand.
- **Streaming live-preview** — `StreamingEouAsrManager` (deferred commit `6509cd7`) re-confirmed available in FluidAudio 0.13.6; would cut the 3 s live-preview lag. Still needs an AirPods canary on the VP-free path first.

## Verification (every sprint)

- Build + tests: `xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' test`.
- Smoke test: AirPods + Spotify playing → record → transcript lands, music resumes clean.
- Tail logs: `log stream --predicate 'subsystem == "com.shhhcribble.app"'`.
