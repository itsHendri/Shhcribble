# FieldWhisperer

A native macOS voice-to-text utility.  
Hold **⌥Space** to record, release to transcribe — text is automatically pasted into the focused app.

Powered by [NVIDIA Parakeet V3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) via [FluidAudio](https://github.com/FluidInference/FluidAudio). Runs entirely on-device — no API keys, no cloud.

---

## Features

- **⌥Space push-to-talk** — global hotkey, works in any app, no Input Monitoring required
- **Toggle mode** — tap to start, tap to stop (great for long recordings)
- **Auto-paste** — text goes directly into the focused field (native apps via Accessibility, Electron apps via Cmd+V, clipboard as fallback)
- **Parakeet V3** — ~10x faster than Whisper, better accuracy, no silence hallucination, 25 languages
- **Floating soundwave panel** — shows recording state, live transcription preview, and completion feedback
- **Menu bar only** — no Dock icon
- **Filler word filter** — optionally strips "um", "uh", "hmm" from transcriptions

---

## Install

### From DMG

1. Open the `.dmg`, drag **FieldWhisperer** to **Applications**
2. **Right-click → Open** on first launch (bypasses Gatekeeper — only needed once)
3. Grant **Microphone** when prompted
4. Wait for the model to download (~494 MB, one-time)

> If right-click → Open doesn't work, run `xattr -cr /Applications/FieldWhisperer.app` in Terminal.

### Build from source

```bash
git clone https://github.com/OsamaBinBallZak/field-whisperer.git
cd field-whisperer
open FieldWhisperer.xcodeproj
```

1. Select the **FieldWhisperer** scheme and your Mac as destination
2. **Signing & Capabilities → Team** — pick your Apple Developer team
3. **⌘R** to build and run

Requires **macOS 14.0+** and **Xcode 15.0+**.

---

## Usage

1. Click into any text field
2. **Hold ⌥Space** — soundwave panel appears
3. Speak
4. **Release ⌥Space** — text is transcribed and pasted

> **Toggle mode:** In Settings → Activation, switch to toggle mode. Tap ⌥Space to start, tap again to stop.

---

## Settings

Click the menu bar icon → **Settings…**

| Setting | Options |
|---|---|
| **Model** | Parakeet V3 (multilingual, 25 langs) ✦ / Parakeet V2 (English-optimized) |
| **Activation** | Push-to-talk (hold) / Toggle (tap) |
| **Hotkey** | ⌥Space, ⌃Space, ⌥`, ⌃⌥Space |
| **Filler filter** | On/Off — removes um, uh, hmm |

---

## Permissions

| Permission | Required? | Why |
|---|---|---|
| **Microphone** | Yes | Prompted automatically |
| **Accessibility** | Optional | Enables direct text insertion; without it, text goes to clipboard |

> After rebuilding in Xcode, re-grant Accessibility: remove FieldWhisperer from the list, then re-add it.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| ⌥Space does nothing | Model still loading — wait for "Ready" in menu bar |
| Text not pasted | Grant Accessibility in System Settings → Privacy |
| "No microphone detected" | Connect a mic and check System Settings → Sound → Input |
| App not in menu bar | Check Activity Monitor; rebuild clean (⌘⇧K then ⌘R) |

---

## Distribution

Build a shareable DMG:

```bash
bash Distribution/create-dmg.sh
```

Produces **FieldWhisperer.dmg** on your Desktop. Recipients right-click → Open on first launch.

---

*Originally created by [Hendri](https://github.com/itsHendri/field-whisperer). This fork replaces WhisperKit with Parakeet V3 for faster transcription.*
