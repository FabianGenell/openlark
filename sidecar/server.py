"""Parakeet-MLX inference daemon for OpenLark.

Listens on a Unix domain socket. Each connection sends:
  - 4-byte big-endian length
  - WAV-encoded audio bytes (16 kHz mono PCM expected)
Returns:
  - 4-byte big-endian length
  - UTF-8 transcription text

The model is loaded once at startup and reused. Connections are handled
sequentially — MLX binds GPU streams to the loading thread, so parallelism
would not help on a single Apple Silicon device.
"""
from __future__ import annotations

import io
import os
import signal
import socket
import socketserver
import struct
import sys
import time
import traceback
import wave
from pathlib import Path

import mlx.core as mx
import numpy as np
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

SOCKET_PATH = os.environ.get("OPENLARK_SOCKET", "/tmp/openlark.sock")
MODEL_NAME = os.environ.get(
    "OPENLARK_MODEL", "mlx-community/parakeet-tdt-0.6b-v2"
)
HEADER = struct.Struct(">I")
# Per-request socket timeout. A stalled client (system sleep mid-send, crashed
# Swift app) would otherwise block this single-threaded server forever.
SOCKET_TIMEOUT_S = 30.0
# Bytes — 200 MB caps malicious oversize-length frames.
MAX_PAYLOAD_BYTES = 200 * 1024 * 1024

_model = None


def load_model():
    global _model
    if _model is None:
        log(f"loading model {MODEL_NAME}")
        t0 = time.perf_counter()
        _model = from_pretrained(MODEL_NAME)
        log(f"model loaded in {time.perf_counter() - t0:.2f}s")
    return _model


def log(msg: str) -> None:
    sys.stderr.write(f"[sidecar] {msg}\n")
    sys.stderr.flush()


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("client closed mid-frame")
        buf.extend(chunk)
    return bytes(buf)


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


def transcribe_audio(audio: np.ndarray, sr: int) -> str:
    """Transcribe a mono float32 array directly — no temp file, no ffmpeg."""
    model = load_model()
    target_sr = model.preprocessor_config.sample_rate

    if sr != target_sr:
        new_len = int(round(len(audio) * target_sr / sr))
        x_old = np.linspace(0, 1, num=len(audio), endpoint=False, dtype=np.float64)
        x_new = np.linspace(0, 1, num=new_len, endpoint=False, dtype=np.float64)
        audio = np.interp(x_new, x_old, audio).astype(np.float32)

    audio = np.clip(audio, -1.0, 1.0)

    # Feed straight to the model — bypasses load_audio's ffmpeg dependency.
    t0 = time.perf_counter()
    audio_mx = mx.array(audio).astype(mx.float32)
    mel = get_logmel(audio_mx, model.preprocessor_config)
    result = model.generate(mel)[0]
    dur = time.perf_counter() - t0

    text = (result.text or "").strip()
    log(f"transcribed {len(audio) / target_sr:.2f}s in {dur * 1000:.0f}ms → {text!r}")
    return text


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        sock: socket.socket = self.request
        sock.settimeout(SOCKET_TIMEOUT_S)
        try:
            (length,) = HEADER.unpack(recv_exact(sock, HEADER.size))
            if length <= 0 or length > MAX_PAYLOAD_BYTES:
                log(f"rejecting bogus length {length}")
                return
            wav_bytes = recv_exact(sock, length)
            audio, sr = read_wav_to_float32(wav_bytes)
            text = transcribe_audio(audio, sr)
            payload = text.encode("utf-8")
            sock.sendall(HEADER.pack(len(payload)) + payload)
        except socket.timeout:
            log("client timed out — dropping connection")
        except Exception as exc:
            log(f"handler error: {exc}\n{traceback.format_exc()}")
            try:
                err = f"__ERROR__ {exc}".encode("utf-8")
                sock.sendall(HEADER.pack(len(err)) + err)
            except OSError:
                pass


class UnixStreamServer(socketserver.UnixStreamServer):
    # Single-threaded by design — MLX binds GPU streams to the loading thread.
    allow_reuse_address = True


def main() -> int:
    socket_path = Path(SOCKET_PATH)
    if socket_path.exists():
        socket_path.unlink()

    load_model()

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
