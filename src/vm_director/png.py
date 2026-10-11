"""PNG encoder for /screenshot: BGRA top-down bytes (what GetDIBits gives) to an RGB PNG.

8-bit RGB (colour type 2), no interlace, filter type 0 on every row, one IDAT chunk, zlib level 6. The channel swap
uses bytearray slice assignment (no per-pixel Python loop); a 1920x1080 frame takes a fraction of a second.
"""

from __future__ import annotations

import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def bgra_to_rgb_rows(width: int, height: int, bgra: bytes) -> bytearray:
    """The PNG scanline data: per row a filter byte 0, then width x (R, G, B)."""
    if width <= 0 or height <= 0:
        raise ValueError("width and height must be positive")
    if len(bgra) != width * height * 4:
        raise ValueError(f"expected {width * height * 4} bytes of BGRA, got {len(bgra)}")
    src = bytes(bgra)
    rgb = bytearray(width * height * 3)
    rgb[0::3] = src[2::4]
    rgb[1::3] = src[1::4]
    rgb[2::3] = src[0::4]
    stride = width * 3
    rows = bytearray((stride + 1) * height)   # zero-filled: every filter byte is already 0
    view = memoryview(rgb)
    for y in range(height):
        o = y * (stride + 1) + 1
        rows[o:o + stride] = view[y * stride:(y + 1) * stride]
    return rows


def encode_png(width: int, height: int, bgra: bytes, level: int = 6) -> bytes:
    raw = bgra_to_rgb_rows(width, height, bgra)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (SIGNATURE + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(raw, level))
            + _chunk(b"IEND", b""))
