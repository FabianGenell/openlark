# OpenLark

Free, fully-local voice dictation for macOS. Press `⌘+↑` to record, press it again to transcribe and paste. Powered by NVIDIA Parakeet TDT 0.6B running on Apple's MLX, the audio never leaves your machine.

Typical latency on Apple Silicon: **~150–300 ms** for a short utterance on warm cache.

## Features

- **Local, free, fast.** Parakeet TDT 0.6B v2 via MLX. ~25× realtime on M-series. No API keys, no network calls after the one-time model download.
- **Global hotkey.** `⌘+↑` toggles recording from any app. Escape cancels.
- **Auto-paste.** Transcribed text is dropped straight into whatever text field has focus, and also left on the clipboard so you can paste again with `⌘+V`.
- **Custom vocabulary.** Per-user list of words and snippets (`weboo → webbu`). Forces canonical casing and fixes near-miss phonetic mistakes.
- **History.** Last 50 transcriptions, searchable, click-to-copy or click-to-repaste.
- **Usage stats.** Average WPM, words this week, distinct apps you've dictated into, estimated time saved vs typing at 40 WPM.
- **Unified Settings.** Sidebar layout: General, Vocabulary, Models, About.
- **Native menu-bar app.** Borderless overlay with live waveform, draggable, position persists. Stays above fullscreen apps; follows you across Spaces.
- **No telemetry.** Open source. MIT licensed.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 14 (Sonoma) or later
- [`uv`](https://github.com/astral-sh/uv) for the Python sidecar
- Python 3.11+ (uv will fetch this for you)

> ⚠ `ffmpeg` is **no longer required** as of v0.2.0. The sidecar decodes WAV in Python and feeds the model directly.

## Install

### From a release

1. Download the latest `OpenLark.app.zip` from [Releases](../../releases) and unzip.
2. Drag `OpenLark.app` to `~/Applications` and open it. The app is signed and notarized by Apple (Heltra LLC), so it opens with no Gatekeeper warning.
3. The app walks you through:
   - Granting **Microphone**, **Accessibility** and **Input Monitoring** permissions
   - Downloading the speech engine (one-time, ~144 MB, embedded Python + Parakeet MLX libraries)
   - Background daemon registration
4. Press your hotkey (default `⌘+↑`) and dictate.

That's it. No `git clone`, no manual `pip install`, no shell scripts. The first transcription also fetches the ~600 MB Parakeet model from HuggingFace (~3 min on typical broadband).

### From source

```bash
git clone https://github.com/FabianGenell/openlark
cd openlark
./scripts/setup-signing-identity.sh   # one-time: local code-signing identity for sticky TCC permissions
./scripts/build.sh                     # builds build/OpenLark.app
cp -R build/OpenLark.app ~/Applications/
open ~/Applications/OpenLark.app       # runs the same first-launch installer as the release
```

For developing the sidecar without going through the embedded installer flow, `./scripts/install-sidecar.sh` is still around as a fallback (requires `uv`).

## Usage

| Action | Shortcut |
|---|---|
| Start recording | `⌘+↑` |
| Stop & transcribe | `⌘+↑` |
| Cancel recording | `Esc` |

Output is auto-pasted into the focused text field and also kept on the clipboard so you can `⌘+V` again if the paste missed.

The menu bar icon gives you:

- **History…** last 50 transcriptions with stats card on top
- **Settings…** General (launch at login, hotkey), Vocabulary, Models, About
- **Quit OpenLark**

### Vocabulary

Two entry types:

- **Plain word** (e.g. `GitHub`) forces canonical casing on matches and rescues near-miss phonetic mistakes ("hithub" → "GitHub").
- **Snippet** (e.g. `weboo → webbu`) does verbatim text replacement.

Stored at `~/Library/Application Support/OpenLark/vocab.json`.

### Stats

Visible in the Settings → General pane and at the top of History:

- **Average speed.** Lifetime dictation WPM
- **Words this week.** Total words across the last 7 days
- **Apps used.** Distinct apps you've dictated into this week
- **Saved this week.** Estimated minutes saved vs typing at 40 WPM

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
- The daemon is kept alive by a `launchd` LaunchAgent, so it boots with you and the first request hits a warm model (~3 s startup from disk cache).

## File layout

```
openlark/
├── app/                       # Swift Package, the menu bar app
│   ├── Package.swift
│   └── Sources/OpenLark/
├── sidecar/                   # Python inference daemon
│   ├── server.py
│   └── pyproject.toml
├── scripts/
│   ├── build.sh                       # builds OpenLark.app
│   ├── install.sh                     # full install: sidecar + .app to ~/Applications
│   ├── install-sidecar.sh             # sidecar-only installer (for release downloads)
│   ├── uninstall.sh                   # clean removal (--keep-data flag preserves vocab/history)
│   ├── setup-signing-identity.sh      # one-time stable code-signing identity
│   ├── release.sh                     # bump version + tag + push (triggers CI release)
│   └── make_icon.py
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
- Last captured WAV (DEBUG builds only): `/tmp/openlark-last.wav`

## Uninstall

```bash
./scripts/uninstall.sh                 # remove everything
./scripts/uninstall.sh --keep-data     # remove app but preserve vocab + history
```

## Releasing (maintainers)

```bash
./scripts/release.sh 0.3.0
```

Bumps `CFBundleShortVersionString` + `CFBundleVersion` in `Info.plist`, commits, tags, pushes. The GitHub Actions workflow then builds + publishes the release with the prebuilt `OpenLark.app.zip` and a SHA-256 checksum.

## Limitations

- **English only.** Parakeet TDT 0.6B v2 is English-only. Swap-in for `mlx-whisper` is on the roadmap.
- **Apple Silicon only.** The MLX backend doesn't run on Intel Macs.
- **Bluetooth headset HFP route.** Some Bluetooth headsets advertise a mic but don't actually deliver audio (silent zero samples). If transcription comes back empty, the app log will show `peak=0`. Switch to the built-in mic in System Settings → Sound → Input as a fallback.

## License

[MIT](LICENSE)
