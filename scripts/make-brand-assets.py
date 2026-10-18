"""Regenerates the BitTool Signer mark, app icon and in-app tile.

    python3 scripts/make-brand-assets.py OUTPUT_DIR

BitTool Wallet and BitTool Signer share one mark: a ring broken by a solid node,
drawn from the geometry measured on the Wallet icon (ring 288-372 and a node of
radius 94.8 centred 316.5 to the right, on a 1024 grid). The two apps differ only
in value: the Wallet ships the light version (ink mark on white), the Signer the
dark one (white mark on ink).

Writes mark.svg, icon.svg, tile.svg, AppIcon.png (1024, opaque) and
BrandTile.png (512, continuous corners). Copy the PNGs into
BitToolSigner/Assets.xcassets/AppIcon.appiconset and BrandTile.imageset.
No third-party packages: the shapes are circles, so they are rasterized here by
measuring coverage, and written as PNG with zlib.
"""
import os, struct, sys, zlib

SIZE = 1024
CX, CY = 512.0, 511.5          # ring centre
OUTER, INNER = 372.0, 288.0    # ring outer and counter radius (thickness 84)
NODE_X, NODE_R = 828.5, 94.8   # the node straddles the ring wall and protrudes
INK = (0x0A, 0x0A, 0x0C)       # near-black background of the dark (Signer) version
PAPER = (0xFF, 0xFF, 0xFF)     # the mark itself
SAMPLES = 4                    # per axis, so 16 coverage samples per pixel
SQUIRCLE = 5.0                 # superellipse exponent, the iOS continuous corner


def covers(x, y, scale):
    """True where the mark is: the annulus, united with the node."""
    cx, cy, outer, inner = CX * scale, CY * scale, OUTER * scale, INNER * scale
    nx, nr = NODE_X * scale, NODE_R * scale
    ring = inner * inner <= (x - cx) ** 2 + (y - cy) ** 2 <= outer * outer
    node = (x - nx) ** 2 + (y - cy) ** 2 <= nr * nr
    return ring or node


def coverage(x, y, scale, inside):
    hits = 0
    for sy in range(SAMPLES):
        for sx in range(SAMPLES):
            if inside(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES, scale): hits += 1
    return hits / (SAMPLES * SAMPLES)


def squircle_alpha(x, y, size):
    half = size / 2.0
    u, v = abs(x - half) / half, abs(y - half) / half
    return u ** SQUIRCLE + v ** SQUIRCLE <= 1.0


def png(path, size, rows, alpha):
    """Minimal PNG writer: 8-bit RGB or RGBA, one IDAT, no interlacing."""
    header = struct.pack('>IIBBBBB', size, size, 8, 6 if alpha else 2, 0, 0, 0)
    body = b''.join(b'\x00' + row for row in rows)
    chunks = b''
    for kind, data in ((b'IHDR', header), (b'IDAT', zlib.compress(body, 9)), (b'IEND', b'')):
        chunks += struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunks)


def render(size, rounded):
    scale = size / SIZE
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            ink = coverage(x, y, scale, covers)
            pixel = [round(INK[i] + (PAPER[i] - INK[i]) * ink) for i in range(3)]
            if rounded:
                pixel.append(round(255 * coverage(x, y, size, lambda px, py, _s: squircle_alpha(px, py, size))))
            row += bytes(pixel)
        rows.append(bytes(row))
    return rows


def svg_mark(color='#FFFFFF'):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}">\n'
            f'<path fill="{color}" fill-rule="evenodd" d="'
            f'M{CX - OUTER},{CY} a{OUTER},{OUTER} 0 1,0 {2 * OUTER},0 a{OUTER},{OUTER} 0 1,0 {-2 * OUTER},0 Z '
            f'M{CX - INNER},{CY} a{INNER},{INNER} 0 1,0 {2 * INNER},0 a{INNER},{INNER} 0 1,0 {-2 * INNER},0 Z"/>\n'
            f'<circle fill="{color}" cx="{NODE_X}" cy="{CY}" r="{NODE_R}"/>\n</svg>\n')


def svg_icon(rounded=False):
    clip = (f'<clipPath id="corner"><path d="M0,0 H{SIZE} V{SIZE} H0 Z"/></clipPath>\n') if False else ''
    shape = svg_mark().split('\n', 1)[1].rsplit('</svg>', 1)[0]
    ink = '#%02X%02X%02X' % INK
    radius = f' rx="{SIZE * 0.2237:.1f}" ry="{SIZE * 0.2237:.1f}"' if rounded else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}">\n{clip}'
            f'<rect width="{SIZE}" height="{SIZE}"{radius} fill="{ink}"/>\n{shape}</svg>\n')


out = sys.argv[1] if len(sys.argv) > 1 else '.'
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'mark.svg'), 'w').write(svg_mark())
open(os.path.join(out, 'icon.svg'), 'w').write(svg_icon())
open(os.path.join(out, 'tile.svg'), 'w').write(svg_icon(rounded=True))
png(os.path.join(out, 'AppIcon.png'), 1024, render(1024, rounded=False), alpha=False)
png(os.path.join(out, 'BrandTile.png'), 512, render(512, rounded=True), alpha=True)
print('wrote mark.svg, icon.svg, tile.svg, AppIcon.png, BrandTile.png in', out)
