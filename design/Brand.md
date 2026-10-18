# BitTool Signer identity

BitTool Wallet and BitTool Signer share one mark: a ring broken by a solid node — a closed loop with the point where a key is applied. The two apps are told apart by value, not by shape: the **Wallet ships the light version** (ink mark on white), the **Signer the dark one** (white mark on ink `#0A0A0C`). Nothing in the mark names a coin, so it belongs equally to every supported network.

Brand line: **Air-gapped signing. For everyone.** Chinese: **离线签名，人人可用。**

Names: **BitTool Signer** and **BitTool Wallet**, published by BITTOOL PTE. LTD. — [bittool.com](https://bittool.com), [bittool.com/signer](https://bittool.com/signer), [bittool.com/wallet](https://bittool.com/wallet).

## Assets

The mark is drawn from exact geometry (no raster tracing, glow or noise) by [`scripts/make-brand-assets.py`](../scripts/make-brand-assets.py), which needs no third-party packages and writes reproducible, byte-identical outputs:

| File | Use |
|---|---|
| [`Brand/BitToolSigner-Icon.svg`](Brand/BitToolSigner-Icon.svg) | Full-bleed 1024 master for the iOS icon (`AppIcon.png`, opaque, no baked corners). |
| [`Brand/BitToolSigner-Tile.svg`](Brand/BitToolSigner-Tile.svg) | Icon with the continuous-corner shape. It becomes `BrandTile.png`, used by the launch screen, Welcome, App Lock, the privacy cover and Settings, so the first SwiftUI frame continues the launch image without a jump. |
| [`Brand/BitToolSigner-Mark.svg`](Brand/BitToolSigner-Mark.svg) | The mark alone, for documents. |

## Construction (1024 grid)

The geometry is measured from the Wallet icon so both apps are pixel-compatible:

- Ring centred at (512, 511.5): outer radius 372, counter radius 288, so the wall is 84 thick.
- Node: radius 94.8 centred at (828.5, 511.5). It straddles the ring wall — 39 past the outer edge, 66 into the counter — and is united with the ring, not cut out of it.
- Dark (Signer): mark `#FFFFFF` on `#0A0A0C`. Light (Wallet): ink mark on white.
- Corners of the tile follow the iOS continuous corner, approximated by a superellipse of exponent 5.
- In the UI, the accent stays emerald `#0F7B55` (light) and mint `#6BE3A4` (dark). Labels on the accent are white in light mode and ink `#0B1F16` in dark mode.

## Principles

- Light and dark follow the system; the Settings theme picker can override it.
- Contrast, readable address typography, 44 pt touch targets and Dynamic Type come first.
- Network logos (Bitcoin, Ethereum, BNB Chain, Arbitrum, Base, TRON, Solana) are original vector drawings in the asset catalog. They are recognisable renditions of each network's public mark, used only to identify networks.

`design/BitSigner-*.png` are screenshots and rasters from before the rename, kept for reference only.
