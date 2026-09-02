"""OpenLark inference daemon: multi-model, multi-language.

Listens on a Unix domain socket. Each connection sends one request and
receives one or more length-prefixed JSON responses (last response is
terminal, server closes after it).

Wire format (v2):
  REQUEST:
    [4 bytes BE]  header_len
    [N bytes]     UTF-8 JSON header  { "cmd": "transcribe" | "prefetch" | "models" | "ping", ... }
    If cmd == "transcribe":
      [4 bytes BE]  audio_len
      [N bytes]     WAV-encoded audio (16 kHz mono PCM expected)

  RESPONSE: one or more length-prefixed UTF-8 JSON frames.
    [4 bytes BE]  body_len
    [N bytes]     UTF-8 JSON
    ...
    Connection closes after the terminal frame.

  Response events:
    transcribe ->  { "event": "result", "text": "..." }
    prefetch  ->  { "event": "progress", "value": 0..1 }* then { "event": "done" }
    models    ->  { "event": "models", "models": [{ id, downloaded, backend, sizeMB, languages }] }
    any       ->  { "event": "error", "message": "..." }

Only one model is kept loaded at a time. MLX models share GPU memory and
keeping multiple loaded blows the budget on a 16 GB Mac.
"""
from __future__ import annotations

import io
import json
import os
import signal
import socket
import socketserver
import struct
import sys
import threading
import time
import traceback
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# Bound every HuggingFace network read. Without this a stalled/trickling
# connection (captive portal, throttled CDN) can leave from_pretrained /
# snapshot_download blocking indefinitely on a socket read. This caps each
# individual read so a dead connection raises instead of hanging forever.
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "30")

import numpy as np

SOCKET_PATH = os.environ.get("OPENLARK_SOCKET", "/tmp/openlark.sock")
HEADER = struct.Struct(">I")
SOCKET_TIMEOUT_S = 30.0
PREFETCH_TIMEOUT_S = 30 * 60  # 30 min, large Whisper models can take a while on slow links
MAX_PAYLOAD_BYTES = 200 * 1024 * 1024

# ---------------------------------------------------------------------------
# Watchdog - self-healing hang recovery
#
# The server is single-threaded and every request runs synchronously on the
# main thread. If a request wedges (a stuck MLX call, a runaway model load,
# a signal-handler deadlock), the socket timeout does NOT help: it only guards
# the blocking recv/send syscalls, not the compute in between. A hung process
# stays alive, so launchd's KeepAlive never respawns it and the app blocks
# forever waiting for a reply.
#
# The watchdog is a daemon thread that force-exits the process if the current
# request runs past a per-command hard deadline. On exit, launchd (KeepAlive)
# restarts the daemon and the default model reloads in ~2s. Any single stuck
# request self-heals instead of bricking dictation until the next reboot.
# ---------------------------------------------------------------------------

# Per-command hard deadlines (seconds). Transcription is normally <3s; a cold
# model load adds a few more. 180s is far above any healthy path but low enough
# that a real hang recovers quickly. Prefetch downloads legitimately take long.
DEADLINE_BY_CMD = {
    "ping": 15.0,
    "models": 60.0,
    "delete": 120.0,
    "transcribe": 180.0,
    "prefetch": 45 * 60.0,
}
DEFAULT_DEADLINE_S = 60.0
WATCHDOG_POLL_S = 5.0
# How often the daemon emits a keepalive frame during a model download so the
# app can bound its per-recv wait without false-tripping on a live download.
PREFETCH_HEARTBEAT_S = 5.0

_watchdog_lock = threading.Lock()
_request_deadline: Optional[float] = None  # monotonic deadline of the in-flight request


def _arm_watchdog(seconds: float) -> None:
    global _request_deadline
    with _watchdog_lock:
        _request_deadline = time.monotonic() + seconds


def _disarm_watchdog() -> None:
    global _request_deadline
    with _watchdog_lock:
        _request_deadline = None


def _watchdog_loop() -> None:
    while True:
        time.sleep(WATCHDOG_POLL_S)
        with _watchdog_lock:
            deadline = _request_deadline
        if deadline is not None and time.monotonic() > deadline:
            log("watchdog: request exceeded its deadline - force-exiting so launchd respawns a fresh daemon")
            # os._exit skips atexit/finally on purpose: the process may be
            # wedged in native code where a clean shutdown could itself hang.
            os._exit(1)


# ---------------------------------------------------------------------------
# Model registry, Python side
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ModelSpec:
    id: str           # canonical id used by the Swift side
    repo: str         # HuggingFace repo id
    backend: str      # "parakeet" | "whisper"
    size_mb: int
    multilingual: bool


MODELS: dict[str, ModelSpec] = {
    spec.id: spec for spec in [
        # size_mb is the real download size (single fp32 safetensors for the
        # Parakeet repos), not the parameter count.
        ModelSpec("parakeet-tdt-0.6b-v3",         "mlx-community/parakeet-tdt-0.6b-v3",         "parakeet",  2508,  True),
        ModelSpec("parakeet-tdt-0.6b-v2",         "mlx-community/parakeet-tdt-0.6b-v2",         "parakeet",  2472,  False),
        ModelSpec("parakeet-tdt-ctc-110m",        "mlx-community/parakeet-tdt_ctc-110m",        "parakeet",   459,  False),
        ModelSpec("parakeet-tdt-1.1b",            "mlx-community/parakeet-tdt-1.1b",            "parakeet",  4282,  False),
        ModelSpec("whisper-large-v3-turbo",       "mlx-community/whisper-large-v3-turbo",       "whisper",   1614,  True),
        # The "-4bit" repo ships model.safetensors, which mlx-whisper cannot
        # load; it wants weights.npz / weights.safetensors. "-q4" has that.
        ModelSpec("whisper-large-v3-turbo-q4",    "mlx-community/whisper-large-v3-turbo-q4",    "whisper",    464,  True),
        ModelSpec("whisper-large-v3",             "mlx-community/whisper-large-v3-mlx",         "whisper",   3084,  True),
        ModelSpec("whisper-medium",               "mlx-community/whisper-medium-mlx",           "whisper",   1525,  True),
        ModelSpec("whisper-small",                "mlx-community/whisper-small-mlx",            "whisper",    481,  True),
        ModelSpec("distil-whisper-large-v3",      "mlx-community/distil-whisper-large-v3",      "whisper",   1509,  False),
    ]
}

DEFAULT_MODEL_ID = "parakeet-tdt-0.6b-v2"


# ---------------------------------------------------------------------------
# Loaded-model cache
# ---------------------------------------------------------------------------

_current_model_id: Optional[str] = None
_current_model: Any = None


def log(msg: str) -> None:
    sys.stderr.write(f"[sidecar] {msg}\n")
    sys.stderr.flush()


def hf_cache_has(repo: str) -> bool:
    """Best-effort check: is this repo already in the local HF cache?"""
    base = Path(os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface"))) / "hub"
    folder_name = "models--" + repo.replace("/", "--")
    snapshots = base / folder_name / "snapshots"
    if not snapshots.is_dir():
        return False
    # A repo is "downloaded" once a snapshot exists with at least one weight file.
    for snap in snapshots.iterdir():
        for entry in snap.rglob("*"):
            if entry.is_file() and entry.suffix in (".safetensors", ".bin", ".npz", ".gguf"):
                return True
    return False


def load_model(model_id: str) -> Any:
    """Load (or return cached) model. Unloads any previously loaded one."""
    global _current_model_id, _current_model

    if model_id == _current_model_id and _current_model is not None:
        return _current_model

    if model_id not in MODELS:
        raise ValueError(f"unknown model id: {model_id}")
    spec = MODELS[model_id]

    if _current_model is not None:
        log(f"unloading current model {_current_model_id}")
        _current_model = None  # let GC reclaim before next load

    log(f"loading {spec.backend} model {spec.repo}")
    t0 = time.perf_counter()
    if spec.backend == "parakeet":
        from parakeet_mlx import from_pretrained
        _current_model = ("parakeet", from_pretrained(spec.repo))
    elif spec.backend == "whisper":
        # mlx-whisper transcribes via a top-level call that loads on demand.
        # The "model" we cache is just the repo string. mlx_whisper caches
        # the loaded weights internally per process.
        import mlx_whisper  # noqa: F401  (verify dep is present)
        _current_model = ("whisper", spec.repo)
    else:
        raise ValueError(f"unsupported backend: {spec.backend}")

    _current_model_id = model_id
    log(f"loaded {model_id} in {time.perf_counter() - t0:.2f}s")
    return _current_model


# ---------------------------------------------------------------------------
# Audio decoding
# ---------------------------------------------------------------------------

def read_wav_to_float32(data: bytes) -> tuple[np.ndarray, int]:
    """Decode a WAV byte buffer into a mono float32 array in [-1, 1]."""
    with wave.open(io.BytesIO(data), "rb") as wf:
        n_channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)

    if sample_width == 2:
        audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sample_width == 4:
        audio = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif sample_width == 1:
        audio = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise ValueError(f"unsupported sample width {sample_width}")

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    return audio, framerate


def resample_to(audio: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    if src_sr == dst_sr:
        return audio
    new_len = int(round(len(audio) * dst_sr / src_sr))
    x_old = np.linspace(0, 1, num=len(audio), endpoint=False, dtype=np.float64)
    x_new = np.linspace(0, 1, num=new_len, endpoint=False, dtype=np.float64)
    return np.interp(x_new, x_old, audio).astype(np.float32)


# ---------------------------------------------------------------------------
# Inference
# ---------------------------------------------------------------------------

def transcribe_with_parakeet(model_handle, audio: np.ndarray, sr: int) -> str:
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    _, model = model_handle
    target_sr = model.preprocessor_config.sample_rate
    audio = resample_to(audio, sr, target_sr)
    audio = np.clip(audio, -1.0, 1.0)
    audio_mx = mx.array(audio).astype(mx.float32)
    mel = get_logmel(audio_mx, model.preprocessor_config)
    result = model.generate(mel)[0]
    return (result.text or "").strip()


def transcribe_with_whisper(model_handle, audio: np.ndarray, sr: int, languages: list[str]) -> str:
    import mlx_whisper

    _, repo = model_handle
    audio = resample_to(audio, sr, 16000)
    audio = np.clip(audio, -1.0, 1.0)

    # 1 language → force it (fastest, most accurate).
    # 0 or 2+ → let Whisper auto-detect.
    kwargs: dict[str, Any] = {"path_or_hf_repo": repo, "fp16": True}
    if len(languages) == 1:
        kwargs["language"] = languages[0]

    result = mlx_whisper.transcribe(audio, **kwargs)
    return (result.get("text") or "").strip()


def transcribe(model_id: str, languages: list[str], audio: np.ndarray, sr: int) -> str:
    handle = load_model(model_id)
    backend = handle[0]
    t0 = time.perf_counter()
    if backend == "parakeet":
        text = transcribe_with_parakeet(handle, audio, sr)
    elif backend == "whisper":
        text = transcribe_with_whisper(handle, audio, sr, languages)
    else:
        raise ValueError(f"unsupported backend {backend}")
    dur = time.perf_counter() - t0
    log(f"transcribed {len(audio) / sr:.2f}s with {model_id} in {dur * 1000:.0f}ms → {text!r}")
    return text


# ---------------------------------------------------------------------------
# Prefetch (download a model without using it)
# ---------------------------------------------------------------------------

def delete_model(model_id: str) -> None:
    """Remove a model from the HuggingFace cache.

    Refuses to delete the currently-loaded model. Caller must switch first.
    """
    global _current_model_id, _current_model
    spec = MODELS[model_id]

    if _current_model_id == model_id:
        # Unload first. Python keeps file handles on .safetensors that
        # block rmtree on some systems.
        _current_model = None
        _current_model_id = None

    import shutil
    base = Path(os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface"))) / "hub"
    folder_name = "models--" + spec.repo.replace("/", "--")
    target = base / folder_name
    if target.is_dir():
        log(f"deleting {target}")
        shutil.rmtree(target, ignore_errors=True)


def prefetch(model_id: str, send_event) -> None:
    if model_id not in MODELS:
        raise ValueError(f"unknown model id: {model_id}")
    spec = MODELS[model_id]

    if hf_cache_has(spec.repo):
        send_event({"event": "done"})
        return

    from huggingface_hub import snapshot_download

    # snapshot_download has no fractional progress callback, so we run it on a
    # worker thread and emit an indeterminate progress heartbeat every few
    # seconds while it runs. The heartbeat lets the client tell a live download
    # apart from a wedged one: it resets a bounded per-recv timeout on the app
    # side, so a real stall (no frame for the timeout window) surfaces as an
    # error there instead of an infinite spinner. HF_HUB_DOWNLOAD_TIMEOUT also
    # caps each read so a dead connection raises here within ~30s.
    send_event({"event": "progress", "value": -1.0})

    result: dict[str, Any] = {}

    def _run() -> None:
        try:
            snapshot_download(
                repo_id=spec.repo,
                # Skip safetensors index duplicates, keep weights + tokenizer.
                allow_patterns=["*.safetensors", "*.json", "*.txt", "*.npz", "*.tiktoken", "tokenizer*", "*.model"],
            )
            result["ok"] = True
        except Exception as exc:  # noqa: BLE001 - surfaced to the client below
            result["error"] = str(exc)

    worker = threading.Thread(target=_run, name="prefetch-download", daemon=True)
    worker.start()
    while worker.is_alive():
        worker.join(timeout=PREFETCH_HEARTBEAT_S)
        if worker.is_alive():
            send_event({"event": "progress", "value": -1.0})

    if "error" in result:
        send_event({"event": "error", "message": result["error"]})
        return
    send_event({"event": "done"})


# ---------------------------------------------------------------------------
# Wire helpers
# ---------------------------------------------------------------------------

def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("client closed mid-frame")
        buf.extend(chunk)
    return bytes(buf)


def send_frame(sock: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj).encode("utf-8")
    sock.sendall(HEADER.pack(len(payload)) + payload)


def recv_header(sock: socket.socket) -> dict:
    (length,) = HEADER.unpack(recv_exact(sock, HEADER.size))
    if length <= 0 or length > 64 * 1024:
        raise ValueError(f"bogus header length {length}")
    raw = recv_exact(sock, length)
    return json.loads(raw.decode("utf-8"))


def recv_audio(sock: socket.socket) -> bytes:
    (length,) = HEADER.unpack(recv_exact(sock, HEADER.size))
    if length <= 0 or length > MAX_PAYLOAD_BYTES:
        raise ValueError(f"bogus audio length {length}")
    return recv_exact(sock, length)


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        sock: socket.socket = self.request
        sock.settimeout(SOCKET_TIMEOUT_S)
        try:
            header = recv_header(sock)
        except Exception as exc:
            log(f"bad header: {exc}")
            return

        cmd = header.get("cmd", "transcribe")  # default for forward-compat with the simplest clients
        _arm_watchdog(DEADLINE_BY_CMD.get(cmd, DEFAULT_DEADLINE_S))
        try:
            if cmd == "ping":
                send_frame(sock, {"event": "pong"})
                return

            if cmd == "models":
                models = [
                    {
                        "id": spec.id,
                        "backend": spec.backend,
                        "sizeMB": spec.size_mb,
                        "multilingual": spec.multilingual,
                        "downloaded": hf_cache_has(spec.repo),
                    }
                    for spec in MODELS.values()
                ]
                send_frame(sock, {"event": "models", "models": models})
                return

            if cmd == "prefetch":
                sock.settimeout(PREFETCH_TIMEOUT_S)
                model_id = header.get("model", DEFAULT_MODEL_ID)
                prefetch(model_id, lambda ev: send_frame(sock, ev))
                return

            if cmd == "delete":
                model_id = header.get("model")
                if not model_id or model_id not in MODELS:
                    send_frame(sock, {"event": "error", "message": f"unknown model id: {model_id}"})
                    return
                delete_model(model_id)
                send_frame(sock, {"event": "done"})
                return

            if cmd == "transcribe":
                model_id = header.get("model", DEFAULT_MODEL_ID)
                languages = header.get("languages", []) or []
                wav_bytes = recv_audio(sock)
                # Never download a model inside a transcribe request. A cold
                # download (~600 MB) far exceeds any sane client timeout, so the
                # app would time out, kill the daemon mid-download, and retry -
                # an infinite loop that never produces text. Fail fast instead;
                # the model is fetched explicitly via the `prefetch` command
                # (onboarding + Settings), which streams progress.
                spec = MODELS.get(model_id)
                if spec is None:
                    send_frame(sock, {"event": "error", "message": f"unknown model id: {model_id}", "code": "unknown_model"})
                    return
                if _current_model_id != model_id and not hf_cache_has(spec.repo):
                    send_frame(sock, {"event": "error", "message": f"model not downloaded: {model_id}", "code": "model_missing"})
                    return
                audio, sr = read_wav_to_float32(wav_bytes)
                # A cached model load still costs a couple seconds - extend the
                # socket timeout while loading + transcribing (watchdog covers it).
                sock.settimeout(PREFETCH_TIMEOUT_S)
                text = transcribe(model_id, languages, audio, sr)
                sock.settimeout(SOCKET_TIMEOUT_S)
                send_frame(sock, {"event": "result", "text": text})
                return

            send_frame(sock, {"event": "error", "message": f"unknown cmd: {cmd}"})

        except socket.timeout:
            log("client timed out, dropping connection")
        except Exception as exc:
            log(f"handler error: {exc}\n{traceback.format_exc()}")
            try:
                send_frame(sock, {"event": "error", "message": str(exc)})
            except OSError:
                pass
        finally:
            _disarm_watchdog()


class UnixStreamServer(socketserver.UnixStreamServer):
    # Single-threaded by design. MLX binds GPU streams to the loading thread.
    allow_reuse_address = True


def main() -> int:
    socket_path = Path(SOCKET_PATH)
    if socket_path.exists():
        socket_path.unlink()

    # Watchdog first - before anything that could wedge (model load, socket
    # bind). A hang during startup now still force-exits and lets launchd respawn.
    threading.Thread(target=_watchdog_loop, name="watchdog", daemon=True).start()

    # Bind + start listening BEFORE any model work. UnixStreamServer.__init__
    # binds and calls listen(), so the socket exists and accepts connections
    # the instant this returns. This is critical for first launch: the app can
    # connect immediately and get a fast, honest answer (even "model_missing")
    # instead of the daemon being unreachable for minutes while it downloads a
    # model - which used to make every dictation kick the daemon and restart
    # the download from scratch, forever.
    server = UnixStreamServer(str(socket_path), Handler)
    os.chmod(socket_path, 0o600)
    log(f"listening on {socket_path}")

    # Preload the default model ONLY if it is already downloaded. Never trigger
    # a network download here - that is what wedged startup before. A cold model
    # is fetched via the explicit `prefetch` command (onboarding + Settings)
    # with a progress UI; the first transcribe then loads the cached weights.
    try:
        spec = MODELS.get(DEFAULT_MODEL_ID)
        if spec is not None and hf_cache_has(spec.repo):
            _arm_watchdog(DEADLINE_BY_CMD["transcribe"])
            load_model(DEFAULT_MODEL_ID)
            _disarm_watchdog()
        else:
            log(f"default model {DEFAULT_MODEL_ID} not downloaded - will load on first use after prefetch")
    except Exception as exc:
        _disarm_watchdog()
        log(f"warning: default model preload failed: {exc}")

    def shutdown(*_):
        # Runs on the main thread, interrupting serve_forever(). Do NOT call
        # server.shutdown() here - it blocks until serve_forever() returns,
        # which cannot happen while this handler owns the main thread. That
        # self-deadlock left the daemon alive-but-wedged (holding the socket,
        # never serving), which launchd's KeepAlive can't recover from because
        # the process never dies. Just unlink and hard-exit; launchd respawns.
        log("shutting down")
        try:
            socket_path.unlink()
        except OSError:
            pass
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    finally:
        try:
            socket_path.unlink()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
