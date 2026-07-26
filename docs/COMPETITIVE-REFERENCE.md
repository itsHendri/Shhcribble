# Shhhcribble — Competitive Reference (2026-06, re-reviewed 2026-07, full re-audit 2026-07-26)

> Durable reference so we don't re-run the competitor audit each time. Original findings from **static analysis of the installed app bundles, prefs, and on-disk SQLite/JSON state** — not marketing pages. The **2026-07-26 full re-audit** adds **Ghost Pepper** (source read) and refreshes every prior competitor; where the installed bundle hadn't moved, the delta comes from release notes and is **labelled as such**.

**Competitors tracked:** SuperWhisper · Wispr Flow · FluidVoice · VoiceInk · Granola · Aqua · Willow · Ghost Pepper.

---

## 2026-07-26 full re-audit — delta since 2026-07

**Method note (honesty):** SuperWhisper (2.14.0) and Wispr Flow (1.5.433) on this Mac have **not auto-updated since May**, so their local bundles are frozen at the versions we already analysed. Their deltas below are from **published release notes, not fresh static analysis** — treat feature claims as vendor-stated. Granola *has* updated locally (v7.441.6, 2026-07-24) but its **schema delta was NOT re-verified** — reading `granola.db` was blocked as personal meeting data, correctly. The prior data model stands unchallenged, not re-confirmed.

| Competitor | Was | Now | Verified by |
|---|---|---|---|
| SuperWhisper | 2.14.0 | **2.16.5** (2026-07-20) | Release notes |
| Wispr Flow | 1.5.433 | Android + Flow Notes era | Release notes |
| FluidVoice | niche find | **8,890★**, pushed 2026-07-25 | GitHub API + README |
| VoiceInk | source read | **5,674★**, pushed 2026-07-26 | GitHub API |
| Granola | (unversioned) | **7.441.6** (2026-07-24) | Installed bundle |
| Aqua | cloud | cloud, + iPhone keyboard (Apr 2026) | Research |
| Willow | cloud | cloud + **optional offline tier** | Research |
| **Ghost Pepper** | — | **2,963★ in 4 months** | Full source read |

### The three findings that matter most

1. **The category has converged on "voice edits existing text", and we don't have it.** FluidVoice ships **Command Mode** (control the Mac by voice) + **Write Mode** (rewrite text in place in any field); Wispr Flow ships **Command Mode** (voice-edit highlighted text — "make this more concise"). Two independent competitors landed the same idea. Every one of our styles transforms *what you just said*; none can act on *what's already on screen*. This is now the clearest capability gap in the product, ahead of anything on the roadmap.
2. **Revert-to-raw shipped elsewhere.** Wispr Flow's **"Undo AI Edit"** reveals the raw transcript, and Auto Cleanup is now a **four-level dial** (None / Light / Medium / High). This was our own parked Sprint-0 question. We store `rawText` alongside cleaned on every row already — the data is there, only the affordance is missing. Cheapest credible win on this list.
3. **Our own dependency has moved two minor versions.** We pin **FluidAudio 0.13.6**; current is **0.15.5** (2026-07-07), carrying **word-level timestamps**, **per-term CTC thresholds for custom vocabulary** (the context-biasing item we parked), **Sortformer v3 diarization** with deterministic offline re-clustering, and a **rebuilt resumable download stack**. Three items on our parked-candidates list matured inside a dependency we already ship.

### Per-competitor deltas

**SuperWhisper 2.14.0 → 2.16.5.** Minimum requirement **raised to macOS 14+** — they dropped Intel/13.3, so the "they hedge because they support old Macs" half of our LLM-cleanup decision record is now weaker (the Apple-Intelligence-gating logic still holds; see that section). Also: `.mov` video transcription (we have this), vocabulary management rebuilt around a combined search-and-create bar with **forced alignment** on Whisper offline models, **paste latency cut by 300 ms**, an experimental **S1-mini** model, **Tone settings**, audio-device favourites/exclusions, and a "no microphone audio detected" warning (our `.noResult` pill predates it).

**Wispr Flow.** Launched **Android**; shipped **Flow Notes** (cross-device notes with transcription, formatting, search) — converging on the Notes module we already built, but cloud-synced. Dictation sessions extended to **20 minutes** (4×). **Personalized Style** sets tone per app category (Very Casual → Formal) — a coarser cousin of our per-app Styles. Following a privacy backlash the CTO publicly apologised; AI-training data use is now **opt-in and off by default**, plus a zero-retention **Privacy Mode**. That backlash is a market signal in our favour, not just gossip.

**FluidVoice — the biggest mover: 8,890★.** Now ships **seven ASR engines** (Nemotron Speech 3.5 ~670 MB/40 languages; **Parakeet Flash beta — 250 MB, lowest-latency English**; Parakeet TDT v3 and v2; Cohere Transcribe; Apple Speech; Whisper) and **"Fluid Intelligence"** — a **~3.5 GB proprietary on-device enhancement model** they deliberately keep **closed while the app stays GPLv3**, explicitly as the monetisation hedge. Plus Command/Write Mode, per-app prompt sets, local audio history with ZIP export, daily usage stats, and a notch-aware overlay. **Parakeet Flash is directly relevant to us** — same FluidAudio stack, half the size of our 494 MB v3, tuned for latency.

**VoiceInk.** 5,674★, pushed today, **240 open issues** (up sharply — support load, not necessarily quality). Still the reference implementation that validated our `audioQueue` serialisation discipline. One-time purchase (~$25), no subscription.

**Aqua.** Still **cloud-only, no on-device mode at all**. Proprietary "Avalon" model; added an iPhone keyboard (April 2026). Reviews flag that transcripts are stored by default unless Privacy Mode is on, and that its headline 97.4% accuracy is a self-published benchmark.

**Willow.** Now has an **optional Offline Mode** — a ~600 MB local model, **Pro-only**, explicitly lower accuracy than its cloud path. So the "cloud-only" label from 2026-07-20 is **out of date**: it's cloud-first with a local fallback. Still not comparable to local-first.

**Granola 7.441.6.** Bundle now **606 MB**. Sentry telemetry directory still present on disk. Schema delta unverified (see method note).

---

## Ghost Pepper — full profile (2026-07-26)

`github.com/matthartman/ghost-pepper` — **2,963★ / 174 forks in four months** (created 2026-03-20, last push 2026-07-22). ~52k lines of Swift + 12.5k of tests. macOS 14+, Apple Silicon only. **The closest competitor we have found**: same pitch nearly word for word, menu-bar-only, Sparkle updates, FluidAudio in the mix, free.

Positioning is explicit and aimed at Wispr: *"it's spicy to offer something for free that other apps have raised $80M to build."*

**⚠ Licence trap — read before borrowing anything.** The README shows an MIT badge linking to `LICENSE`, but **there is no LICENSE file in the repo** and GitHub detects no licence. Default is **all-rights-reserved**. Combined with our GPLv3, this is **ideas-only: copy zero code, zero data models, zero logic.** Any adoption must be a clean first-principles rewrite. (Same rule as FluidVoice, for the opposite reason.)

### Their approach vs ours, feature by feature

| Area | Ghost Pepper | Shhhcribble | Verdict |
|---|---|---|---|
| **ASR** | 5 choices: Whisper tiny/small.en/multilingual (WhisperKit), Parakeet v3, Qwen3-ASR 0.6B | Parakeet V3 only, English | **Them** on choice; **us** on simplicity. Their default is Whisper small.en (466 MB) |
| **Cleanup** | Local Qwen 3.5 GGUF via LLM.swift — 0.8B / 2B / 4B, 535 MB–2.8 GB, ~1–7 s | Apple FoundationModels, 0 bytes, gated on macOS 26 + AI | **Genuine trade.** They cover 100% of users at 535 MB+; we cover ~15–25% at zero bundle cost. Proves the fallback tier is buildable — see decision record |
| **Cleanup safety** | `sanitizeCleanupOutput` strips `<think>` tags only — **no faithfulness check** | `CleanupGuard` (≥80% output words from input, ≥60% content retained) + `PromptFence` nonce | **Us, decisively.** Their cleanup output auto-pastes unvalidated — the exact hole our 2026-07-10 probe found |
| **Hotkey** | **CGEvent tap** → arbitrary chords, incl. **hold a bare modifier** ("Hold Control") | Carbon `RegisterEventHotKey` → fixed presets | **Them on capability.** Carbon *cannot* register a bare modifier. They pay: tap needs Accessibility (they need it anyway) and macOS can auto-disable it, so they carry re-enable logic |
| **Activation** | Explicit push-to-talk / toggle chord bindings | **Smart activation** (tap = toggle, hold = PTT, no setting) + explicit modes | **Us.** Still nobody else does hold-duration inference |
| **Mid-recording route change** | **None.** No `AVAudioEngineConfigurationChange` observer anywhere in `Audio/` | Full teardown + rebuild, samples preserved | **Us.** An AirPods↔Mac switch kills their recording |
| **Cold Bluetooth start** | **No warm-up gating at all** | HAL probe, transport-branched readiness, BT dwell, leading-silence trim | **Us, by a wide margin.** They would have the digital-zero bug verbatim, with no diagnostic to find it |
| **Engine lifecycle** | `prewarm()` (`inputNode` + `prepare()`) from **4 call sites** incl. Settings; realloc on stop | Fresh engine per recording, **never** warmed | **Us.** Their prewarm sits right against our load-bearing rule |
| **Input device** | Explicit picker (`resetForDeviceChange`, `audioUnit` device set) | **Forbidden** — route handlers heal automatically | **Us.** We banned this for lifecycle bugs; they shipped it |
| **Paste** | Cmd+V only; saves **all pasteboard items with all type representations**; `retryLastClipboardPaste()` | AX-first → Cmd+V → clipboard, change-count-gated restore | **Us on insertion** (AX direct is cleaner); **them on clipboard fidelity** and on having a re-paste affordance |
| **Screen context** | **Vision OCR of the frontmost window, prefetched at record-start**, injected as `<WINDOW-OCR-CONTENT>`; user vocab fed to Vision as `customWords` | None | **Them.** Genuinely novel and latency-free — but see the security caveat |
| **Dictionary** | **Learns itself** from post-paste edits (`PostPasteLearningCoordinator`) + manual list | Manual SQLite dictionary, ordered, comma-variant alternation | **Them on acquisition; us on execution.** Our storage and matching are better; theirs fills itself |
| **Correction application** | Soft — injected as `<CORRECTION-HINTS>` for the LLM to honour | Hard — deterministic regex substitution **before** cleanup | **Us.** Deterministic beats hoping the model complies. Theirs degrades silently when the model ignores a hint |
| **Meeting/call detection** | 5 s `Timer` polling whether a known app is **frontmost**; plus **browser meetings by AX window title** and video-site rules | HAL `DeviceIsRunningSomewhere` + AudioProcess attribution — actual mic-in-use | **Us on precision** (theirs fires when Zoom is merely in front); **them on browser coverage** — AX window titles reach Meet/Teams-in-browser, which our HAL path can't name |
| **Both-sides capture** | **Shipped** — ScreenCaptureKit `SCStream` audio + mic, tagged; mic = "Me", system = "Others" | Mic-only; both-sides is unbuilt ROADMAP item 6 (scoped as Core Audio process taps) | **Them.** And their route is **simpler than ours** — worth re-scoping |
| **Long recordings** | Chunked: drain every N s, chunk WAV to disk, 1 s overlap + text dedup, ~3.7 MB resident | Single `[Float]` for the whole recording | **Them.** This exposed a real defect in ours — see below |
| **Diarization** | Voice embeddings persisted across meetings (`SpeakerIdentityResolver`, cosine match, auto-naming) | None | **Them** |
| **Eval tooling** | In-app **Transcription Lab** — stores audio + raw/cleaned + model IDs; **re-run either stage on saved audio** | `Testing/smoke/` harness; logs only, audio discarded | **Them.** Would have made the AirPods bug a five-minute fix |
| **Analytics** | Local-only counters, in-app Usage report (7 / 30 / lifetime) | None at all | **Them on a nice touch**, at no privacy cost |
| **Code structure** | `MeetingTranscriptWindow.swift` = **10,431 lines**; `SettingsWindow` 4,444; `AppState` 3,153 | Modular, one concern per file | **Us, decisively** |
| **Scope** | Dictation + meetings + wiki + cross-meeting Q&A agent + Google Calendar + Trello + Airtable + Granola import | Dictation + Studio | **Us on focus.** Their breadth is why `AppState` is 3k lines |
| **Trust artifact** | **`PRIVACY_AUDIT.md`** — public audit prompt + dated file-level results table | Claims in README only | **Them.** Cheapest high-value idea in the repo |

### Defect this audit exposed in *our* code

Their chunked pipeline made the comparison obvious: our `samples: [Float]` holds the entire recording at 16 kHz mono Float32 = **3.84 MB/min**, and call capture caps at **60 minutes** ([AppDelegate.swift:100](../Shhhcribble/App/AppDelegate.swift:100)). That is **~230 MB resident**, with transient ~460 MB peaks when the array doubles capacity, and a single 60-minute transcribe at the end with **no partial result if anything fails**. Unhit only because call capture has never run end-to-end at length. **Log as a defect against call-capture part A, not as a feature.**

### Ranked adoption list (Ghost Pepper)

1. **Post-paste correction learning** — watch the focused AX element ~15 s after paste, 1 s poll, 2 s quiescence, shared prefix/suffix diff, accept only ≤2-word changes that appeared in the pasted text. Auto-grows the dictionary from the user's own fixes. We have the AX plumbing and a better store; needs a confirmation step so it can't learn silently. **Autonomy-safe, no new permissions, no audio-path risk.**
2. **Chunked capture for long recordings** — fixes the defect above.
3. **Two-stream both-sides capture** — re-scope ROADMAP item 6 from Core Audio process taps to ScreenCaptureKit; costs the Screen Recording permission, and mic-vs-system gives free two-speaker attribution with no diarization model.
4. **`PRIVACY_AUDIT.md` equivalent** — an afternoon; strongest trust signal available to a privacy-first app. We pass today with one honest asterisk (Apple Intelligence cleanup runs through a system framework).
5. **Screen OCR as cleanup context** — biggest accuracy upside for technical dictation, prefetched at record-start so it costs no latency. **Gated on `CleanupGuard` covering that path first** (see below).
6. **Transcription Lab** — keep the audio + both transcripts, allow re-running either stage.
7. **Small:** all-type pasteboard preservation; wire up the stubbed, currently-unused `repaste` in `MenuBarControllerDelegate`.

### Security finding (theirs, and a caveat for us)

Injecting OCR'd screen content into a prompt whose output is **auto-pasted** is a prompt-injection vector where **any web page on screen is the attacker**. Ghost Pepper has **no output-faithfulness guard**, so this is a live vulnerability in their shipping app. If we adopt OCR context, `CleanupGuard` must cover that path **before** it ships — our 2026-07-10 lesson was that framing and prompt-hardening do not stop instruction-following; only output validation does.

---

## Verified capabilities in our current stack

**⚠ We pin FluidAudio `0.13.6` (revision `57551cd9`); current is `0.15.5` (2026-07-07) — two minor versions behind.** Three parked candidates matured inside our own dependency:

- **Custom-vocabulary context biasing** — now with **per-term CTC thresholds** in 0.15.x. Public API: `SlidingWindowAsrManager.configureVocabularyBoosting(...)`, `CustomVocabularyContext`, `CustomVocabularyTerm`, `VocabularyRescorer`. Would let **Personal Dictionary** terms bias Parakeet *at recognition time* — a differentiator no competitor matches at the ASR layer. **Why it's a spike:** it lives on `SlidingWindowAsrManager` (+ a CTC rescorer model), whereas we use plain `AsrManager`. Changes the transcription pipeline, adds a model download. Touches transcription but **not** `AudioRecorder`.
- **Word-level timestamps** (new in 0.15.x, native Swift mel front-end) — worth a look *only* as a curiosity: the paragraphing question is settled in favour of LLM-semantic splitting, and the `PauseSegmenter` revert was caused by TDT absorbing silence into token duration. Don't reopen without new evidence.
- **Sortformer v3 diarization** — BNNS-fixed, deterministic offline VBx re-clustering, progress handlers. Materially more mature than when we last looked; relevant if both-sides capture lands.
- **Rebuilt download stack** — resumable HTTP Range downloads with byte-level progress. Relevant to model-download UX.
- **Streaming ASR** — `StreamingEouAsrManager` / `StreamingChunkSize` public. Matches deferred commit `6509cd7`; still needs an AirPods canary on the VP-free path.
- **Parakeet Flash** (via FluidVoice's catalogue) — **250 MB, lowest-latency English**, vs our 494 MB v3. Same vendor. Worth benchmarking.
- **25-language batch transcription** — Parakeet TDT v3 supports 25 European languages; we hard-code English, gated only by our own cleanup/UI assumptions.
- **File transcription** — `transcribe(_ url:)` / `transcribeDiskBacked(_:)`; already shipped.

## Constraints / corrections

- **License: GPLv3** (chosen 2026-07-08) — `LICENSE` + README notice.
- **FluidVoice is GPLv3** — study patterns, **do not copy** code, data models, or logic.
- **Ghost Pepper has NO licence file** despite an MIT badge → all-rights-reserved. **Ideas only.**
- **Granola schema not re-verified** in this audit (blocked as personal data, correctly). Prior model stands unchallenged, not re-confirmed.
- **SuperWhisper / Wispr deltas are vendor-stated**, not statically verified — their local bundles are frozen at May versions.

---

## Side-by-side

| | **SuperWhisper** | **Wispr Flow** | **Ghost Pepper** | **FluidVoice** | **Shhhcribble** |
|---|---|---|---|---|---|
| Stack | Native Swift, **macOS 14+** | Electron, macOS 12+ | Native Swift, macOS 14+, **AS-only** | Native Swift | Native Swift, macOS 14+ |
| Version | 2.16.5 | 1.5.x | — | — | 1.13.0 |
| Bundle | 133 MB | 497 MB | ~30 MB + models | ~3.5 GB w/ model | **~30 MB** |
| ASR | WhisperKit + Parakeet V3 | Cloud-only | Whisper / Parakeet / Qwen3-ASR | **7 engines** | Parakeet V3 (FluidAudio) |
| Local LLM | llama.cpp, 6 families | None | **Qwen 3.5 GGUF** (LLM.swift) | **"Fluid Intelligence" 3.5 GB, closed** | Apple FoundationModels |
| Cloud LLM | 8 via proxy | All cloud | Opt-in only | Opt-in | **None** |
| Cleanup guard | — | "Undo AI Edit" | **None** | — | **`CleanupGuard` + `PromptFence`** |
| Storage | GRDB SQLite | `flow.sqlite` (14 tables) | Markdown on disk | — | **SQLite (schema v12)** |
| Auto-update | Sparkle | Squirrel | Sparkle | — | **Sparkle** |
| Telemetry | Sentry | Sentry | **None** (local counters) | — | **None** |
| Accounts | Yes | Yes | **No** | No | **No** |
| Both-sides capture | `useSystemAudio` | Meetings | **ScreenCaptureKit** | — | Not built |
| Voice-edit mode | — | **Command Mode** | — | **Command + Write Mode** | **Not built** |
| Licence | Proprietary | Proprietary | **None (badge lies)** | GPLv3 | **GPLv3** |

---

## SuperWhisper's killer feature: the Modes system

A mode lives at `~/Documents/superwhisper/modes/*.json` and carries:

- `activationApps[]`, `activationSites[]` — **auto-switch by frontmost bundle ID / URL**
- `prompt`, `promptExamples[]`, `contextTemplate`
- `contextFromActiveApplication`, `contextFromClipboard`, `contextFromSelection`
- `languageModelID`, `voiceModelID`
- `realtimeOutput`, `script` / `scriptEnabled`
- `translateToEnglish`, `literalPunctuation`, `autocapitalizeInsert`, `diarize`, `useSystemAudio`

Ships **`bundled_app_info.json`** — a **686-app catalog** mapping apps → one of **43 text-input formats** (top: `configuration_settings` 98, `file_path` 67, `plaintext` 53, `chat_message` 51, `design_parameters` 43, `code` 30, `terminal_command` 28, `email` 15, `sql` 6…). Dictating into Cursor formats as `code`; Mail as `email`; Slack as `chat_message`. Plus `agent-hook` (Swift Mach-O) + `claude-hook` (shell).

**Status:** we shipped the core of this as **Custom Styles** (per-app activation, seeded presets, import). `contextFromActiveApplication` / `contextFromSelection` remain unbuilt — and Ghost Pepper's OCR route is a stronger version of the same idea.

## Wispr Flow is a productivity suite, not just dictation

`flow.sqlite` — 14 tables:
- **History** (51 columns): `asrText` / `formattedText` / `editedText` tiers, `audio` + `screenshot` BLOBs, `axText` + `axHTML` (full accessibility context per dictation), `e2eLatency`, `formattingDivergenceScore`, `fallbackAsrText` / `fallbackFormattedText`, `toneMatchedText`, `numDictionaryReplacements`, `personalizationStyleSettings`.
- **Dictionary**: `phrase`, `replacement`, `frequencyUsed`, `isSnippet`, `isStarred`, `teamDictionaryId`.
- **Polish**: every LLM cleanup logged + **undoable** — now shipped user-facing as **"Undo AI Edit"**.
- **FlowLensHistory**, **Notes / NoteVersions / NoteImages**, **Meetings / MeetingVersions**, **CalendarEvents**, **Links**.
- `config.json` defines ~20 error-notification states.

Note the `editedText` column and `formattingDivergenceScore`: **they have been recording post-paste user edits all along.** Ghost Pepper closed the loop and learns from them. That is the same signal, twice.

---

## LLM cleanup — decision record

**Decision (unchanged): Apple Foundation Models, prototype-first. `FillerWordFilter` stays the universal fallback. Do NOT bundle local llama.cpp.**

- Apple FM = **zero bundle weight, zero cost, zero config, zero API keys** — preserves the no-cloud / no-telemetry pitch.
- **Progressive enhancement**: `FillerWordFilter` for everyone; FM cleanup for the eligible ~15–25%.
- Eligibility: macOS 26+, Apple Silicon, Apple Intelligence on, supported region/language, not MDM-disabled. Gate: `SystemLanguageModel.default.availability`.

**2026-07-26 pressure on this decision — record it honestly:**
- The original reasoning leaned on "SuperWhisper hedges only because it supports macOS 13.3 / Intel." **SuperWhisper now requires macOS 14+ too**, so that specific argument no longer distinguishes us. The load-bearing half still holds: macOS **14+** ≠ macOS **26 + Apple Intelligence**, and only the latter gets FM.
- **Ghost Pepper proves the fallback tier is buildable and shippable** — Qwen 3.5 0.8B at 535 MB, ~1–2 s, via LLM.swift. Consistent with our 2026-07-20 research (llama.cpp static + Qwen2.5-0.5B, opt-in download).
- **FluidVoice went the other way**: a 3.5 GB closed enhancement model as the monetisation hedge. Not a path open to us at GPLv3, and not one we'd want.
- **Reframe still stands:** Parakeet already emits punctuation and capitalisation, so the non-FM tier is not "unpunctuated soup" — the real gap is paragraphing and false-start repair. That keeps the bar for a bundled LLM high. **Decision unchanged; revisit only if macOS 26 adoption stalls.**

---

## Deliberately NOT copying (privacy / focus as differentiators)

- Wispr Flow's notes/meetings/calendar/agent-chat *suite*, and **Ghost Pepper's wiki + cross-meeting Q&A + Trello/Airtable/Calendar** — the same scope creep, twice. Their `AppState.swift` is 3,153 lines because of it.
- **Telemetry / Sentry** — zero-telemetry is a real differentiator, and Wispr's 2026 privacy backlash proves the market notices.
- User accounts / sign-in.
- **Input device picker** — forbidden; route handlers heal automatically. (Both SuperWhisper and Ghost Pepper ship one.)
- Persistent on-disk recording archive — privacy concern. *(Note the tension: a Transcription-Lab-style audio archive would be exactly this. If adopted, it must be explicitly opt-in and locally purgeable.)*
- **Cleanup without an output guard** — Ghost Pepper's approach; unsafe on an auto-paste path.

## What Shhhcribble already wins on

- **Smart activation** (tap = toggle, hold = PTT, no setting) — still unique across all eight competitors.
- **Cold-Bluetooth correctness** — HAL probe, transport-branched readiness, dwell backstop, leading-silence trim. **No competitor examined shows this care**; Ghost Pepper has none of it.
- **Mid-recording route rebuild** — Ghost Pepper has no configuration-change observer at all.
- **VP-free AirPods reliability + fresh-engine-per-recording.**
- **Cleanup output validation** (`CleanupGuard` + `PromptFence`) — nobody else validates that cleanup didn't fabricate or drop the user's words.
- **Deterministic dictionary substitution before cleanup** — vs Ghost Pepper's soft prompt hints.
- **Music-pause via AppleScript** — SuperWhisper bundles `MediaRemoteAdapter.framework`, dead on macOS 26 per our 2026-05-06 testing.
- **~30 MB native bundle**; **zero telemetry, zero cloud, zero accounts.**
- **Modular codebase** — the clearest structural advantage over Ghost Pepper.

---

## Emerging gaps (ranked, cross-competitor)

1. **Voice-edit-existing-text** (Command / Write Mode) — FluidVoice **and** Wispr. Our biggest capability gap.
2. **Revert-to-raw / cleanup intensity dial** — Wispr shipped it; we already store `rawText`. Cheapest win.
3. **Self-learning dictionary** — Ghost Pepper shipped it; Wispr has the data to.
4. **Both-sides capture** — Ghost Pepper shipped it via a simpler route than we scoped.
5. **Screen context for cleanup** — Ghost Pepper (OCR) and SuperWhisper (`contextFrom*`).
6. **Browser meeting detection** — AX window titles reach what our HAL path can't name.
7. **Local usage stats** — Ghost Pepper and FluidVoice; costless, privacy-safe.

## Dropped ideas (with reason)

- **Translate-to-English** — *not possible with our engine.* FluidAudio/Parakeet V3 is transcription-only (verified v0.13.6 source). SuperWhisper's flag works only via WhisperKit.
- **Bundled local llama.cpp** — heavy, fights lean-native identity. Revisit only if macOS 26 adoption stalls. *(Ghost Pepper proves feasibility; the reframe above keeps the bar high.)*
- **Proprietary closed enhancement model** (FluidVoice's "Fluid Intelligence") — incompatible with GPLv3 and with our pitch.

## Already resolved (don't re-propose)

- **Input-device picker** — forbidden.
- **Warm engine across recordings** — anti-pattern; fresh-engine-per-recording is load-bearing.
- **Pasteboard restore after paste** — shipped. *(Open refinement: preserve all pasteboard types, not just the string.)*
- **`noResult` / honest empty-transcription state** — shipped; SuperWhisper added the same warning in 2.16.x, after us.
- **Streaming transcription** — deferred (commit `6509cd7`); needs an AirPods canary.
- **Per-app style activation** — shipped as Custom Styles.
