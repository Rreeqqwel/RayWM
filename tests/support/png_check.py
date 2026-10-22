#!/usr/bin/env python3
"""Validates a PNG written by grim and checks its pixels (stdlib only).

usage: png_check.py FILE [--size WxH] [--size-near WxH] [--pixel X,Y,RRGGBB]...

Decodes the whole image: signature, chunk CRCs, IHDR, zlib stream and
every scanline filter, so a truncated or corrupt file fails. --size wants
exactly WxH; --size-near accepts +-1 per side (slurp edge rounding).
Pixels are compared per channel with a tolerance of 2. Exit status 0 when
everything matches; otherwise the reasons are printed.
"""
import struct
import sys
import zlib


def decode(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG signature")
    pos, ihdr, idat, end = 8, None, bytearray(), False
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError("truncated chunk header")
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if len(body) != length or pos + 12 + length > len(data):
            raise ValueError("truncated chunk " + ctype.decode("latin-1"))
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc:
            raise ValueError("bad CRC in chunk " + ctype.decode("latin-1"))
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            end = True
            break
        pos += 12 + length
    if ihdr is None or not end:
        raise ValueError("missing IHDR or IEND")
    width, height, depth, ctype, _, _, interlace = ihdr
    if depth != 8 or ctype not in (2, 6) or interlace != 0:
        raise ValueError("unsupported PNG: depth %d, color type %d, interlace %d" % (depth, ctype, interlace))
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    if len(raw) != height * (stride + 1):
        raise ValueError("pixel data has %d bytes, expected %d" % (len(raw), height * (stride + 1)))
    rows, prev = [], bytearray(stride)
    for y in range(height):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
            elif ftype != 0:
                raise ValueError("bad filter type %d in row %d" % (ftype, y))
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, errors = argv[1], []
    try:
        width, height, bpp, rows = decode(path)
    except (OSError, ValueError, zlib.error) as e:
        print("%s: invalid PNG: %s" % (path, e))
        return 1
    args = argv[2:]
    while args:
        opt, val = args[0], args[1]
        args = args[2:]
        if opt in ("--size", "--size-near"):
            w, h = (int(v) for v in val.split("x"))
            slack = 1 if opt == "--size-near" else 0
            if abs(width - w) > slack or abs(height - h) > slack:
                errors.append("size %dx%d, expected %dx%d" % (width, height, w, h))
        elif opt == "--pixel":
            x, y, rgb = val.split(",")
            x, y = int(x), int(y)
            want = tuple(int(rgb[i:i + 2], 16) for i in (0, 2, 4))
            if not (0 <= x < width and 0 <= y < height):
                errors.append("pixel %d,%d outside the image" % (x, y))
                continue
            got = tuple(rows[y][x * bpp:x * bpp + 3])
            if any(abs(g - w) > 2 for g, w in zip(got, want)):
                errors.append("pixel %d,%d is %02x%02x%02x, expected %s" % (x, y, got[0], got[1], got[2], rgb))
        else:
            print("unknown option " + opt)
            return 2
    for e in errors:
        print("%s: %s" % (path, e))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
