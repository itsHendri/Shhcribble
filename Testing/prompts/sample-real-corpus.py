#!/usr/bin/env python3
"""Sample real dictations from the live DB into a corpus both benches can share.

Read-only, and deliberately NOT via TranscriptStore: opening the live database
through the app's store would run the v13 migration as a side effect of a
benchmark, which is not a thing a measurement should do.

`rawText` is the right column: it is the transcript as it leaves Parakeet,
before the dictionary and before any cleanup — exactly what the pipeline hands
to a style. `text` is already-processed output and would measure nothing.

Output stays in the scratchpad. This is the user's personal dictation content
and must never be committed.
"""
import json, sqlite3, sys
from pathlib import Path

DB = Path.home() / "Library/Application Support/Shhhcribble/transcripts.sqlite"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 50
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)

# Stratify by length so the sample isn't dominated by two-word dictations —
# a style behaves very differently on 10 words than on 200.
buckets = [("short", 8, 25), ("medium", 25, 70), ("long", 70, 160), ("very long", 160, 100000)]
rows, per = [], N // len(buckets)
for label, lo, hi in buckets:
    got = con.execute("""
        SELECT id, rawText, LENGTH(rawText)-LENGTH(REPLACE(rawText,' ',''))+1 AS w
        FROM transcripts
        WHERE source='dictation' AND rawText IS NOT NULL AND TRIM(rawText) != ''
          AND w >= ? AND w < ?
        ORDER BY createdAt DESC LIMIT ?""", (lo, hi, per)).fetchall()
    for tid, raw, w in got:
        rows.append({"id": tid, "bucket": label, "words": w, "text": raw.strip()})
    print(f"  {label:<10} {len(got):>3} sampled (target {per})")

out = Path("real-corpus.jsonl")
out.write_text("\n".join(json.dumps(r) for r in rows))
print(f"\n{len(rows)} real dictations → {out}")
print(f"word count: min {min(r['words'] for r in rows)}  median "
      f"{sorted(r['words'] for r in rows)[len(rows)//2]}  max {max(r['words'] for r in rows)}")
