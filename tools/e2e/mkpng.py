#!/usr/bin/python3
# A test picture for the e2e suite, no imaging library needed:
#   mkpng.py PATH W H BG [X0,Y0,X1,Y1,RRGGBB ...]
# BG and each box (X1, Y1 exclusive) are RRGGBB.
import struct
import sys
import zlib


def rgb(s):
    return bytes.fromhex(s)


def main():
    path, w, h, bg = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), rgb(sys.argv[4])
    rows = [bytearray(bg * w) for _ in range(h)]
    for spec in sys.argv[5:]:
        x0, y0, x1, y1, c = spec.split(",")
        for y in range(int(y0), int(y1)):
            rows[y][int(x0) * 3:int(x1) * 3] = rgb(c) * (int(x1) - int(x0))
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


main()
