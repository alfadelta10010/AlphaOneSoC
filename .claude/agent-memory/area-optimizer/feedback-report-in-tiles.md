---
name: feedback-report-in-tiles
description: User rule (revised 2026-10-25) — design size = whole TT tiles + the shape hardened (AxB), routing density % and area utilization % separately, headroom, flagged limits; no fractional tiles; harden only at TT-selectable sizes
metadata:
  type: feedback
---

**Revised 2026-10-25.** The old rule ("every area figure in tiles, 1 tile ≈ 11,300 µm²
usable at 60 % density", so "14.54 t") is retired: it folded a density into an area
figure and hid whether the design fits.

The user, 2026-10-25: "express the tile area (micrometer square) in terms of tiny
tapeout tiles only. The density number reporting, density and utilization is
different, keep that in percentage. always harden at sizes which are selected for the
tinytapeout ... it always have to be a multiple of tile size. If I ask you what the
size of the design is, I want it in terms of 'X tiles, hardened in AxB, the routing
density is X and the area utilization is Y', and flag concerning limits accordingly."
Clarified: convey that in natural prose, not as a fixed sentence.

- **Design size** = whole TT tiles of the config actually hardened (3x4 -> 12 tiles),
  plus the **shape** (2x6 and 3x4 are both 12 tiles but differ). Configs come from the
  shuttle's `tt-support-tools/tech/sky130A/tile_sizes.yaml`.
- **Routing density** (global-route usage / congestion) and **area utilization**
  (std-cell / core) are two separate percentages; never mix them into an area figure.
- **Headroom:** say how much more fits before placement, routing or timing stops closing.
- **Flag limits** with numbers: high utilization, routing near overflow, thin hold/DRC.
- No fractional "N.NN tiles". Per-block µm² is fine inside an analysis; the headline
  size is always whole tiles. Old "t" figures in this memory were cell µm² / 11,300.
- Harden only at TT-selectable sizes; no custom die areas.

**How to apply:** every area report or table for this project; see [[area-baseline]].
