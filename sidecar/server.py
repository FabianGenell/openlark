"""OpenLark inference daemon — multi-model, multi-language.

Listens on a Unix domain socket. Each connection sends one request and
receives one or more length-prefixed JSON responses (last response is
terminal — server closes after it).

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

Only one model is kept loaded at a time — MLX models share GPU memory and
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
import time
import traceback
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

import numpy as np

SOCKET_PATH = os.environ.get("OPENLARK_SOCKET", "/tmp/openlark.sock")
HEADER = struct.Struct(">I")
SOCKET_TIMEOUT_S = 30.0
PREFETCH_TIMEOUT_S = 30 * 60  # 30 min — large Whisper models can take a while on slow links
MAX_PAYLOAD_BYTES = 200 * 1024 * 1024


# ---------------------------------------------------------------------------
# Model registry — Python side
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
        ModelSpec("parakeet-tdt-0.6b-v2",     "mlx-community/parakeet-tdt-0.6b-v2",       "parakeet",   600,  False),
        ModelSpec("parakeet-tdt-0.6b-v3",     "mlx-community/parakeet-tdt-0.6b-v3",       "parakeet",   600,  False),
        ModelSpec("parakeet-tdt-1.1b",        "mlx-community/parakeet-tdt-1.1b",          "parakeet",  1100,  False),
        ModelSpec("whisper-large-v3-turbo",   "mlx-community/whisper-large-v3-turbo",     "whisper",   1600,  True),
        ModelSpec("whisper-large-v3",         "mlx-community/whisper-large-v3-mlx",       "whisper",   3100,  True),
        ModelSpec("whisper-medium",           "mlx-community/whisper-medium-mlx",         "whisper",   1500,  True),
        ModelSpec("whisper-small",            "mlx-community/whisper-small-mlx",          "whisper",    500,  True),
        ModelSpec("distil-whisper-large-v3",  "mlx-community/distil-whisper-large-v3",    "whisper",   1500,  False),
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
        # mlx-whisper transcribes via a top-level call that loads on demand —
        # the "model" we cache is just the repo string. mlx_whisper caches
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

    Refuses to delete the currently-loaded model — caller must switch first.
    """
    global _current_model_id, _current_model
    spec = MODELS[model_id]

    if _current_model_id == model_id:
        # Unload first — Python keeps file handles on .safetensors that
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

    # snapshot_download has no built-in fractional progress callback. We send
    # an indeterminate progress event so the UI can show a spinner, then a
    # terminal "done" event when the download finishes.
    send_event({"event": "progress", "value": -1.0})
    try:
        snapshot_download(
            repo_id=spec.repo,
            # Skip safetensors index duplicates, keep weights + tokenizer.
            allow_patterns=["*.safetensors", "*.json", "*.txt", "*.npz", "*.tiktoken", "tokenizer*", "*.model"],
        )
    except Exception as exc:
        send_event({"event": "error", "message": f"{exc}"})
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
                audio, sr = read_wav_to_float32(wav_bytes)
                # Model load can exceed the 30s default — extend while loading.
                sock.settimeout(PREFETCH_TIMEOUT_S)
                text = transcribe(model_id, languages, audio, sr)
                sock.settimeout(SOCKET_TIMEOUT_S)
                send_frame(sock, {"event": "result", "text": text})
                return

            send_frame(sock, {"event": "error", "message": f"unknown cmd: {cmd}"})

        except socket.timeout:
            log("client timed out — dropping connection")
        except Exception as exc:
            log(f"handler error: {exc}\n{traceback.format_exc()}")
            try:
                send_frame(sock, {"event": "error", "message": str(exc)})
            except OSError:
                pass


class UnixStreamServer(socketserver.UnixStreamServer):
    # Single-threaded by design — MLX binds GPU streams to the loading thread.
    allow_reuse_address = True


def main() -> int:
    socket_path = Path(SOCKET_PATH)
    if socket_path.exists():
        socket_path.unlink()

    # Pre-load the default model so first transcription is instant.
    try:
        load_model(DEFAULT_MODEL_ID)
    except Exception as exc:
        log(f"warning: default model preload failed: {exc}")

    server = UnixStreamServer(str(socket_path), Handler)
    os.chmod(socket_path, 0o600)
    log(f"listening on {socket_path}")

    def shutdown(*_):
        log("shutting down")
        server.shutdown()
        try:
            socket_path.unlink()
        except OSError:
            pass
        sys.exit(0)

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
