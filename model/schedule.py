#!/usr/bin/env python3
"""Schedule metrics for the source-driven renderer (walker + active queue).

Semantics being sized (see docs/ROLLPITCH_SOURCE_DRIVEN_RENDERER.md):
  * each segment is walked in the direction of increasing source y
  * sched_y(pixel) = clamp(floor(ay), 0, 1078)
  * at y0 the walker takes pixels while sched_y <= y0 (or y0 == Yhi)
  * a segment enters the queue at its first pixel's sched_y
  * rows emit in order once y0 > row_ready[sy]
"""
import sys
import numpy as np
from envelope import load_segments, cs_q15, y_shift_rows, CX, CY, MAX_X, MAX_Y, ROWS, NCAM, SEGS, SEG, CAM_W

def seg_params(seg, roll_cd, pitch_cd):
    ax0, ay0, dax, day = seg
    P = []
    for cam in range(NCAM):
        c, s = cs_q15(-roll_cd[cam]); sh = y_shift_rows(pitch_cd[cam]) << 16
        dx = ax0[:, cam, :] - CX; dy = ay0[:, cam, :] + sh - CY
        Ax = ((c * dx + s * dy) >> 15) + CX; Ay = ((-s * dx + c * dy) >> 15) + CY
        Dx = (c * (dax[:, cam, :] << 11) + s * (day[:, cam, :] << 11)) >> 15
        Dy = (-s * (dax[:, cam, :] << 11) + c * (day[:, cam, :] << 11)) >> 15
        P.append((Ax, Ay, Dx, Dy))
    return P

def metrics(seg, roll_cd, pitch_cd, label):
    P = seg_params(seg, roll_cd, pitch_cd)
    starts, ends, rows = [], [], []
    ylo, yhi = 1 << 20, -1
    for cam in range(NCAM):
        Ax, Ay, Dx, Dy = P[cam]
        for sg in range(SEGS):
            lo = sg * SEG; ln = min(SEG, CAM_W[cam] - lo)
            if ln <= 0: continue
            y_first = Ay[:, sg]; y_last = Ay[:, sg] + (ln - 1) * Dy[:, sg]
            ya = np.minimum(y_first, y_last); yb = np.maximum(y_first, y_last)
            sa = np.clip(ya >> 16, 0, 1078); sb = np.clip(yb >> 16, 0, 1078)
            starts.append(sa); ends.append(sb); rows.append(np.arange(ROWS))
            # valid y range (conservative: endpoints clipped into [0, MAX_Y])
            okA = (ya <= MAX_Y) & (yb >= 0)
            if okA.any():
                ylo = min(ylo, int(np.clip(ya[okA], 0, MAX_Y).min() >> 16))
                yhi = max(yhi, int(np.clip(yb[okA], 0, MAX_Y).max() >> 16))
    st = np.concatenate(starts); en = np.concatenate(ends); ro = np.concatenate(rows)
    st = np.clip(st, ylo, yhi); en = np.clip(en, ylo, yhi)
    ys = np.arange(ylo, yhi + 1)
    new_per_y = np.bincount(st - ylo, minlength=len(ys))
    end_per_y = np.bincount(en - ylo, minlength=len(ys))
    active = np.cumsum(new_per_y) - np.concatenate(([0], np.cumsum(end_per_y)[:-1]))
    visits = int((en - st + 1).sum())
    row_ready = np.full(ROWS, ylo, np.int64)
    np.maximum.at(row_ready, ro, en)
    print(f"{label:28s} Y={ylo}..{yhi} segs={st.size} visits={visits} "
          f"maxActive={int(active.max())} maxNew/y0={int(new_per_y.max())} "
          f"rowready_max={int(row_ready.max())}")
    return active.max()

if __name__ == "__main__":
    seg = load_segments()
    z = [0] * 6
    for label, r, p in [("zero", z, z), ("roll +10", [1000]*6, z),
                        ("roll+-10 pitch+-10 alt", [1000, -1000]*3, [1000, -1000]*3),
                        ("pitch -10", z, [-1000]*6), ("roll -10 pitch +10", [-1000]*6, [1000]*6)]:
        metrics(seg, r, p, label)
