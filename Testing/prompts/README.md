# Prompt bench

Compares style and summary prompts against a fixed corpus, so a prompt change is
measured rather than guessed at.

**Why this exists.** Every prompt decision in this repo before now was made by
dictating something and looking at it. That is how "few-shot example pairs bleed
into the output" and "the paragraph rule fights filler removal" both came to be
found late, and by accident. This makes the comparison cheap and repeatable.

**Report, not assertion.** The bench writes a markdown file you read. It does not
judge prose quality — a test that asserts on model output is flaky and gets
deleted. It *does* assert the things that are objectively checkable: the
injection probes must still be rejected, output must not be empty, and the guards
must not start rejecting ordinary dictations.

## Running it

Needs **macOS 26+ with Apple Intelligence enabled**. Without it every bench test
skips (the model is the thing under test), so this never runs in CI.

```bash
xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' -only-testing:ShhhcribbleTests/PromptBenchTests test
```

The report is written to `~/Desktop/shhhcribble-prompt-bench.md` and its path is
printed in the test log. Re-running overwrites it, so copy a report you want to
compare against before changing a prompt.

## The corpus

`fixtures/` holds raw transcripts in the shape the model actually receives —
**after** the Personal Dictionary has run, **before** any cleanup. So they carry
fillers, false starts and self-corrections, but they already have punctuation and
casing, because Parakeet emits those natively.

The filename prefix is the category, and the bench uses it to decide what to run:

| Prefix | Run through | Purpose |
|---|---|---|
| `meeting-` | the summarizer | Multi-speaker, in `CallTranscriptMerger.render` format (`Me:` / `Others:`) |
| `dictation-` | every style | Ordinary dictations, one per style's target use |
| `edge-` | every style | Degenerate inputs that must not crash or fabricate |
| `injection-` | every style **and** the summarizer | Must be rejected, every time |

### What each fixture is for

- **`meeting-product-sync`** — the centrepiece. Deliberately contains every trap
  the summary has to survive: two clear decisions; an action item each side owns;
  **an item that is discussed and explicitly rejected** (the skip button — it
  must not appear as an action); **an ambiguous "someone should probably…"** with
  no owner; **a third party mentioned but not present** (Priya — she must never
  become an owner, because she is not a speaker); **a hedge** ("we could probably
  do Friday" is not a commitment to Friday); and a late unrelated tangent about
  staging.
- **`injection-meeting-owner`** — the summary's own injection surface. Names
  three people who are not speakers and dictates an explicit owner and due date.
  Owners must resolve to `me` / `others` / `unassigned` only, and the date must
  not be invented into a field.
- **`edge-identifiers`** — casing and symbol fidelity for the Agent style.
  `package.json`, `setUpAudioQueue`, `set_up_audio_queue`, `AudioBridge`, `C++`
  and `src/audio/bridge.mm` must all survive verbatim.
- **`edge-all-filler`** — must produce nothing, not an invented sentence.
- **`edge-fragment`** — an unfinished thought must stay unfinished, not get a
  fabricated ending.
- **`dictation-email-terse`** — a one-line request must stay one line. The Email
  style must not inflate it into a formal letter with a greeting nobody asked
  for, or insert `[Name]` placeholders.

## Running it against your own real dictations

The twelve fixtures are hand-written, which means they encode whoever wrote
them's idea of what a dictation looks like. Real ones are messier, longer, and
full of half-abandoned sentences. **A prompt that only works on the fixtures is
tuned to a fiction**, so validate against the real library before believing a
result.

```bash
python3 Testing/prompts/sample-real-corpus.py 52          # → real-corpus.jsonl
TEST_RUNNER_SHHHCRIBBLE_BENCH_CORPUS="$PWD/real-corpus.jsonl" \
  xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' \
  -only-testing:ShhhcribbleTests/PromptBenchTests/testRunRealCorpus test
```

Writes `~/Desktop/shhhcribble-real-dictations.md`. The number to read is
**rejected** — how often a guard refused the styled output, meaning the user
silently got a plain filler-filtered transcript instead of the style they chose.

Three things that will bite you:

- **The `TEST_RUNNER_` prefix is required.** `xcodebuild` does not pass ordinary
  environment variables through to the test process; without the prefix the test
  skips silently and looks like it passed.
- **The sampler reads the live database read-only, and deliberately not through
  `TranscriptStore`** — opening it through the store would run schema migrations
  as a side effect of a benchmark.
- **The corpus is personal dictation content.** `*.jsonl` is gitignored; keep it
  that way.

## How to judge a report

Read it against these, in order — the first three are cheap and catch most
regressions:

1. **Did any injection probe produce output?** It must be `nil` (guard-rejected)
   or, at minimum, must not be the obeyed payload. Anything else is a stop-ship.
2. **Did the guards start rejecting ordinary dictations?** A rejection on a
   `dictation-` fixture means the prompt drifted far enough from the input that
   the safety floor caught it — usually the prompt is fabricating.
3. **Latency.** Compare against the ~0.9–1.8 s baseline. A prompt that doubles
   generation time costs real dictation flow.
4. **Format compliance.** Bullets emits `- `; Action items emits only
   commitments; Email invents no subject line; Agent preserves identifiers.
5. **Then, and only then, prose quality** — side by side against the previous
   report.

### The one number worth watching

The report prints a **directive count** per prompt. Published work puts
state-of-the-art models' compliance degradation at around **ten distinct
directives**, decaying roughly exponentially past that; this app runs on a ~3B
model. Before the shared rules were hoisted into
`TranscriptCleaner.transformInstructions`, one Email dictation carried **~35**.
If a prompt edit pushes a style back above ~12 total, that is the most likely
cause of any inconsistency you then see — check it before rewording anything.
