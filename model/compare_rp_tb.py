#!/usr/bin/env python3
"""Compare tb_EoV19RpRenderer output rasters with model/golden.py."""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import golden as g  # noqa: E402

CASES = {
    "zero": ([0] * 6, [0] * 6, (1,) * 6),
    "zero2": ([0] * 6, [0] * 6, (1,) * 6),
    "mixed": ([150, -300, 1000, -1000, 0, 777], [-1000, 250, 0, 1000, -60, 5], (1,) * 6),
    "roll10": ([1000] * 6, [0] * 6, (1,) * 6),
    "alt10": ([1000, -1000] * 3, [1000, -1000] * 3, (1,) * 6),
    "absent": ([150, -300, 1000, -1000, 0, 777], [-1000, 250, 0, 1000, -60, 5], (1, 1, 1, 0, 1, 1)),
}


def main():
    out = g.ROOT / "sim_out"
    rom = g.load_rom()
    frames = g.synthetic_frames()
    ok = True
    for name, (r, p, present) in CASES.items():
        f = out / f"rp_{name}.hex"
        if not f.exists():
            print(f"{name}: no output file")
            ok = False
            continue
        got = np.array([int(t, 16) for t in f.read_text().split()], np.int64)
        exp = g.render_offsets(rom, frames, r, p, present).reshape(-1)
        if got.size != exp.size:
            print(f"{name}: {got.size} pixels, expected {exp.size}")
            ok = False
            n = min(got.size, exp.size)
            got, exp = got[:n], exp[:n]
        bad = np.nonzero(got != exp)[0]
        if bad.size:
            ok = False
            first = bad[:8]
            print(f"{name}: {bad.size} mismatches; first at (row, x):",
                  [(int(i) // g.PANO_W, int(i) % g.PANO_W, f"{got[i]:04x}", f"{exp[i]:04x}") for i in first])
            rows = np.unique(bad // g.PANO_W)
            print(f"   rows affected: {rows.size} (first {rows[:10].tolist()})")
        else:
            print(f"{name}: bit-exact ({got.size} pixels)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
