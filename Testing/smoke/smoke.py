#!/usr/bin/env python3
"""
Shhhcribble local smoke-test harness.

Automates the behavioural tests that unit tests cannot touch: real dictation
through a (virtual or physical) microphone, Spotify pause/resume, auto-paste,
Escape-to-cancel, pill-open latency — plus a guided, auto-judged AirPods
checklist for the parts only real Bluetooth hardware can produce.

This runs on a developer Mac against the INSTALLED app (/Applications), never
in CI: CI runners have no audio hardware, no Bluetooth, and no TCC grants.

Usage:
    python3 Testing/smoke/smoke.py doctor          # check prerequisites
    python3 Testing/smoke/smoke.py tier1           # fully scripted suite
    python3 Testing/smoke/smoke.py tier2           # guided AirPods checklist
    python3 Testing/smoke/smoke.py tier2 --cold-wait 60   # shorter cold wait

One-time setup (see Testing/smoke/README.md):
    brew install blueutil switchaudio-osx
    brew install --cask blackhole-2ch     # needs sudo; speaker fallback without
    Grant Accessibility to your terminal (for synthetic keystrokes) and to
    /Applications/Shhhcribble.app (for auto-paste + Escape).
"""

import argparse
import datetime
import os
import re
import subprocess
import sys
import time

APP_BUNDLE = "/Applications/Shhhcribble.app"
APP_PROCESS = "Shhhcribble.app/Contents/MacOS/Shhhcribble"
DB_PATH = os.path.expanduser(
    "~/Library/Application Support/Shhhcribble/transcripts.sqlite")
SUBSYSTEM = "com.shhhcribble.app"
BLACKHOLE = "BlackHole 2ch"

# Reference phrase: content words Parakeet transcribes reliably. The match is
# fuzzy (>= MIN_KEYWORDS of KEYWORDS present) because ASR output and the AI
# cleanup may reshape function words.
REF_PHRASE = ("the quick brown fox jumps over the lazy dog "
              "while seven wizards watch quietly")
KEYWORDS = ["quick", "brown", "fox", "lazy", "dog", "wizards"]
MIN_KEYWORDS = 4

# Hotkey presets mirrored from ModelManager.availableHotkeys.
# key code / modifiers for System Events' `key code ... using {...}`.
HOTKEYS = {
    "optSpace":  (49, "option down"),
    "ctrlSpace": (49, "control down"),
    "optGrave":  (50, "option down"),
    "ctrlOpt":   (49, "{control down, option down}"),
}


# ---------------------------------------------------------------- helpers

def sh(cmd, check=True, timeout=60):
    """Run a command, return stdout (stripped)."""
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def osa(script, check=True):
    try:
        return sh(["osascript", "-e", script], check=check)
    except subprocess.TimeoutExpired:
        raise SystemExit(
            "\nAn AppleScript call hung — almost certainly a one-time "
            "Automation permission prompt waiting on screen ('…would like to "
            "control TextEdit/Spotify/System Events'). Approve it and re-run. "
            "Prompts already dismissed can be re-enabled under System Settings "
            "→ Privacy & Security → Automation.")


def log_since(t0):
    """All app log lines since datetime t0 (unified log)."""
    start = t0.strftime("%Y-%m-%d %H:%M:%S")
    out = sh(["log", "show", "--start", start, "--style", "compact",
              "--predicate", f'subsystem == "{SUBSYSTEM}"'], timeout=120)
    return out.splitlines()


def log_ts(line):
    """Parse a compact-style log line's timestamp into a datetime."""
    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})", line)
    return datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f") if m else None


def db(query):
    return sh(["sqlite3", DB_PATH, query])


def db_row_count():
    return int(db("SELECT COUNT(*) FROM transcripts;"))


def latest_transcript():
    return db("SELECT text FROM transcripts ORDER BY createdAt DESC LIMIT 1;")


def hotkey():
    """(key code, modifier clause) for the app's configured hotkey."""
    hid = sh(["defaults", "read", "com.shhhcribble.app", "selectedHotkeyID"],
             check=False) or "optSpace"
    if hid not in HOTKEYS:
        print(f"  ! unknown hotkey id {hid!r}, assuming optSpace")
        hid = "optSpace"
    return HOTKEYS[hid]


def tap_hotkey():
    code, mods = hotkey()
    osa(f'tell application "System Events" to key code {code} using {mods}')


def press_escape():
    osa('tell application "System Events" to key code 53')


def app_running():
    return subprocess.run(["pgrep", "-f", APP_PROCESS + "$"],
                          capture_output=True).returncode == 0


def keyword_coverage(text):
    low = text.lower()
    return sum(1 for k in KEYWORDS if k in low)


def say_to_file(path):
    if not os.path.exists(path):
        sh(["say", "-o", path, REF_PHRASE])


class AudioSandbox:
    """Route audio through BlackHole (input+output) when available, so the
    reference phrase loops back into the app deterministically and nothing is
    audible. Falls back to speakers + built-in mic when BlackHole is missing.
    Always restores the previous devices."""

    def __init__(self):
        devices = sh(["SwitchAudioSource", "-a"], check=False)
        self.blackhole = BLACKHOLE in devices
        self.prev_in = self.prev_out = None

    def __enter__(self):
        if self.blackhole:
            self.prev_in = sh(["SwitchAudioSource", "-c", "-t", "input"])
            self.prev_out = sh(["SwitchAudioSource", "-c", "-t", "output"])
            sh(["SwitchAudioSource", "-s", BLACKHOLE, "-t", "input"])
            sh(["SwitchAudioSource", "-s", BLACKHOLE, "-t", "output"])
        else:
            print("  ! BlackHole not installed — speaker-fallback mode "
                  "(plays the phrase out loud; built-in mic picks it up)")
            # A muted Mac would record silence and fail spuriously — pin the
            # output volume for the run and restore it after.
            self.prev_vol = osa("output volume of (get volume settings)",
                                check=False)
            osa("set volume output volume 45", check=False)
        return self

    def __exit__(self, *exc):
        if self.blackhole:
            if self.prev_in:
                sh(["SwitchAudioSource", "-s", self.prev_in, "-t", "input"],
                   check=False)
            if self.prev_out:
                sh(["SwitchAudioSource", "-s", self.prev_out, "-t", "output"],
                   check=False)
        elif getattr(self, "prev_vol", "").isdigit():
            osa(f"set volume output volume {self.prev_vol}", check=False)


class TextEditTarget:
    """A scratch TextEdit document as the paste target, so dictation never
    lands in a random focused app. Reads the pasted text back for assertion."""

    def __enter__(self):
        osa('tell application "TextEdit"\n'
            'activate\nmake new document\nend tell')
        time.sleep(1.0)
        return self

    def text(self):
        return osa('tell application "TextEdit" to get text of document 1',
                   check=False)

    def focus(self):
        osa('tell application "TextEdit" to activate')
        time.sleep(0.5)

    def __exit__(self, *exc):
        osa('tell application "TextEdit" to close document 1 saving no',
            check=False)


def wait_for_new_row(baseline, timeout=25):
    """Wait until the transcript store gains a row (transcribe+cleanup done)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if db_row_count() > baseline:
            return True
        time.sleep(0.5)
    return False


def dictate(ref_audio, settle=1.0):
    """One scripted dictation: tap, play the reference phrase, tap, wait for
    the transcript row. Returns (ok, t_keypress, lines_fn) where lines_fn()
    fetches the log lines for this dictation."""
    baseline = db_row_count()
    t0 = datetime.datetime.now() - datetime.timedelta(seconds=1)
    t_key = time.time()
    tap_hotkey()
    time.sleep(settle)               # let the route go live before "speaking"
    sh(["afplay", ref_audio], timeout=30)
    time.sleep(0.5)
    tap_hotkey()
    ok = wait_for_new_row(baseline)
    return ok, t_key, (lambda: log_since(t0))


# ---------------------------------------------------------------- scenarios

class Result:
    def __init__(self, name, passed, notes):
        self.name, self.passed, self.notes = name, passed, notes


def scenario_dictation_basic(ref_audio):
    """End-to-end: hotkey → speech → transcript row + auto-paste + latency."""
    notes = []
    with TextEditTarget() as te:
        ok, t_key, lines_fn = dictate(ref_audio)
        if not ok:
            return Result("dictation_basic", False,
                          ["no transcript row appeared within 25 s"])
        lines = lines_fn()
        ready = [l for l in lines if "Warm-up ready" in l]
        if not ready:
            notes.append("FAIL: no 'Warm-up ready' line (the old bug signature)")
        else:
            rts = log_ts(ready[0])
            open_ms = (rts.timestamp() - t_key) * 1000
            notes.append(f"pill-open latency (keypress→ready): {open_ms:.0f} ms")
            if open_ms > 2000:
                notes.append("FAIL: pill-open latency over 2 s on a non-BT device")
        cov = keyword_coverage(latest_transcript())
        notes.append(f"transcript keyword coverage: {cov}/{len(KEYWORDS)}")
        if cov < MIN_KEYWORDS:
            notes.append(f"FAIL: transcript matched < {MIN_KEYWORDS} keywords: "
                         f"{latest_transcript()[:120]!r}")
        pasted = te.text()
        if keyword_coverage(pasted) >= MIN_KEYWORDS:
            notes.append("auto-paste landed in TextEdit")
        else:
            notes.append("FAIL: auto-paste did not land (is Accessibility "
                         f"granted to {APP_BUNDLE}?) TextEdit had: {pasted[:80]!r}")
        capture = [l for l in lines if "Capture:" in l]
        if capture:
            notes.append(capture[-1].split("] ")[-1])
    passed = not any(n.startswith("FAIL") for n in notes)
    return Result("dictation_basic", passed, notes)


def spotify_state():
    return osa('tell application "Spotify" to player state as text', check=False)


def scenario_spotify_pause_resume(ref_audio):
    """Spotify playing → must pause during dictation, resume after."""
    if not os.path.exists("/Applications/Spotify.app"):
        return Result("spotify_pause_resume", True, ["SKIP: Spotify not installed"])
    notes = []
    was_running = subprocess.run(["pgrep", "-x", "Spotify"],
                                 capture_output=True).returncode == 0
    osa('tell application "Spotify" to play', check=False)
    time.sleep(3)
    if spotify_state() != "playing":
        return Result("spotify_pause_resume", True,
                      ["SKIP: could not start Spotify playback "
                       "(no track queued / not logged in)"])
    with TextEditTarget():
        baseline = db_row_count()
        tap_hotkey()
        time.sleep(2.5)
        mid = spotify_state()
        notes.append(f"state during recording: {mid}")
        if mid != "paused":
            notes.append("FAIL: Spotify was not paused during recording")
        sh(["afplay", ref_audio], timeout=30)
        tap_hotkey()
        wait_for_new_row(baseline)
        time.sleep(3.5)              # non-BT resume delay is 700 ms; BT 2100 ms
        after = spotify_state()
        notes.append(f"state after recording: {after}")
        if after != "playing":
            notes.append("FAIL: Spotify did not resume")
    osa('tell application "Spotify" to pause', check=False)
    if not was_running:
        osa('tell application "Spotify" to quit', check=False)
    passed = not any(n.startswith("FAIL") for n in notes)
    return Result("spotify_pause_resume", passed, notes)


def scenario_escape_cancel():
    """Escape mid-recording: no transcript row, no completion sound."""
    notes = []
    t0 = datetime.datetime.now() - datetime.timedelta(seconds=1)
    with TextEditTarget() as te:
        baseline = db_row_count()
        tap_hotkey()
        time.sleep(1.5)
        press_escape()
        time.sleep(3)
        if db_row_count() != baseline:
            notes.append("FAIL: Escape still produced a transcript row")
        if any("Completion sound" in l for l in log_since(t0)):
            notes.append("FAIL: completion sound fired on a cancelled recording")
        if te.text().strip():
            notes.append("FAIL: text was pasted after Escape")
        if not notes:
            notes.append("cancelled cleanly: no row, no sound, no paste")
        # A cancel that leaves the state machine stuck would break the NEXT
        # recording — probe with a minimal tap-tap.
        tap_hotkey()
        time.sleep(1.0)
        tap_hotkey()
        time.sleep(3)
        notes.append("state machine alive after cancel"
                     if app_running() else "FAIL: app died after cancel")
    passed = not any(n.startswith("FAIL") for n in notes)
    return Result("escape_cancel", passed, notes)


def scenario_rapid_double_tap(ref_audio):
    """Start/stop within ~300 ms, then a normal dictation must still work."""
    notes = []
    with TextEditTarget():
        tap_hotkey()
        time.sleep(0.3)
        tap_hotkey()
        time.sleep(4)                # let the aborted take settle
        if not app_running():
            return Result("rapid_double_tap", False, ["FAIL: app crashed"])
        ok, _, _ = dictate(ref_audio)
        if ok and keyword_coverage(latest_transcript()) >= MIN_KEYWORDS:
            notes.append("recording after rapid double-tap works")
        else:
            notes.append("FAIL: dictation broken after rapid double-tap")
    passed = not any(n.startswith("FAIL") for n in notes)
    return Result("rapid_double_tap", passed, notes)


# ---------------------------------------------------------------- tier 2

def find_airpods():
    out = sh(["blueutil", "--paired"], check=False)
    for line in out.splitlines():
        if "pods" in line.lower():
            m = re.search(r"address: ([0-9a-f-]+)", line)
            if m:
                return m.group(1), line.split(",")[1].strip() if "," in line else "AirPods"
    return None, None


def judge_bt_dictation(lines, expect_cold):
    """Auto-judge a Bluetooth dictation from its log lines."""
    notes, ok = [], True
    starts = [l for l in lines if "Warm-up start" in l]
    readys = [l for l in lines if "Warm-up ready" in l]
    if not starts or not readys:
        return False, ["FAIL: missing warm-up start/ready pair "
                       "(ready absent = recording died before the mic woke)"]
    if "Bluetooth" not in starts[-1]:
        notes.append("WARN: input transport was not Bluetooth — wrong mic?")
    gap = (log_ts(readys[-1]) - log_ts(starts[-1])).total_seconds()
    notes.append(f"warm-up start→ready: {gap*1000:.0f} ms")
    if expect_cold and gap < 0.15:
        notes.append("WARN: ready was near-instant — route probably wasn't cold")
    if "audio seen: true" not in readys[-1]:
        notes.append("WARN: went live on the dwell backstop, not real audio")
    caps = [l for l in lines if "Capture:" in l]
    if caps:
        notes.append(caps[-1].split("] ")[-1])
        m = re.search(r"first-1s peak (\d+\.\d+)", caps[-1])
        if m and float(m.group(1)) == 0.0:
            ok = False
            notes.append("FAIL: first second is digital zero — dead-mic window "
                         "captured (the original bug)")
    return ok, notes


def tier2(cold_wait):
    print("== Tier 2: guided AirPods checklist ==")
    mac, name = find_airpods()
    if not mac:
        print("No paired AirPods found (blueutil --paired). Aborting.")
        return 1
    print(f"Using {name} ({mac})")
    results = []

    def step(title, instructions, expect_cold=False, pre=None, during=None):
        print(f"\n-- {title} --\n{instructions}")
        if pre:
            pre()
        input("Press Enter to arm log capture, then do it… ")
        t0 = datetime.datetime.now()
        if during:
            during()
        input("Press Enter when the dictation has finished… ")
        time.sleep(2)
        ok, notes = judge_bt_dictation(log_since(t0), expect_cold)
        for n in notes:
            print(f"   {n}")
        print(f"   => {'PASS' if ok else 'FAIL'}")
        results.append(Result(title, ok, notes))

    def enforce_cold():
        print(f"Keeping the route idle for {cold_wait}s so it is genuinely "
              "cold. Don't play any audio.")
        for remaining in range(cold_wait, 0, -30):
            print(f"   …{remaining}s")
            time.sleep(min(30, remaining))

    step("cold_start_tap",
         "AirPods in, no audio playing. ONE quick tap, then speak a sentence "
         "as soon as the pill appears; tap again to stop.",
         expect_cold=True, pre=enforce_cold)

    step("warm_start", "Immediately dictate again (tap, speak, tap).")

    def drop_airpods():
        print("   …recording is live; disconnecting AirPods in 5 s to force "
              "a mid-recording route swap onto the built-in mic…")
        time.sleep(5)
        sh(["blueutil", "--disconnect", mac], check=False)

    step("route_swap_mid_recording",
         "Start a LONG dictation (~15 s) and keep talking through the "
         "AirPods disconnect — the recording should survive on the built-in "
         "mic and keep your words.",
         during=drop_airpods)
    sh(["blueutil", "--connect", mac], check=False)

    print("\n== Tier 2 summary ==")
    return summarize(results)


# ---------------------------------------------------------------- runners

def summarize(results):
    width = max(len(r.name) for r in results) + 2
    failed = 0
    for r in results:
        print(f"{r.name:<{width}} {'PASS' if r.passed else 'FAIL'}")
        if not r.passed:
            failed += 1
            for n in r.notes:
                print(f"    {n}")
    print(f"\n{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


def doctor():
    checks = []
    ver = sh(["/usr/libexec/PlistBuddy", "-c",
              "Print :CFBundleShortVersionString",
              f"{APP_BUNDLE}/Contents/Info.plist"], check=False)
    checks.append((f"installed app v{ver}", bool(ver)))
    checks.append(("app running", app_running()))
    checks.append(("transcripts.sqlite readable", os.path.exists(DB_PATH)))
    for tool in ["SwitchAudioSource", "blueutil", "sqlite3"]:
        checks.append((f"{tool} on PATH",
                       subprocess.run(["which", tool],
                                      capture_output=True).returncode == 0))
    devices = sh(["SwitchAudioSource", "-a"], check=False)
    checks.append((f"BlackHole installed ({BLACKHOLE})", BLACKHOLE in devices))
    mode = sh(["defaults", "read", "com.shhhcribble.app", "activationModeV2"],
              check=False) or "automatic"
    checks.append((f"activation mode {mode!r} tap-compatible",
                   mode in ("automatic", "toggle")))
    # Synthetic-keystroke permission probe (harmless key: fn/none — we just
    # ask System Events to exist; the real test is the first tap_hotkey()).
    ax = subprocess.run(["osascript", "-e",
                         'tell application "System Events" to count processes'],
                        capture_output=True, text=True)
    checks.append(("terminal can drive System Events (Accessibility)",
                   ax.returncode == 0))
    for label, ok in checks:
        print(f"  [{'ok' if ok else '!!'}] {label}")
    return 0 if all(ok for _, ok in checks) else 1


def tier1():
    print("== Tier 1: scripted regression suite ==")
    if not app_running():
        print(f"App not running — open {APP_BUNDLE} first.")
        return 1
    ref = "/tmp/shhhcribble-smoke-ref.aiff"
    say_to_file(ref)
    results = []
    with AudioSandbox():
        for fn in (lambda: scenario_dictation_basic(ref),
                   lambda: scenario_spotify_pause_resume(ref),
                   scenario_escape_cancel,
                   lambda: scenario_rapid_double_tap(ref)):
            r = fn()
            print(f"\n[{r.name}] {'PASS' if r.passed else 'FAIL'}")
            for n in r.notes:
                print(f"   {n}")
            results.append(r)
            time.sleep(2)
    print("\n== Tier 1 summary ==")
    return summarize(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=["doctor", "tier1", "tier2"])
    ap.add_argument("--cold-wait", type=int, default=180,
                    help="seconds to enforce Bluetooth idle before the cold "
                         "test (default 180)")
    args = ap.parse_args()
    if args.command == "doctor":
        sys.exit(doctor())
    if args.command == "tier1":
        sys.exit(tier1())
    sys.exit(tier2(args.cold_wait))


if __name__ == "__main__":
    main()
