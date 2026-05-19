# OpenLark

Free, fully-local voice dictation for macOS. Press `⌘+↑` to record, press it again to transcribe and paste. Powered by NVIDIA Parakeet TDT 0.6B running on Apple's MLX, the audio never leaves your machine.

Typical latency on Apple Silicon: **~150–300 ms** for a short utterance on warm cache.

## Features

- **Local, free, fast.** Parakeet TDT 0.6B v2 via MLX. ~25× realtime on M-series. No API keys, no network calls after the one-time model download.
- **Global hotkey.** `⌘+↑` toggles recording from any app. Escape cancels.
- **Auto-paste.** Transcribed text is dropped straight into whatever text field has focus, and also left on the clipboard so you can paste again with `⌘+V`.
- **Custom vocabulary.** Per-user list of words and snippets (`weboo → webbu`). Forces canonical casing and fixes near-miss phonetic matches.
- **History.** Last 50 transcriptions, searchable, click-to-copy or click-to-repaste.
- **Native menu-bar app.** Borderless overlay with live waveform, draggable, position persists.
- **No telemetry.** Open source.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 14 (Sonoma) or later
- Python 3.11+ via [`uv`](https://github.com/astral-sh/uv)
- `ffmpeg` (used by the inference daemon for audio decoding)

## Install

### From a release

1. Download the latest `OpenLark.app.zip` from [Releases](../../releases).
2. Unzip and drag `OpenLark.app` to `~/Applications`.
3. Install the prerequisites if you don't already have them:
   ```bash
   brew install ffmpeg
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
4. Set up the inference daemon (one-time, downloads the ~600 MB model):
   ```bash
   git clone https://github.com/FabianGenell/openlark.git
   cd openlark
   ./scripts/install-sidecar.sh
   ```
5. Open OpenLark from `~/Applications`. macOS will warn it's from an unidentified developer — right-click → **Open** the first time, then click **Open** in the dialog.
6. Grant **Microphone**, **Accessibility** and **Input Monitoring** in System Settings → Privacy & Security.

### From source

```bash
git clone https://github.com/FabianGenell/openlark
cd openlark
brew install ffmpeg
curl -LsSf https://astral.sh/uv/install.sh | sh
./scripts/setup-signing-identity.sh   # one-time: stable code-signing identity for sticky TCC permissions
./scripts/install.sh                   # builds the app + sets up the inference daemon
open ~/Applications/OpenLark.app
```

## Usage

| Action | Shortcut |
|---|---|
| Start recording | `⌘+↑` |
| Stop & transcribe | `⌘+↑` |
| Cancel recording | `Esc` |

Output is auto-pasted into the focused text field and also kept on the clipboard so you can `⌘+V` again if the paste missed.

The menu bar icon gives you:

- **History…** — last 50 transcriptions, search, copy, paste-again, delete
- **Vocabulary…** — manage custom words and snippets
- **Launch at Login** — toggle auto-start
- **Quit OpenLark**

### Vocabulary

Two entry types:

- **Plain word** (e.g. `GitHub`) — forces canonical casing on matches and rescues near-miss phonetic mistakes ("hithub" → "GitHub").
- **Snippet** (e.g. `weboo → webbu`) — verbatim text replacement.

Stored at `~/Library/Application Support/OpenLark/vocab.json`.

## Architecture

```
┌────────────────────────┐         Unix socket            ┌──────────────────────────┐
│ OpenLark.app (Swift)   │ ─── /tmp/openlark.sock ─────▶ │ openlark-sidecar (Python)│
│  • Menu bar + hotkey   │   (length-prefixed WAV)        │  • parakeet-mlx          │
│  • AVCaptureSession    │ ◀─── transcription text ───── │  • MLX on Apple Silicon  │
│  • Overlay UI          │                                │  • Loaded once, resident │
│  • Vocab + history     │                                │    via launchd           │
│  • Paste injection     │                                └──────────────────────────┘
└────────────────────────┘
```

- The Swift app captures mic input at 16 kHz mono Int16, encodes a WAV, and sends it over a Unix socket.
- The Python daemon runs `parakeet-mlx`, returns the transcription, and the Swift app post-processes against the vocab list before pasting.
- The daemon is kept alive by a `launchd` LaunchAgent — boots with you and the first request hits a warm model (~3 s startup from disk cache).

## File layout

```
openlark/
├── app/                       # Swift Package — the menu bar app
│   ├── Package.swift
│   ├── Sources/OpenLark/
│   └── Resources/
├── sidecar/                   # Python inference daemon
│   ├── server.py
│   └── pyproject.toml
├── scripts/
│   ├── build.sh
│   ├── install.sh
│   ├── install-sidecar.sh
│   ├── make_icon.py
│   └── setup-signing-identity.sh
└── README.md
```

## Sidecar control

```bash
launchctl list | grep openlark               # status
tail -f ~/Library/Logs/OpenLark/sidecar.log  # logs
launchctl unload ~/Library/LaunchAgents/app.openlark.sidecar.plist
launchctl load   ~/Library/LaunchAgents/app.openlark.sidecar.plist
```

## Logs

- App log: `~/Library/Logs/OpenLark/app.log`
- Sidecar log: `~/Library/Logs/OpenLark/sidecar.log`
- Last captured WAV (for debugging): `/tmp/openlark-last.wav`

## Limitations

- **English only.** Parakeet TDT 0.6B v2 is English-only. Swap-in for `mlx-whisper` is planned.
- **Apple Silicon only.** The MLX backend doesn't run on Intel Macs.
- **Bluetooth headset HFP route.** Some Bluetooth headsets advertise a mic but don't actually deliver audio (silent zero samples). If transcription comes back empty, the app log will show `peak=0` — switch to the built-in mic in System Settings → Sound → Input as a fallback.

## License

MIT
