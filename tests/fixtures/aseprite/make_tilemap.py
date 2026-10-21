#!/usr/bin/env python3
"""Writes tilemap.aseprite: a 16 x 8 sprite with one tilemap layer, "Ground" (4 x 2 tiles of
4 x 4), and a tileset of 4 tiles (0 empty) with collision properties: 1 solid (red | blue),
2 one-way (green), 3 an area named "spikes" (yellow). The grid:

    1 1 2 0
    3 3 1 1(flipped across)

A second tilemap layer, "Decor", hidden in Aseprite, holds one one-way tile at its top right.

Run it from this folder to make it again."""
import struct, zlib

TILE = 4
def string(s):
    b = s.encode()
    return struct.pack('<H', len(b)) + b

def chunk(kind, data):
    return struct.pack('<IH', len(data) + 6, kind) + data

def user_data(*props):
    if not props:
        return struct.pack('<I', 0)
    body = struct.pack('<II', 0, len(props))
    for name, value in props:
        body += string(name) + struct.pack('<H', 0x0D) + string(value)
    return struct.pack('<III', 4, len(body) + 8, 1) + body

colors = [[(0, 0, 0, 0)] * 2, [(255, 0, 0, 255), (0, 0, 255, 255)], [(0, 255, 0, 255)] * 2, [(255, 255, 0, 255)] * 2]
pixels = bytearray()
for tile in range(4):
    for y in range(TILE):
        for x in range(TILE):
            pixels += bytes(colors[tile][0 if x < TILE // 2 else 1])
tileset_image = zlib.compress(bytes(pixels))

frame = b''
frame += chunk(0x2004, struct.pack('<HHHHHHBBBB', 1, 2, 0, 0, 0, 0, 255, 0, 0, 0) + string('Ground') + struct.pack('<I', 0))
# Hidden (flags 0): built only when named
frame += chunk(0x2004, struct.pack('<HHHHHHBBBB', 0, 2, 0, 0, 0, 0, 255, 0, 0, 0) + string('Decor') + struct.pack('<I', 0))
frame += chunk(0x2023, struct.pack('<IIIHHh', 0, 2 | 4, 4, TILE, TILE, 1) + bytes(14) + string('Terrain') + struct.pack('<I', len(tileset_image)) + tileset_image)
frame += chunk(0x2020, user_data())
frame += chunk(0x2020, user_data())
frame += chunk(0x2020, user_data(('collision', 'solid')))
frame += chunk(0x2020, user_data(('collision', 'one-way')))
frame += chunk(0x2020, user_data(('area', 'spikes')))
tiles = [1, 1, 2, 0, 3, 3, 1, 1 | 0x80000000]
cel = struct.pack('<HhhBHh', 0, 0, 0, 255, 3, 0) + bytes(5)
cel += struct.pack('<HHHIIII', 4, 2, 32, 0x1fffffff, 0x80000000, 0x40000000, 0x20000000) + bytes(10)
cel += zlib.compress(struct.pack('<8I', *tiles))
frame += chunk(0x2005, cel)
decor = struct.pack('<HhhBHh', 1, 0, 0, 255, 3, 0) + bytes(5)
decor += struct.pack('<HHHIIII', 4, 2, 32, 0x1fffffff, 0x80000000, 0x40000000, 0x20000000) + bytes(10)
decor += zlib.compress(struct.pack('<8I', 0, 0, 0, 2, 0, 0, 0, 0))
frame += chunk(0x2005, decor)
chunks = 10

frame_header = struct.pack('<IHHHHI', 16 + len(frame), 0xF1FA, chunks, 100, 0, chunks)
header = struct.pack('<IHHHHHIH', 128 + len(frame_header) + len(frame), 0xA5E0, 1, 16, 8, 32, 1, 100)
header += bytes(128 - len(header))
with open('tilemap.aseprite', 'wb') as f:
    f.write(header + frame_header + frame)
print('wrote tilemap.aseprite')
