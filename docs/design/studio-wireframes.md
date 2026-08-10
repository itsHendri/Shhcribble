# Studio wireframes — decision record

**Living document** — updated as wireframe iterations continue; the current
state supersedes older entries in place. Last major revision: 2026-07-25
(direction locked with Hendri across the sessions of 2026-07-24/25).
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
- **Notes** are the durable, mindful environment — written, returned to,
  built on.
- **Documents** (uploaded files, videos, call captures) are real long-form
  transcripts and keep the reader + summary treatment. Quick dictations are
  never documents.

The old UI treated dictations and notes as two identical master-detail clones.
The redesign is "**one timeline, two weights**": one chronological Today stream
where notes/documents anchor as cards and dictations pass through as lines.

## Information architecture

Rail (five items, every screen): **Today · Documents · Notes · Pinned · ⌵ ·
Settings**. Documents sits above Notes as of 2026-08-10: with Today
transcriptions-only, Documents is the other half of the same material, while
Notes is the separate written environment. The titlebar always reads
"Shhhcribble" — the rail's active state is the location indicator; the title
never restates it.

- **Today** — single chronological stream of **transcriptions only**, **scoped
  to one day** (ruled 2026-08-10). Notes left the stream: Today is the record of
  what you *said*, a note is something you *wrote*, and mixing them made turning
  one into the other look like the obvious move. "Two weights" now runs along
  the line the app already draws internally (`isDocument`). Anchored (bordered
  card): documents, title + type pill + preview. Passing (borderless line):
  dictations, **always fully expanded — no truncation**
  (scroll carries the length; revisit only if it ever feels overwhelming).
  **"No truncation" binds the stream, not every surface** — search results trim
  a dictation, because a list of matches is a different job from the record of
  what you said. **Dictations render at full-strength label colour, not
  secondary** (revised 2026-07-27): the card border is what carries the two
  weights, and greying the passing items as well is what made the stream read as
  inactive. **Time sits at the row's trailing edge**, not in a left gutter, so
  every item's content starts on one left edge. Search results carry their date
  on the same edge. **The meta line
  reads copy · word count · style tag … delete** (revised 2026-08-10), and the
  asymmetry is deliberate: copy is the reason the screen exists, so it *leads*
  the line and is always visible; delete is the one thing you'd hate to hit by
  accident, so it sits at the far right and only on hover. That one hover
  control is why the row still needs its `contentShape` — see the cross-cutting
  rule. **Add-to-note was removed from the stream**: turning a transcription
  into a note read as the wrong move here, and notes then left the stream
  entirely (`addNoteFromDictation` stays on the store, unused by any view).
  Date: chevrons step a day; the day label opens
  a month popover with dots on non-empty days + "Jump to today"; the date
  navigator steps aside while a search is active, since results span every day.
- **Notes** — master-detail. List groups: Pinned, then day groups ("Today",
  "Earlier this week", …). **Row hover swaps the date for pin + copy** in its
  fixed trailing slot (2026-07-27) — pinning is frequent enough now that it
  shouldn't require opening the item first. Detail: rich-text editor (existing
  type ramp), header actions **pin · copy · delete** only. Embedded dictation
  blocks: 2pt left rule (square corners), quoted text, "From a dictation,
  <date>" with mic glyph.
- **Documents** — master-detail, keeps the Transcript | Summary tabs, which
  **span the full width of the reader** and stay neutral. Same pin + copy row
  hover as Notes. Rail glyph is a stack, not a ruled page — at rail size the
  page glyph read as a second Notes icon, and the two-square shape it briefly
  wore now belongs to copy. **Summaries exist only here.** Header actions
  **pin · copy · delete**.
  Dropped: reveal-in-Finder (sources are often ephemeral — WhatsApp files,
  deleted uploads; the transcript is the durable artifact) and download (a
  .txt sidecar is already written automatically at transcription time).
- **Pinned** — cross-type board, two sections: "On your screen" strip (active
  stickies, each with Unstick) above a grid of pinned notes + documents (type
  pill; stuck items carry a small screen glyph). **Cards are a fixed height and
  roughly square — a wall of stickies, not a list** (revised 2026-08-10):
  content-sized cards left ragged holes wherever a one-line note sat beside a
  wrapped one, and spent the space on nothing. Every card carries real preview
  text filling whatever the title leaves, so the board can be scanned without
  opening anything. Clicking a card jumps to the item in its home tab. This is
  the only cross-type surface and the only place to manage stickies without
  hunting across desktops.
- **Settings** — one rail item, master-detail like Notes. Subnav column:
  **Preferences · Styles · Dictionary · Feedback**, with **Check for updates ·
  Quit** anchored at the subnav bottom. Menu-bar right-click Quit remains (the
  CLAUDE.md "Quit must stay reachable" invariant holds). Rationale for demoting
  Styles: quick *switching* lives in the menu-bar Style submenu + per-app auto;
  the page is for authoring, which is occasional.

## Pin vs stick (the split)

Today's `Note.pinned` conflated two lifecycles. Split:

- **Pin** = *importance*. Durable favourite; applies to **notes and
  documents**. Pinned items sit in a "Pinned" group at the top of their own
  list and on the Pinned board. Quiet glyph toggle in the header action row.
- **Stick** = *urgency*. Puts a note on screen as a floating sticky (1–2 at a
  time, removed when done). Its control is the **floating capsule over the
  editor** — the label is the state ("Stick to screen" ↔ "Unstick"); no
  separate "On screen" tag.
- **Sticking auto-pins.** Urgency is a subset of importance. Unpinning a stuck
  note stays possible as a manual override but is not the normal path.
- Naming: "pin" is reserved exclusively for the favourite; the sticky verbs are
  stick/unstick (desktop glyph). This renames the shipped "Pin to Screen"
  button.

## Cross-cutting rules

- **The floating capsule is a column's single primary verb** — Add note (notes
  list), Upload audio… (documents list), Stick/Unstick (note editor). One
  capsule per column — **without exception again as of 2026-08-10**. The
  carve-out for Today's empty state (Add note *and* Upload audio…, ruled
  2026-07-25) existed only because an empty Today had no route to a note; that
  stopped being Today's problem when notes left the stream. The standing tie-break
  it was drawn from still holds: where the wireframes' drawings and prose
  disagree, **the wireframe wins unless it's technically impossible**.
- **Search**: only Today's "Search everything" crosses categories — results
  replace the timeline, grouped **Notes → Dictations → Documents** (was written
  as "library order", which is undefined for dictations: they have no rail item)
  then dated, matches highlighted, Esc/✕ restores the day. Notes/Documents
  search pills filter their own lists inline, no custom results view.
- **Empty states** teach the pane's verb with a real CTA; Today teaches the
  hotkey (keycap style) and offers **one** capsule (Upload Audio…) — the
  two-capsule carve-out below was retired 2026-08-10 when notes left the stream
  and Today stopped needing a route to one; Pinned carries the one-sentence
  pin-vs-stick explainer. Today also has a *quiet-day* variant ("Nothing on this day") for a
  past day that happens to be empty — distinct from the library-empty state.
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
  on hover (the Notes and Documents list rows), the whole row must be the hover
  target via an explicit `contentShape` — `onHover` hit-tests drawn content, so
  a row with transparent space dismisses itself as the pointer crosses it.
- **Every action whose result isn't visible on screen flashes a toast** — copy,
  pin, unpin. Pinning moves an item to another group and another tab, so a
  glyph quietly filling in isn't feedback. One `ToastState` per pane, one
  `.toast(state)` anchor; see `DesignSystem.swift`.

## Open questions (raised by the 2026-07-25 build; need a ruling)

- ~~**Today's empty state: one capsule or two?**~~ **RULED 2026-07-25: two**,
  per the wireframe. The rule gains an explicit carve-out above.
- ~~**Can a dictation be pinned?**~~ **RULED 2026-07-25: no.** Pin is for the
  durable half. `pinnedTranscripts` filters on `isDocument`, the reader's pin
  control only appears for documents, and a row pinned by an earlier build stays
  off the board.
- ~~**What does Today contain?**~~ **RULED 2026-08-10: transcriptions only.**
  Notes left; documents stayed, since a document *is* a transcription and
  `isDocument` already draws that line. `Timeline` no longer takes notes at all,
  so the month dots and the opening day agree with the stream. Pinned by
  `testItemsMergesDictationsAndDocumentsNewestFirstAndExcludesNotes`.
- **"Search everything" still crosses into notes**, from a pane that never
  otherwise shows them; a note result jumps to the Notes tab. Kept deliberately
  — a global search is worth more than the consistency — but it is the one place
  Today has a second personality. Revisit if it reads as a leak.
- **Embedded dictation blocks** (2pt left rule, quoted text, "From a dictation,
  <date>" with mic glyph) are specified for Notes but **not built**. The left
  rule needs custom text-view drawing; the attribution line is cheap. Now
  partly contingent on the question above — if notes and dictations stop
  crossing over, this may have no callers left.

## Explicitly deferred (documented so they don't sneak in)

- **Richer notes: images, image grids.** Attachments survive the keyed-archive
  storage in principle; layout/grids are untested and undesigned.
- **Dictate-into-a-note with a "note style"** (structures speech into
  title/subtitle/body). NOTE: this reopens the deliberate 2026-07-23 "no
  dictate-into-note" decision — needs its own design session, not incidental
  inclusion.
- **Local MCP server** over transcripts.sqlite (read-only tools:
  search_transcripts, get_note, …) so Claude can query everything with zero
  cloud. Uniquely compatible with the privacy pitch; no competitor can offer it
  (Voicenotes' equivalent requires their cloud).
- **Sync** (Macs + iPhone) stays Phase B: SwiftData + CloudKit private DB,
  opt-in, per CLAUDE.md.
- Competitive note: no product combines system dictation + durable notes +
  call capture + stickies on-device (nearest: Voicenotes/AudioPen on
  capture→note, superwhisper/Wispr on dictation; all cloud or single-half).

## Implementation phasing (recommended; one branch per phase)

1. ~~**Shell**~~ — **DONE 2026-07-25.** Five-item rail, Settings environment
   (subnav master-detail), constant titlebar, Quit/updates relocation.
2. ~~**Pin/stick split**~~ — **DONE 2026-07-25.** Schema v10 adds `notes.stuck`
   seeded from `pinned` (so existing stickies come out stuck AND pinned, which
   the auto-pin rule makes exactly right); v11 adds `transcripts.pinned`. Sticky
   verbs renamed, Pinned groups atop both lists. **This phase also delivered
   phase 6's board** — adding pin without a surface that shows pinned items
   would have left the Pinned tab lying — so 6 below is reduced to polish.
3. ~~**Documents vs dictations**~~ — **DONE 2026-07-25.** `TranscriptSource`
   gained `.call`; schema v12 reclassifies the call captures that shipped as
   `.dictation`, keyed on `durationSec` rather than the title. `isDocument` is
   the one predicate dividing the app's two halves. Action rows pared to
   pin · copy · delete (download and reveal dropped).
4. ~~**Today timeline**~~ — **DONE 2026-07-25.** The feed replacing the
   transcripts master-detail: day stream, two weights, hover actions, chevrons +
   month popover. Day logic is pure and tested (`Storage/Timeline.swift`).
5. ~~**Search everything**~~ — **DONE 2026-07-25.** Cross-category results on
   Today: grouped Notes → Dictations → Documents, dated within each, matches
   highlighted, Esc/✕ restores the day. Pure and tested (`Storage/Search.swift`).
6. ~~**Pinned board**~~ — **DONE 2026-07-25.** Strip + grid (the bulk landed
   with phase 2); this pass added the board's tested content model, the
   pin-vs-stick empty state with its Browse-notes CTA, and the contract's empty
   -state copy across Today, Notes and Documents.

Phases 2–3 touch schema (versioned per-step migrations per the TranscriptStore
pattern); none touch `AudioRecorder`/routing/`MusicPauser`/`TextInserter`, so
no hardware smoke test is triggered until a phase says otherwise. Empty states
land with their owning phase, not separately.
