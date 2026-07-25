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

Rail (five items, every screen): **Today · Notes · Documents · Pinned · ⌵ ·
Settings**. The titlebar always reads "Shhhcribble" — the rail's active state
is the location indicator; the title never restates it.

- **Today** — single chronological stream. Anchored (bordered card): notes and
  documents, title + type pill + preview. Passing (borderless line): dictations,
  **always fully expanded — no truncation** (day grouping + scroll carry the
  length; revisit only if it ever feels overwhelming). Hover reveals per-item
  actions: copy (accent), add-to-note, delete. Date: chevrons step a day; the
  day label opens a month popover with dots on non-empty days + "Jump to today".
- **Notes** — master-detail. List groups: Pinned, then day groups ("Today",
  "Earlier this week", …). Detail: rich-text editor (existing type ramp),
  header actions **pin · copy · delete** only. Embedded dictation blocks: 2pt
  left rule (square corners), quoted text, "From a dictation, <date>" with mic
  glyph.
- **Documents** — master-detail, keeps the Transcript | Summary tabs.
  **Summaries exist only here.** Header actions **pin · copy · delete**.
  Dropped: reveal-in-Finder (sources are often ephemeral — WhatsApp files,
  deleted uploads; the transcript is the durable artifact) and download (a
  .txt sidecar is already written automatically at transcription time).
- **Pinned** — cross-type board, two sections: "On your screen" strip (active
  stickies, each with Unstick) above a grid of pinned notes + documents (type
  pill; stuck items carry a small screen glyph). Clicking a card jumps to the
  item in its home tab. This is the only cross-type surface and the only place
  to manage stickies without hunting across desktops.
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
  list), Upload audio… (documents list / Today empty state), Stick/Unstick
  (note editor). One capsule per column, never more.
- **Search**: only Today's "Search everything" crosses categories — results
  replace the timeline, grouped by category (library order) then dated, matches
  highlighted, Esc/✕ restores the day. Notes/Documents search pills filter
  their own lists inline, no custom results view.
- **Empty states** teach the pane's verb with a real CTA; Today teaches the
  hotkey (keycap style); Pinned carries the one-sentence pin-vs-stick
  explainer.
- Action rows stay minimal: no download anywhere (copy covers it), no reveal.
- All existing DesignSystem tokens carry over (neutral fills over primary,
  radius roles, chrome type ramp). Selection stays neutral; accent only for
  links, active copy glyph, and match highlights.

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
3. **Documents vs dictations** — a real source distinction. Call captures are
   currently stored as `source: .dictation` with a "Call —" title (v1 gap in
   CLAUDE.md); this phase gives them and file imports a proper document
   category. Documents tab + pared actions.
4. **Today timeline** — the feed replacing the transcripts master-detail:
   day stream, two weights, hover actions, chevrons + month popover.
5. **Search everything** — cross-category results view on Today.
6. **Pinned board** — strip + grid. **Largely delivered in phase 2**; what's
   left is whatever polish the wireframe implies once documents have a real
   source category (phase 3).

Phases 2–3 touch schema (versioned per-step migrations per the TranscriptStore
pattern); none touch `AudioRecorder`/routing/`MusicPauser`/`TextInserter`, so
no hardware smoke test is triggered until a phase says otherwise. Empty states
land with their owning phase, not separately.
