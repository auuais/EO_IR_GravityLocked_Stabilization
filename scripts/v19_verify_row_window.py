#!/usr/bin/env python3
"""Prove the RowRun row-window tables bound what the renderer actually reads.

EoV19StreamingRendererII1 never evaluates the exact calibration map.  It
reconstructs each source coordinate from the quantised RowRun chord fit stored
in eo_v19_render_runs.mem:

    cy = ay0 + ((lx - ox0) * day) << DRUN_TO_Q16      qy = cy >> 16

row_max_y0 / row_min_y0 must therefore bound *that* reconstruction, not the
exact map.  Deriving them from the exact map (the defect fixed on 2026-07-29)
left 112/378 output rows whose reconstructed qy exceeded row_max_y0, so
gate_need_row = row_max_y0 + 2 never waited for the row the renderer went on
to address.  The EoV19LineCache read then missed, and because black-on-miss is
currently bypassed in the renderer the miss surfaced as corrupt pixels rather
than a labelled black row.

Contract checked here, with captured_rows == R meaning rows [R-64, R-1] are
complete in the 64-entry ring:

  1. row_min_y0[sy] <= qy <= row_max_y0[sy]   for every token the RTL issues
  2. bilinear needs qy+1, and the renderer waits for R >= row_max_y0+2,
     so qy+1 <= R-1 holds iff check 1 holds
  3. the oldest required row must still be resident: row_max_y0 - row_min_y0
     must satisfy the renderer's FULL admission contract, not just the span.

     The gate binds one variable twice: the renderer waits for
     captured_rows >= row_max_y0 + BILINEAR_LEAD, and declares an overrun above
     row_min_y0 + WINDOW_GUARD.  Comparing the span against the guard alone
     ignores the +2 readiness lead and reports PASS on tables that cannot be
     admitted -- it did exactly that for logical rows 0..3, whose span of 61
     looked fine against 62 while the real requirement was max+2 <= min+62.

Exits non-zero on any violation.  Run after regenerating the RowRun assets.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

W_CAM = [650, 655, 655, 655, 655, 655]
H, NCAM, SEG = 480, 6, 64
SEGS = (655 + SEG - 1) // SEG
QY_LIMIT = 1078
DRUN_FRAC_BITS = 5
WINDOW_GUARD  = 63   # EoV19StreamingRendererII1 WINDOW_GUARD (CACHE_LINES-1)
BILINEAR_LEAD = 2    # the renderer needs source rows m..M+1, i.e. count M+2


def load_mem(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text().splitlines() if line.strip()]


def sext(value: int, width: int) -> int:
    return value - (1 << width) if value >> (width - 1) else value


def record(word: int) -> tuple[int, int, int]:
    """Return (ox0, ay0_q16, day) exactly as the RTL slices the record."""
    return (
        (word >> 16) & 0xFFFF,
        sext((word >> 80) & 0xFFFFFFFF, 32),
        sext((word >> 128) & 0xFFFF, 16),
    )


def qy(cy: int) -> int:
    if cy < 0:
        return 0
    return QY_LIMIT if cy > (QY_LIMIT << 16) else (cy >> 16) & 0x7FF


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rowrun-dir", type=Path, default=Path("assets/rowruns"))
    ap.add_argument("--drun-frac-bits", type=int, default=DRUN_FRAC_BITS)
    args = ap.parse_args()
    drun_to_q16 = 16 - args.drun_frac_bits

    runs = load_mem(args.rowrun_dir / "eo_v19_render_runs.mem")
    row_max = load_mem(args.rowrun_dir / "eo_v19_render_row_max_y0.mem")
    row_min = load_mem(args.rowrun_dir / "eo_v19_render_row_min_y0.mem")

    expected = H * NCAM * SEGS
    if len(runs) != expected or len(row_max) != H or len(row_min) != H:
        print(f"FAIL: asset sizes runs={len(runs)} (expect {expected}) "
              f"max={len(row_max)} min={len(row_min)} (expect {H})")
        return 1

    above = below = 0
    worst_above = worst_below = 0
    first: list[str] = []
    for sy in range(H):
        lo, hi = row_min[sy], row_max[sy]
        for cam in range(NCAM):
            for lx in range(W_CAM[cam]):
                ox0, ay0, day = record(runs[(sy * NCAM + cam) * SEGS + lx // SEG])
                y = qy(ay0 + ((sext((lx - ox0) & 0xFFFF, 16) * day) << drun_to_q16))
                if y > hi:
                    above += 1
                    worst_above = max(worst_above, y - hi)
                    if len(first) < 5:
                        first.append(f"sy={sy} cam={cam} lx={lx} qy={y} > row_max={hi}")
                elif y < lo:
                    below += 1
                    worst_below = max(worst_below, lo - y)
                    if len(first) < 5:
                        first.append(f"sy={sy} cam={cam} lx={lx} qy={y} < row_min={lo}")

    spans = [row_max[sy] - row_min[sy] for sy in range(H)]
    # settled captured_rows for row sy is row_max+BILINEAR_LEAD, given the
    # replay is asked to stop at row_max+BILINEAR_LEAD-1
    over_ring = [(sy, spans[sy]) for sy in range(H)
                 if row_max[sy] + BILINEAR_LEAD > row_min[sy] + WINDOW_GUARD]

    print(f"tokens above row_max_y0 : {above} (worst +{worst_above})")
    print(f"tokens below row_min_y0 : {below} (worst -{worst_below})")
    print(f"row window span min/max : {min(spans)}/{max(spans)} "
          f"(guard {WINDOW_GUARD}, lead {BILINEAR_LEAD})")
    for line in first:
        print("  " + line)
    if over_ring:
        print(f"rows exceeding the ring : {len(over_ring)} e.g. {over_ring[:5]}")

    if above or below or over_ring:
        print("FAIL: row-window tables do not bound the reconstructed coordinates")
        return 1
    print("PASS: every reconstructed source row lies inside its gated window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
