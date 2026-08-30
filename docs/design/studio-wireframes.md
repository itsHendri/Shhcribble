# Studio wireframes — decision record

**Living document** — updated as wireframe iterations continue; the current
state supersedes older entries in place. Last major revision: **2026-08-28**
(IA rework locked with Hendri; supersedes the 2026-07-24/25 five-item shell).
Wireframes: [studio-wireframes.html](studio-wireframes.html) (open in any
browser; light + dark; keep it in sync with this file). This document is the
contract for implementation — if a build decision contradicts it, stop and
re-check here first.

## The reframe that drives everything

Shhhcribble is a **mix of a dictation utility and a note-taking app**, and the
two halves have different physics:

- **Dictations** are high-frequency and semi-throwaway. They're kept for
  *recovery* (a paste that missed) and *reuse* (re-copy an old prompt), not as
  documents. They never needed a master-detail reader.
- **Everything you keep** — written notes, uploaded files, videos, call
  captures — is one shelf. A note and a document differ in how they were made
  and how they're read, not in what they're *for*: both are things you return
  to. Splitting them across two rail items spent a nav slot on a distinction
  nobody feels (Hendri, 2026-08-28).

So the app is **two halves, not four**: the stream of what you said, and the
shelf of what you keep. The rail says exactly that.

## Information architecture

Rail (three items, every screen): **Dictations · Notes · Settings**. The
titlebar always reads "Shhhcribble" — the rail's active state is the location
indicator; the title never restates it.

- **Dictations** — single chronological stream of **dictations only**, scoped to
  one day. Notes left the stream 2026-08-10 (this is what you *said*; a note is
  what you *wrote*); **documents left 2026-08-28** for the neighbouring reason —
  an import or a call is long-form material you *keep*, so it belongs on the
  shelf. What remains is one honest thing, which is why the tab is no longer
  called "Today": that name never matched a pane you can page backwards through.
  Rows are borderless lines, **always fully expanded — no truncation** (scroll
  carries the length; revisit only if it ever feels overwhelming). **"No
  truncation" binds the stream, not every surface** — search results trim a
  dictation, because a list of matches is a different job from the record of
  what you said. Rows render at full-strength label colour (revised 2026-07-27):
  greying them is what made the stream read as inactive. **Time sits at the
  row's trailing edge**, not in a left gutter, so every item's content starts on
  one left edge; search results carry their date on the same edge. **The meta
  line reads copy · word count · style tag … delete**, and the asymmetry is
  deliberate: copy is the reason the screen exists, so it *leads* the line and is
  always visible; delete is the one thing you'd hate to hit by accident, so it
  sits at the far right and only on hover. That one hover control is why the row
  still needs its `contentShape` — see the cross-cutting rule. Add-to-note was
  removed from the stream (`addNoteFromDictation` stays on the store, unused).
  **Date: chevrons step a day, and forward is disabled on today** (2026-08-28) —
  you can't dictate into the future, so the only thing a forward step could
  reach is a blank page; the month popover greys future days for the same reason,
  and carries dots on non-empty days + "Jump to today". The date navigator steps
  aside while a search is active, since results span every day.
  **All day questions filter identically** (`Timeline.streamable`): a dot over a
  day that opens empty is a bug this exclusion exists to prevent.
- **Notes** — master-detail over **one merged shelf: notes and documents
  together**, day-grouped, told apart by a quiet glyph on the document rows.
  List groups: **On your screen** (stuck notes, recency-ordered), then day
  groups ("Today", "Earlier this week", …). Row hover swaps the date for copy.
  Detail depends on the row: a note opens the **rich-text editor** (existing
  type ramp), header actions **dictate · copy · delete**; a document opens the
  **Transcript | Summary reader**, tabs spanning the full reader width, header
  actions **copy · delete**. **Summaries exist only on documents.** Only notes
  can be stuck — a document isn't something you put on your screen.
  Dropped everywhere: reveal-in-Finder (sources are often ephemeral — WhatsApp
  files, deleted uploads; the transcript is the durable artifact) and download
  (a .txt sidecar is already written automatically at transcription time).
- **Settings** — one rail item, master-detail. Subnav column: **Preferences ·
  Styles · Dictionary · Feedback**, with **Check for updates · Quit** anchored
  at the subnav bottom. Menu-bar right-click Quit remains (the CLAUDE.md "Quit
  must stay reachable" invariant holds). Rationale for demoting Styles: quick
  *switching* lives in the menu-bar Style submenu + per-app auto; the page is
  for authoring, which is occasional.

## Stick — the only lifecycle (pin is retired)

**Pin was removed entirely on 2026-08-28.** It had been split from stick on
2026-07-25 (pin = importance, stick = urgency, sticking auto-pins), and the
split failed in use: *"I keep pinning things but actually I'm wanting to just
stick them to my screen."* Two verbs where the user only ever meant one, and the
Pinned board's stated job — "the only place to manage stickies" — had already
evaporated when stickies became tabs in one panel that manages itself.

- **Stick** puts a note on screen as a floating sticky. Its control is the
  **floating capsule over the editor**, whose label *is* the state ("Stick to
  screen" ↔ "Unstick") — which is why no separate "on screen" tag is needed.
  Keep it spelled out; nothing else on screen says whether a note is stuck.
- Stuck notes surface in the **"On your screen"** group at the top of the Notes
  list, recency-ordered (`stuckNotes`), with the desktop glyph.
- **Notes only.** A document is not something you put on your screen.
- The `notes.pinned` and `transcripts.pinned` **columns stay in the schema,
  unwritten** — same rollback discipline as `pinX/pinY/pinW/pinH`. Nothing
  reads or writes them; the v10/v11 migrations stay byte-untouched. **No schema
  bump.** If a doc or comment still describes auto-pin behaviour, it is rot —
  fix it, or the next session re-implements a retired feature from the docs.

**Stickies are tabs in one panel** (2026-08-10, borrowed from Wispr's
Scratchpad). **Tabs are presentation; stick/unstick remains the only
lifecycle** — closing a *tab* unsticks that note (keeping the Discard-if-empty /
Unstick-if-content confirm), the panel disappears on its own when the last tab
goes, so **there is no window close button and no new destructive semantics**.
Tab order is creation order (`stuckNotesInTabOrder`), never the recency order —
recency changes on every keystroke and would reshuffle tabs mid-sentence. The
panel frame and active tab live in UserDefaults. The load-bearing risk is that
only the active tab has a live `RichTextEditor`, so a tab switch destroys one
editor and creates another: **the debounced save must flush first** or the last
keystrokes are lost — the `hasPendingEdit` / `onUserEdit` discipline is what
makes that tractable; reuse it rather than reinventing focus tracking.

## The sticky panel — a quiet writing surface (2026-08-28)

Reference: **Trace** (https://john-mrty.github.io/Trace/) — "the words are the
interface". What we take is its chrome discipline, not its feature set.

- **The tab strip is the only chrome.** No titlebar band; text runs to the
  edges (a small inset only — 0pt clips descenders into the corner radius).
- **Formatting is summoned, not resident:** a floating capsule (B / I / U /
  Highlight) appears over a selection. The right-click menu and ⌘B/⌘I/⌘U stay
  exactly as they are — they're pinned by `RichTextTests`, and **there is still
  no Format menu** (an LSUIElement app's main menu swallows the key equivalent;
  that bug shipped twice).
- **Two sizes, not free resize: compact ⇄ expanded**, one toggle in the tab
  strip. Free resize and the per-pixel persisted frame are retired — deliberate
  sizes read calmer and remove a fiddly edge. The toggle **anchors the top-left
  corner** (AppKit's origin is bottom-left, so the origin's y must move) and
  clamps to the visible screen.

## Cross-cutting rules

- **The floating capsule is a column's single primary verb** — Add Note (the
  Notes shelf), Upload Audio… (the Dictations empty state), Stick/Unstick (note
  editor). One capsule per column — **without exception**. With the shelves
  merged (2026-08-28) the Notes column keeps **Add Note** as its one verb, and
  **Upload Audio… lives on the menu-bar right-click menu** (plus Finder's
  Open-With, and the Dictations empty state). ⚠ **Open for the visual pass:** an
  earlier draft of this rule called the Dictations empty state a standing
  fallback. It isn't — it only renders on a day with *no* dictations, so on any
  active day the menu bar is the only in-app route. If that reads as too hidden,
  the sanctioned fix is the Add Note capsule with a small trailing menu carrying
  Upload Audio… — one capsule, two verbs.
  The standing tie-break still applies: where the wireframes'
  drawings and prose disagree, **the wireframe wins unless it's technically
  impossible**.
- **Search**: only the Dictations pane's "Search everything" crosses categories —
  results replace the timeline, grouped **Notes → Dictations → Documents** (was
  written as "library order", which is undefined for dictations: they have no
  rail item) then dated, matches highlighted, Esc/✕ restores the day. **Note and
  document results both open in Notes**, which is now one shelf. The Notes search
  pill filters its own list inline, no custom results view.
- **Empty states** teach the pane's verb with a real CTA; Dictations teaches the
  hotkey (keycap style) and offers **one** capsule (Upload Audio…). Dictations
  also has a *quiet-day* variant ("Nothing on this day") for a past day that
  happens to be empty — distinct from the library-empty state. The Notes empty
  state must speak for **both** kinds of thing on the shelf, not just notes.
  Capsule labels follow macOS title case ("Add Note", "Upload Audio…") rather
  than the sentence case used in this document's prose.
- Action rows stay minimal: no download anywhere (copy covers it), no reveal.
- All existing DesignSystem tokens carry over (neutral fills over primary,
  radius roles, chrome type ramp). Selection stays neutral; **accent only for
  links and search-match highlights** (tightened 2026-07-27 — the hover copy
  glyph and the reader's source icon gave it up: an accent that appears on every
  row on hover reads as a selection, and colouring an identity glyph made it
  read as a status).
- **Prefer a permanent control to a hover-revealed one** for anything a user
  reaches for repeatedly. Hover-reveal costs a hover *and* a decision, and it
  hides the tooltip that would explain the glyph. Where a row does still reveal
  on hover (the Notes shelf rows), the whole row must be the hover target via an
  explicit `contentShape` — `onHover` hit-tests drawn content, so a row with
  transparent space dismisses itself as the pointer crosses it.
- **Every action whose result isn't visible on screen flashes a toast** — copy
  above all. One `ToastState` per pane, one `.toast(state)` anchor; see
  `DesignSystem.swift`. (The pin/unpin toasts went with pin.)

## Rulings (historical; don't reopen without new evidence)

- ~~**Today's empty state: one capsule or two?**~~ **RULED: one.** The
  two-capsule carve-out died with notes leaving the stream.
- ~~**Can a dictation be pinned?**~~ **Moot as of 2026-08-28** — pin is gone
  entirely. Nothing is pinned; notes are stuck.
- ~~**What does the stream contain?**~~ **RULED 2026-08-28: dictations only.**
  Notes left 2026-08-10; documents followed, to the merged Notes shelf. Every
  day question filters identically (`Timeline.streamable`), so month dots, the
  opening day and the stream agree. Pinned by
  `testItemsAreDictationsOnlyNewestFirst` and
  `testDocumentOnlyDayIsInvisibleToEveryDayQuestion`.
- ~~**Can the stream step into the future?**~~ **RULED 2026-08-28: no.** Forward
  chevron disabled on today, month-grid future days inert. Pinned by the
  `canStepForward` / `isFutureDay` tests.
- **"Search everything" still crosses into notes** from the Dictations pane;
  results open on the Notes shelf. Kept deliberately — a global search is worth
  more than the consistency — but it is the one place the pane has a second
  personality. Revisit if it reads as a leak.
- **Embedded dictation blocks** (2pt left rule, quoted text, "From a dictation,
  <date>" with mic glyph) are specified for Notes but **not built**. The left
  rule needs custom text-view drawing; the attribution line is cheap.

## Explicitly retired (removed on purpose — don't rebuild from an old doc)

- **Pin, the Pinned rail tab, and the Pinned board** — retired 2026-08-28; see
  "Stick — the only lifecycle" above. The columns survive for rollback only.
- **Free-resize stickies** and the per-note `pinX/pinY/pinW/pinH` placement —
  replaced by compact ⇄ expanded; the columns survive for rollback only.
- **The Documents rail tab** — merged into Notes. `isDocument` still divides the
  two halves everywhere it matters; it just no longer earns a nav slot.
- **The "Today" name and the two-weights stream** — the stream is dictations
  only. Two weights survive in search results.

## Explicitly deferred (documented so they don't sneak in)

- **Richer notes: images, image grids.** Attachments survive the keyed-archive
  storage in principle; layout/grids are untested and undesigned.
- ~~**Dictate-into-a-note with a "note style"**~~ — **REOPENED AND BUILT
  2026-08-10.** Rulings from that design session: the microphone button reuses
  the existing capture pipeline but delivers **straight into the editor** (no
  clipboard, no synthetic ⌘V — the button takes focus off the text view, so the
  ordinary paste path has nowhere to land); notes **always** use the faithful
  cleaner, because per-app style activation would otherwise resolve against our
  own bundle id; the dictation **still appears in Today**, which stays the record
  of what you said wherever the words went; and transforms **reuse the user's
  existing styles** rather than a free-text instruction box, since note text can
  come from a transcript and a free prompt over untrusted content would be the
  widest injection surface in the app. **Safety net is undo only** (human's call)
  — with one recorded limit: a sticky's undo stack is cleared on tab switch, so a
  transform applied in a sticky is unrecoverable after switching tabs. Text below
  kept as the original framing.
- **Note transforms were REMOVED the same day, after seeing them on screen**
  (human's call): *"instead of choosing a style for a note I think it can simply
  be unstyled… I'd remove the styles for now, I don't think this is needed."* The
  reason was **density, not correctness** — a wand *and* a microphone in a note's
  action row read as too many things to do. **Dictation into a note stays.** The
  implementation is intact in commit `ea1f88c` (transform menu + `applyTransform`)
  if it is ever wanted back; `NoteEditorProxy` survived because dictation needs
  it. Standing lesson, already true twice in this app (tasks/reminders, and this):
  **a feature can be built correctly and still be wrong on screen** — judge the
  density before assuming the work should ship.
- ~~**Dictate-into-a-note, original entry**~~ — (human's
  call, prompted by Wispr's Scratchpad shipping in-note push-to-talk *and* a
  Transforms bar). It is running-order #3 and still gets **its own design session** —
  the caveat below always applied and now binds: this is not incidental inclusion.
  Two halves, and the second is bigger than it looks. **Dictation into a note**
  raises which style applies and whether a note dictation appears in Today (which is
  *transcriptions only* as of the 2026-08-10 ruling above — so probably not, and that
  asymmetry needs stating). **Transforms on note text is C8 pointed inward**: it acts
  on text we didn't author, note text can already come from a transcript or an
  AI-extracted action item, and `StyleGuard`'s coverage floor was built for "reshape
  what you just said", not "reshape a document". Wispr's **version history labelled by
  origin** (Created / Typed edits / Dictated / Transform) is the affordance that makes
  an AI transform on your own note feel recoverable rather than lossy — a good fit
  with our existing raw-vs-cleaned split. Design session must produce a ruling here,
  not a build.
- **Local MCP server** over transcripts.sqlite (read-only tools:
  search_transcripts, get_note, …) so Claude can query everything with zero
  cloud. Uniquely compatible with the privacy pitch; no competitor can offer it
  (Voicenotes' equivalent requires their cloud).
- **Sync** (Macs + iPhone) stays Phase B: SwiftData + CloudKit private DB,
  opt-in, per CLAUDE.md.
- Competitive note: no product combines system dictation + durable notes +
  call capture + stickies on-device (nearest: Voicenotes/AudioPen on
  capture→note, superwhisper/Wispr on dictation; all cloud or single-half).

## Implementation phasing

### The 2026-07-25 redesign — all six phases DONE, then partly superseded

Shell (five-item rail), pin/stick split (schema v10/v11), documents vs
dictations (`.call` + schema v12), the Today timeline, search everything, and
the Pinned board all shipped 2026-07-25/26. **The IA rework below supersedes the
rail, the pin lifecycle and the Pinned board**; `isDocument`, the timeline, the
search engine and `.call` all survive and are reused.

### The 2026-08-28 IA rework (one branch per phase)

All four phases were **built on 2026-08-28**, one branch each, none merged
pending Hendri's visual pass.

1. ~~**Dictations-only stream + date clamp**~~ — **DONE.** `Timeline.streamable` excludes
   documents from every day question; forward chevron dead on today and month
   future days inert (`canStepForward` / `isFutureDay`, both pure and tested);
   `documentCard`/`pinGlyph` deleted from the stream (the shared `card` helper
   stays — search results still show the two weights). Rename waits for phase 3
   so the rail is rewritten once.
2. ~~**Pin removal**~~ — **DONE.** every pin affordance, `PinnedBoard`, the store's pin
   accessors and mutators go; `setNoteStuck` stops auto-pinning; the Notes list
   grows an "On your screen" group. **Columns stay, unwritten; no schema bump**,
   and the v10/v11 migration tests must pass byte-untouched (if one needs
   editing, the store change went too far). Rail 5 → 4.
3. ~~**Documents merge into Notes**~~ — **DONE.** rail 4 → 3 and the "Dictations" rename land
   here. One shelf, one merged list (new pure `Storage/NotesLibrary.swift`), and
   a shell-owned `enum NoteListSelection { case note(UUID); case document(UUID) }`
   — an enum rather than two optionals so an illegal state is unrepresentable,
   and shell-owned because the detail `switch` is a `_ConditionalContent` that
   destroys the `@State` of any branch you leave. `TranscriptDetail` moves to its
   own file and becomes the document detail; `TranscriptListPane` dies with the
   Documents pane.
4. ~~**Sticky panel redesign**~~ — **DONE.** chromeless tab strip, edge-to-edge text,
   summoned formatting capsule, compact ⇄ expanded replacing free resize (pure
   `StickyPanelGeometry` for the top-left-anchored, screen-clamped frame).

**No phase touches `AudioRecorder`/routing/`MusicPauser`/`TextInserter`, and no
phase bumps the schema (it stays v13)** — a schema bump means the plan was
violated. Empty states land with their owning phase, not separately.
