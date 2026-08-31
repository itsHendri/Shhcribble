# Studio IA rework — Dictations · Notes · Settings, pin removal, Trace-style stickies

## Context

Workshopped with Hendri 2026-08-28 (wireframe session, four forks ruled via structured
questions — all recommendations accepted). His live usage surfaced three failures of the
shipped redesign: **"Today" lies** (it's a day navigator whose forward chevron steps into
guaranteed-empty future days); **Documents vs Notes is a split he doesn't feel** (two
structurally identical master-details, and at his real ratio — ~610 dictations : ~8
documents — the timeline's document anchor cards never registered); and **the pin/stick
split failed in use** ("I keep pinning things but actually wanting to stick them" — pin
never sticks, and the Pinned board's manage-stickies job evaporated when stickies became
tabs in one panel). Reference for the sticky redesign: **Trace**
(https://john-mrty.github.io/Trace/) — chromeless overlay, words-are-the-interface,
summoned formatting.

## Locked decisions (supersede the current studio-wireframes.md contract)

1. **Rail: Dictations · Notes · Settings** (five → three). Today renamed **Dictations**;
   Documents and Pinned tabs die.
2. **Timeline is dictations-only.** Document cards leave the stream. Forward chevron
   disabled when shown day is today; month popover future days inert.
3. **Documents (.file/.call) merge into the Notes list** — one day-grouped list of notes
   + documents, told apart by a quiet glyph. Note → rich-text editor detail; document →
   existing Transcript | Summary reader detail (moves house, unchanged behaviour).
4. **Pin removed entirely.** Stick is the only lifecycle; `setNoteStuck` no longer
   auto-pins. Stuck notes get an **"On your screen"** group (recency-ordered) atop the
   Notes list. `pinned` columns stay in the schema, unwritten (rollback discipline, like
   `pinX/pinY`). **No schema bump anywhere** (stays v13).
5. **Sticky panel, Trace-inspired:** tab strip is the only chrome; tighter edge-to-edge
   insets; formatting capsule (B/I/U/Highlight) summoned over a selection (right-click
   menu + key equivalents stay — they're pinned by RichTextTests); free resize replaced
   by **compact ⇄ expanded** fixed sizes, one toggle, top-left-anchored.
6. Search everything stays on Dictations; result groups stay Notes → Dictations →
   Documents (`Search.swift` unchanged); a document result now jumps to the **Notes** tab.

No phase touches `AudioRecorder`/routing/`MusicPauser`/`TextInserter` → **no hardware
smoke test triggered**. Every phase updates `docs/design/studio-wireframes.md` + `.html`
(living docs, in place) and CLAUDE.md — the contract moves first (StudioShellTests'
failure message demands it, `ShhhcribbleTests/StudioShellTests.swift:16`).

## Phase 0 — contract update (with phase 1's branch)

Rewrite `docs/design/studio-wireframes.md` + `.html` in place: new IA, pin section
replaced by "stick only + On your screen group", sticky two-mode spec, retired-decisions
notes (Pinned board, pin lifecycle, free resize, five-item rail — moved to "explicitly
retired" so they don't sneak back).

## Phase 1 — Dictations-only timeline + dateNav clamp (branch `timeline-dictations-only`)

- `Storage/Timeline.swift`: `items(on:)` (:58), `daysWithContent` (:71), `openingDay`
  (:89), `mostRecentDayWithContent` (:105) all filter `!isDocument` — exclusion at the
  pure layer so month dots and the stream can never disagree (same reasoning as the
  notes exclusion). New pure `canStepForward(from:now:calendar:)` and
  `isFutureDay(_:now:calendar:)`.
- `UI/TodayView.swift`: delete `documentCard` (:244), `pinGlyph` (:259),
  `documentSubtitle` (:468), dead `noteSubtitle` (:477), the `isAnchored` branch in
  `row` (:194). Forward chevron (:160) `.disabled(!Timeline.canStepForward(...))`.
  `MonthPicker.dayCell` (:570): future days dimmed + disabled. Follow-new-work
  `onChange` (:92) guards `!newest.source.isDocument` (a finishing import must not yank
  the day). Keep `isAnchored`/`typeLabel` — search results still use them (`Search.swift:63`).
- Rename lands in phase 3 with the rail (one rail rewrite, not two labels).
- Tests: invert `testItemsMergesDictationsAndDocuments…` → excludes documents; new clamp
  tests (today/yesterday/future, midnight boundary, pinned Europe/London calendar);
  document-only day excluded from dots/openingDay.

## Phase 2 — pin removal, rail 5 → 4 (branch `remove-pin`)

- `Storage/TranscriptStore.swift`: delete `setNotePinned` (:762), `setTranscriptPinned`
  (:788), `pinnedNotes` (:902), `pinnedTranscripts` (:927), `pinnedBoardContents` +
  `PinnedBoardContents` (:888–899). `setNoteStuck` (:776) drops the auto-pin (:779).
  **Keep** `pinned` fields, INSERT/UPDATE bindings, loaders, and v10/v11 migrations
  byte-identical. `stuckNotes` (:906, recency) now orders the On-your-screen group;
  `stuckNotesInTabOrder` untouched (StickyPanelManager diffs on it — verified :248).
- `UI/StickyNotePanel.swift`: `createStickyAtCursor` (:234) drops `note.pinned = true`.
- `UI/TranscriptionsView.swift`: drop `.pinned` rail case; delete `pinnedPane` (:247) +
  `PinnedBoard` (:511–697; verified private, single caller); strip pinned section/filter
  + pin controls from `TranscriptListPane` and `TranscriptDetail` (actions → copy · delete).
- `UI/NotesView.swift`: "Pinned" section (:72–78) → **"On your screen"** fed by
  `store.stuckNotes`; `pinnedMatches`/`unpinnedMatches` → stuck/unstuck; delete pin
  glyphs/buttons/toasts; `NoteDetail` header → dictate · copy · delete;
  `discardIfUntouched` (:546) drops the `!pinned` condition.
- Docs: rewrite `Note.pinned` struct doc (:106–112) + CLAUDE.md pin-vs-stick section to
  "retired column, preserved unwritten" — or the next session re-implements auto-pin
  from the docs.
- Tests: auto-pin/board/pin-round-trip tests die; migration tests stay green untouched;
  new `testStickingDoesNotWritePinned` (pins the rollback discipline) and
  stuck-group-recency test. StudioShellTests → 4-item intermediate.

## Phase 3 — documents into Notes, rail 4 → 3, rename (branch `notes-library-merge`)

- **Selection model:** shell-owned
  `enum NoteListSelection: Hashable { case note(UUID); case document(UUID) }` replacing
  `noteID`/`documentID` (`TranscriptionsView.swift:34–37`). Enum, not two optionals —
  illegal states unrepresentable; search writes it directly. Shell-owned because the
  shell's detail `switch` is a `_ConditionalContent` (the documented @State trap).
  Inside NotesView the note↔document detail switch is also conditional and that's fine:
  both details rebuild via `.id(...)`, `NoteDetail` flushes on `.onDisappear`, and the
  pane's ToastState lives on NotesView, not in a branch.
- **New pure `Storage/NotesLibrary.swift`:** `enum NoteOrDocument: Identifiable` (id =
  `NoteListSelection`), `merged(notes:documents:)` newest-first + id tie-break (the
  `Timeline.items` pattern), feeding the existing generic `Timeline.grouped`
  (`Timeline.swift:136`) for day groups. Store predicates stay on the store: reuse
  `documents(matching:)` (:879), add `notes(matching:)` lifting NotesView's inline filter.
- `UI/TranscriptionsView.swift`: `RailSection` → `dictations, notes, settings` (label
  "Dictations"); delete `documentsPane`, `documentSearchText`, `TranscriptListPane` +
  `TranscriptRow`. Move `TranscriptDetail` (:766–1083) to new `UI/TranscriptDetail.swift`.
  File-job jump (:131) targets `.notes`; progress banner + Cancel move into the Notes
  list column. Search wiring: note result → `.note(id)` + `.notes`; document result →
  `.document(id)` + `.notes`.
- `UI/NotesView.swift`: binding → `NoteListSelection?`; merged rows (document rows get a
  quiet tertiary glyph + copy-only hover); detail switch note→NoteDetail /
  document→TranscriptDetail; empty-state copy covers both kinds.
- **Upload Audio placement (flagged for visual pass):** Notes keeps its single
  "Add Note" capsule; Upload Audio… stays on the menu-bar right-click (already there,
  `MenuBarController.swift:100`) and the Dictations empty-state capsule (already there,
  `TodayView.swift:432`). One-capsule rule holds with zero new chrome. Fallback drawing
  if discoverability worries him: Add capsule with a small trailing menu.
- Also flagged for visual pass: Dictations rail icon (mic vs calendar).
- Tests: StudioShellTests → 3-item rail; new NotesLibraryTests (merged ordering,
  tie-break, identity mapping, stuck-group exclusion); SearchTests untouched.

## Phase 4 — sticky panel redesign (branch `sticky-two-modes`)

Touches only `StickyNotePanel.swift` + `RichTextEditor.swift` (+ DesignSystem).

- **Sizing:** drop `.resizable` (:66) + min/max (:82–83). `compactSize` ≈ 320×260,
  `expandedSize` ≈ 520×560 (values to visual pass); toggle glyph in tab strip beside +.
  New pure `StickyPanelGeometry.frame(togglingTo:from:screen:)` — top-left anchored
  (AppKit origin is bottom-left: `newOrigin.y = frame.maxY − newHeight`), clamped to
  `visibleFrame`. Persist: new UserDefaults `stickyPanelMode`; keep writing
  `stickyPanelFrame` (old builds restore a legal frame); mode toggle fires
  `didResizeNotification` so the existing debounced persist covers it. CLAUDE.md pref
  table updated.
- **Chrome:** there is no titlebar band today — the work is tightening editor insets
  from 8×4 (:535) toward edge-to-edge (~4–6pt; 0 clips descenders into the corner
  radius) + tab-strip restyle per Trace.
- **Formatting capsule:** `RichTextEditor` gains `onSelectionChange:` via
  `textViewDidChangeSelection` (+ `firstRect(forCharacterRange:)`); StickyView overlays
  a B/I/U/Highlight capsule calling the existing `toggleBoldTrait`/… actions
  (`RichTextEditor.swift:437–541`) through `NoteEditorProxy`. Right-click menu (:384)
  and `performKeyEquivalent` (:356) untouched. Risk: capsule clicks must not steal first
  responder (selection collapses) — `.plain` buttons in `FirstMouseHostingView`; escape
  hatch is `NSButton` with `refusesFirstResponder`. Clear rect on tab switch/activate.
  The toggles go through `shouldChangeText`/`didChangeText`, so the existing
  `hasPendingEdit`/`onUserEdit` save discipline covers the new path — verify manually
  (type → style → tab-switch).
- Tests: StickyTabsTests survive untouched; new StickyPanelGeometryTests (anchor both
  directions, edge clamping), mode round-trip, rect-cleared-on-activate.

## Rulings already made (don't reopen)

- Month dots/openingDay exclude documents — dots must agree with the stream. The
  "import vanished" moment is covered by the file-job jump landing on Notes (phase 3).
- "On your screen" group orders by recency (matches the dead board's strip).
- Phases 2 and 3 stay separate branches despite two StudioShellTests rewrites — the
  4-item rail is a legal shippable intermediate, and one-feature-per-branch is a paid-for
  lesson.

## Self-evaluation checklist (claims to re-verify while implementing, not assume)

- **Phase 1:** confirm `TodayView`'s search-results rendering does NOT share
  `documentCard` before deleting it — search results keep the two-weights treatment
  (`Search.swift:63`), so if they render through it, extract a results-only card first.
- **Phase 2:** after the deletions, `grep -rn "pinned" Shhhcribble/UI/` must return only
  the retired-column comments — no live UI reference survives. Migration tests
  (`testV9StickiesBecomeStuckAndPinned`, `testInterruptedV10DoesNotClobberDivergedFlags`,
  `testTranscriptsPredatingThePinColumnLoadUnpinned`) must pass byte-untouched — if one
  needs editing, the store change went too far.
- **Phase 3:** `RailSection` raw values are not persisted anywhere (re-verify before
  renaming); `TranscriptDetail` move is file-move-only (no behaviour diff in the same
  commit); **document rows get no stick affordance** — stick stays notes-only;
  `NotesView`'s existing selection-survives-rail-round-trip behaviour still holds with
  the enum selection.
- **Phase 4:** `StickyPanelManager.sync()` diff on `stuckNotesInTabOrder` untouched;
  the format-capsule buttons carry accessibility labels; manually verify
  type → style-via-capsule → tab-switch loses nothing (the `hasPendingEdit` discipline
  covers it in theory — prove it by hand).
- **Every phase:** `TranscriptStoreTests`' `latestSchemaVersion` check still reads v13 —
  any schema bump means the plan was violated. One-capsule-per-column audit and
  toast-rule audit over every touched pane before review.

## QC gates — Definition of Done, per phase (project loop, tailored)

1. `xcodebuild -scheme Shhhcribble -configuration Debug build` green.
2. `xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' test`
   green — including the new tests named in each phase above.
3. Adversarial `/code-review` (and `/security-review` for phase 3, which rewires
   navigation) finds no confirmed issue; iterate implement→review→fix max ~3 rounds,
   then stop and escalate rather than loop.
4. Regression checklist: no `AudioRecorder`/routing/`MusicPauser`/`TextInserter` touch,
   no VP / device-picker, pref table intact (+`stickyPanelMode` documented in phase 4),
   no schema bump, one feature per branch.
5. `CHANGELOG.md [Unreleased]` updated; `studio-wireframes.md` + `.html` updated in
   place; CLAUDE.md updated (retired pin decision, pref row, loop-progress note) in the
   phase that changes it.
6. Honesty gate — surfaced, never silently skipped: **human visual pass required before
   each UI phase merges** (rail icon mic-vs-calendar, document-row glyph, Upload Audio
   discoverability, sticky sizes/insets/capsule), and phase 4's capsule-focus risk is
   hand-verified, not claimed.

## Verification (end-to-end, after phase 4)

Launch the dev build (expect the Accessibility re-grant after a fresh build):
chevron dead on today, month future days inert; an import lands in Notes (list + reader
+ Summary) and the shell jumps there; a call capture lands in Notes; stick/unstick
round-trips with the On-your-screen group; sticky compact⇄expand keeps its top-left
corner on screen at every screen edge; format capsule appears over a selection without
collapsing it; ⌘B and right-click still style; search from Dictations opens note and
document results in Notes.
