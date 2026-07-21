# Smoke-test harness

Automates the behavioural tests the unit suite can't touch: real dictation
through a microphone, Spotify pause/resume, auto-paste, Escape-to-cancel,
pill-open latency — plus a guided, auto-judged AirPods checklist.

**Local only, never CI.** CI runners have no audio hardware, no Bluetooth and
no TCC grants. This runs on a developer Mac against the **installed** app at
`/Applications/Shhhcribble.app` (which holds stable permission grants — the
Debug build re-triggers the Accessibility churn on every rebuild).

## One-time setup

```bash
brew install blueutil switchaudio-osx
brew install --cask blackhole-2ch   # asks for your password (audio driver)
```

Permissions (System Settings → Privacy & Security):
- **Accessibility → your terminal** (the harness sends synthetic hotkey
  presses via System Events).
- **Accessibility → Shhhcribble** (auto-paste + Escape need it — one-time for
  the installed app).
- First run will also show one-time **Automation** prompts (terminal
  controlling TextEdit / Spotify / System Events) — approve them.

Without BlackHole the harness falls back to playing the reference phrase
through the speakers and recording it with the built-in mic — works, but is
audible and slightly less deterministic. With BlackHole everything is silent
and exact.

## Usage

```bash
python3 Testing/smoke/smoke.py doctor   # verify setup
python3 Testing/smoke/smoke.py tier1    # fully scripted (~2 min)
python3 Testing/smoke/smoke.py tier2    # guided AirPods checklist (~10 min)
```

### Tier 1 — fully scripted
| Scenario | Asserts |
|---|---|
| `dictation_basic` | transcript row lands; ≥4/6 reference keywords; auto-paste appears in a scratch TextEdit doc; `Warm-up ready` present; keypress→ready < 2 s |
| `spotify_pause_resume` | Spotify pauses during recording, resumes after (skips cleanly if not installed / nothing playable) |
| `escape_cancel` | no transcript row, no completion sound, no paste; next recording still works |
| `rapid_double_tap` | app survives a ~300 ms start/stop; next dictation works |

### Tier 2 — guided AirPods checklist
You wear the AirPods and press the keys; the harness enforces a genuinely
cold route (timed idle), reads the unified log live, and judges each step:
warm-up start→ready gap, `audio seen: true` vs dwell-backstop, first-second
peak ≠ digital zero, transport = Bluetooth. The route-swap step uses
`blueutil` to disconnect the AirPods mid-dictation automatically.

## What stays manual forever

- A genuinely **cold** A2DP→HFP switch needs real idle AirPods (the harness
  can only enforce the wait, not simulate the radio).
- The **no-microphone** crash path needs a Mac with zero input devices.
- **Muffled-bleed** on Spotify resume is an ear judgment.
