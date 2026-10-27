#!/usr/bin/env python3
"""Minimal `cpio -di -u` replacement: extract a newc archive from stdin into cwd."""
import os
import stat
import sys


def main():
    args = [a for a in sys.argv[1:] if a.startswith("-")]
    if not any("i" in a for a in args if not a.startswith("--")):
        raise SystemExit("only extraction (-i) is supported")
    data = sys.stdin.buffer
    pending_links = {}  # (dev, ino) -> [paths] for hardlink sets
    while True:
        hdr = data.read(110)
        if len(hdr) < 110:
            break
        if hdr[:6] not in (b"070701", b"070702"):
            raise SystemExit("unsupported cpio format")
        f = [int(hdr[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        ino, mode, _uid, _gid, nlink, mtime, size = f[0], f[1], f[2], f[3], f[4], f[5], f[6]
        devmaj, devmin, namesize = f[7], f[8], f[11]
        name = data.read(namesize)[:-1].decode("utf-8", "surrogateescape")
        data.read((4 - (110 + namesize) % 4) % 4)
        body = data.read(size)
        data.read((4 - size % 4) % 4)
        if name == "TRAILER!!!":
            break
        path = os.path.normpath(name.lstrip("/"))
        if path.startswith(".."):
            raise SystemExit("refusing path outside cwd: " + name)
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if stat.S_ISDIR(mode):
            os.makedirs(path, exist_ok=True)
            continue
        if os.path.lexists(path) and not os.path.isdir(path):
            os.unlink(path)
        if stat.S_ISLNK(mode):
            os.symlink(body.decode("utf-8", "surrogateescape"), path)
        elif stat.S_ISREG(mode):
            key = (devmaj, devmin, ino)
            if nlink > 1 and size == 0:
                pending_links.setdefault(key, []).append(path)
                continue
            with open(path, "wb") as out:
                out.write(body)
            os.chmod(path, stat.S_IMODE(mode))
            os.utime(path, (mtime, mtime))
            for other in pending_links.pop(key, []):
                if os.path.lexists(other):
                    os.unlink(other)
                os.link(path, other)
        # device nodes, fifos and sockets are not needed for build deps


if __name__ == "__main__":
    main()
