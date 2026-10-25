---
name: feedback-report-in-tiles
description: User rule (replaced 2026-10-25) — size is a whole TT tile config, area is µm², utilisation is a separate %; no fractional tiles; harden only at TT-selectable sizes
metadata:
  type: feedback
---

**Replaced 2026-10-25.** The old rule ("every area figure in tiles, 1 tile ≈ 11,300 µm²
usable at 60 % density") is retired: it folded a density into an area figure.

The user, 2026-10-25: "was it hardened within 3x4 or not, that's what matters more.
the tile area is for micrometer square only, not for the density number reporting,
density and utilization is different and area is different ... always harden at sizes
which are selected for the tinytapeout ... it always have to be a multiple of tile size."

- **Fit first:** "hardened at 3x4: fits / does not fit", from a real harden.
- **Size** = a TT tile config, whole tiles, from the shuttle's
  `tt-support-tools/tech/sky130A/tile_sizes.yaml` (3x4 = 508.76 x 511.36 µm =
  260,160 µm² die; 1x1 = 161.00 x 111.52 µm).
- **Area** = µm² (die, core, std-cell, per block, deltas).
- **Utilisation / density** = its own %, never mixed into an area number.
- No "N.NN tiles" figures. Old ones in this memory were cell µm² / 11,300.
- Harden only at TT-selectable sizes; no custom die areas.

**How to apply:** every area report or table for this project; see [[area-baseline]].
