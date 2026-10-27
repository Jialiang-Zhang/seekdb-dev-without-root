#!/usr/bin/env python3
"""Minimal rpm2cpio: write an RPM's decompressed cpio payload to stdout."""
import struct
import subprocess
import sys


def skip_header(f, align):
    magic = f.read(8)
    if magic[:3] != b"\x8e\xad\xe8":
        raise SystemExit("bad rpm header magic")
    count, size = struct.unpack(">II", f.read(8))
    f.read(count * 16 + size)
    if align:
        pad = (8 - (count * 16 + size) % 8) % 8
        f.read(pad)


def main():
    path = sys.argv[1]
    with open(path, "rb") as f:
        if f.read(4) != b"\xed\xab\xee\xdb":
            raise SystemExit("not an rpm: " + path)
        f.read(92)  # rest of the 96-byte lead
        skip_header(f, align=True)   # signature header is 8-byte aligned
        skip_header(f, align=False)  # main header
        payload = f.read()
    if payload[:2] == b"\x1f\x8b":
        cmd = ["gzip", "-dc"]
    elif payload[:6] == b"\xfd7zXZ\x00":
        cmd = ["xz", "-dc"]
    elif payload[:4] == b"\x28\xb5\x2f\xfd":
        cmd = ["zstd", "-dc"]
    elif payload[:3] == b"BZh":
        cmd = ["bzip2", "-dc"]
    elif payload[:6] in (b"070701", b"070702"):
        sys.stdout.buffer.write(payload)
        return
    else:
        raise SystemExit("unknown payload compression in " + path)
    proc = subprocess.run(cmd, input=payload, stdout=sys.stdout.buffer)
    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()
