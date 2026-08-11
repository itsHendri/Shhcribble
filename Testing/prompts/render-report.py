#!/usr/bin/env python3
"""Render the A/B bench markdown as a side-by-side HTML page.

The markdown the bench writes is fine for grepping and terrible for judging:
the arms sit one under another, so comparing them means scrolling and holding
the previous one in your head. This puts the arms in columns, one row per
fixture, which is the only way the comparison is actually cheap.

    python3 Testing/prompts/render-report.py ~/Desktop/shhhcribble-prompt-ab.md

Writes an .html beside the input and prints its path.
"""
import html
import re
import sys
from pathlib import Path

CSS = """
:root { color-scheme: light dark; --bg:#fff; --fg:#111; --muted:#666; --line:#e3e3e3;
        --card:#fafafa; --ok:#1a7f37; --bad:#b3261e; --warn:#8a6d00; --accent:#4c4cff; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#16161a; --fg:#e8e8ea; --muted:#9a9aa2; --line:#2c2c32;
          --card:#1d1d22; --ok:#4ac26b; --bad:#ff7b72; --warn:#d9b400; --accent:#9a9aff; } }
* { box-sizing: border-box; }
body { margin:0; padding:32px 28px 80px; background:var(--bg); color:var(--fg);
       font:14px/1.55 ui-sans-serif,-apple-system,"SF Pro Text",system-ui,sans-serif; }
h1 { font-size:22px; margin:0 0 4px; letter-spacing:-.01em; }
h2 { font-size:17px; margin:44px 0 2px; letter-spacing:-.01em; }
h2 .arms { font-size:12px; font-weight:400; color:var(--muted); }
.intro { color:var(--muted); max-width:70ch; margin-bottom:8px; }
.fixture { margin:26px 0 0; border-top:1px solid var(--line); padding-top:18px; }
.fixture > .name { font:600 12px ui-monospace,SFMono-Regular,Menlo,monospace;
                   color:var(--accent); margin-bottom:8px; }
.said { color:var(--muted); font-style:italic; max-width:100ch; margin:0 0 14px;
        padding-left:12px; border-left:2px solid var(--line); white-space:pre-wrap; }
.cols { display:grid; gap:14px; grid-template-columns:repeat(var(--n),minmax(0,1fr)); }
@media (max-width:900px) { .cols { grid-template-columns:1fr; } }
.arm { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
.arm.shipped { border-color:var(--accent); }
.arm .hd { display:flex; justify-content:space-between; align-items:baseline;
           gap:10px; margin-bottom:8px; }
.arm .nm { font-weight:600; font-size:12px; }
.arm .meta { font:11px ui-monospace,SFMono-Regular,Menlo,monospace; color:var(--muted);
             white-space:nowrap; }
.v-ok { color:var(--ok); } .v-bad { color:var(--bad); } .v-warn { color:var(--warn); }
pre { margin:0; white-space:pre-wrap; word-wrap:break-word;
      font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
"""

ARM_RE = re.compile(
    r"\*\*(?P<name>.+?)\*\* — (?P<ms>\d+) ms — (?P<verdict>.+?)\n\n```\n(?P<body>.*?)\n```",
    re.S,
)


def verdict_class(v):
    if v.startswith("REJECTED"):
        return "v-bad"
    if v.startswith("empty"):
        return "v-warn"
    return "v-ok"


def render(md_path: Path) -> Path:
    text = md_path.read_text(encoding="utf-8")
    out = [
        "<!doctype html><meta charset=utf-8>",
        f"<title>{html.escape(md_path.stem)}</title><style>{CSS}</style>",
        "<h1>Prompt A/B</h1>",
        "<p class=intro>Same fixture, same model, same guards — only the prompt differs. "
        "Pick the column you'd rather have pasted into your editor; that's the whole method. "
        "The outlined column is what currently ships.</p>",
    ]

    # Split into style sections ("# Agent", "# Bullets", …), skipping the title.
    sections = re.split(r"^# (.+)$", text, flags=re.M)[1:]
    for style, block in zip(sections[0::2], sections[1::2]):
        if style.strip() == "Prompt A/B":
            continue
        arms_line = ""
        m = re.search(r"^Arms: (.+)$", block, re.M)
        if m:
            arms_line = re.sub(r"\*\*(.+?)\*\*", r"\1", m.group(1))
        out.append(f"<h2>{html.escape(style.strip())} "
                   f"<span class=arms>{html.escape(arms_line)}</span></h2>")

        # Each fixture is "## `name`" followed by the quoted input and the arms.
        for fixture, fblock in zip(*[iter(re.split(r"^## `(.+?)`$", block, flags=re.M)[1:])] * 2):
            said = "\n".join(
                line[2:] for line in fblock.splitlines() if line.startswith("> ")
            )
            arms = list(ARM_RE.finditer(fblock))
            if not arms:
                continue
            cards = []
            for a in arms:
                name = a.group("name")
                shipped = " shipped" if name.strip() == "shipped" else ""
                cards.append(
                    f"<div class='arm{shipped}'><div class=hd>"
                    f"<span class=nm>{html.escape(name)}</span>"
                    f"<span class=meta>{a.group('ms')} ms · "
                    f"<span class={verdict_class(a.group('verdict'))}>"
                    f"{html.escape(a.group('verdict').strip())}</span></span></div>"
                    f"<pre>{html.escape(a.group('body'))}</pre></div>"
                )
            out.append(
                f"<div class=fixture><div class=name>{html.escape(fixture)}</div>"
                f"<div class=said>{html.escape(said)}</div>"
                f"<div class=cols style='--n:{len(cards)}'>{''.join(cards)}</div></div>"
            )

    dest = md_path.with_suffix(".html")
    dest.write_text("\n".join(out), encoding="utf-8")
    return dest


if __name__ == "__main__":
    src = Path(sys.argv[1] if len(sys.argv) > 1
               else Path.home() / "Desktop/shhhcribble-prompt-ab.md").expanduser()
    if not src.exists():
        sys.exit(f"No report at {src} — run the bench first.")
    print(render(src))
