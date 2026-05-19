"""Quick end-to-end probe for the sidecar protocol."""
import socket
import struct
import sys
import time
from pathlib import Path

SOCK = "/tmp/transcribe.sock"
HEADER = struct.Struct(">I")


def main(wav_path: str) -> int:
    data = Path(wav_path).read_bytes()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    t0 = time.perf_counter()
    s.sendall(HEADER.pack(len(data)) + data)

    (length,) = HEADER.unpack(_recv_exact(s, HEADER.size))
    text = _recv_exact(s, length).decode("utf-8")
    dur = time.perf_counter() - t0
    print(f"roundtrip {dur * 1000:.0f}ms")
    print(f"text: {text!r}")
    s.close()
    return 0


def _recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("eof")
        buf.extend(chunk)
    return bytes(buf)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/test.wav"))
