#!/usr/bin/env python3
"""Size the source-driven renderer for live per-camera roll/pitch offsets.

Works on the RTL's own segment ROM (assets/rowruns/eo_v19_render_runs.mem),
transformed per camera exactly the way the new RTL will do it:

    by'  = ay0 + y_shift
    A_x  = ((c*(ax0-cx) + s*(by'-cy)) >>> 15) + cx
    A_y  = ((-s*(ax0-cx) + c*(by'-cy)) >>> 15) + cy
    D_x  = (c*dax16 + s*day16) >>> 15
    D_y  = (-s*dax16 + c*day16) >>> 15
    pixel i of the segment: (A_x + i*D_x, A_y + i*D_y)

c,s are Q15 with 32768 representable, so zero roll is the exact identity.
"""
import math, sys
import numpy as np

W_SRC, H_SRC = 1920, 1080
CX, CY = W_SRC << 15, H_SRC << 15
MAX_X, MAX_Y = (W_SRC - 2) << 16, (H_SRC - 2) << 16
ROWS, NCAM, SEGS, SEG = 480, 6, 11, 64
CAM_W = [650, 655, 655, 655, 655, 655]
PITCH_TR = -9.80   # eo pitch_to_translation_factor

def load_segments(path="assets/rowruns/eo_v19_render_runs.mem"):
    recs = [int(l, 16) for l in open(path)]
    assert len(recs) == ROWS * NCAM * SEGS
    def s32(v): return v - (1 << 32) if v & (1 << 31) else v
    def s16(v): return v - (1 << 16) if v & (1 << 15) else v
    ax0 = np.array([s32((r >> 48) & 0xffffffff) for r in recs], np.int64)
    ay0 = np.array([s32((r >> 80) & 0xffffffff) for r in recs], np.int64)
    dax = np.array([s16((r >> 112) & 0xffff) for r in recs], np.int64)
    day = np.array([s16((r >> 128) & 0xffff) for r in recs], np.int64)
    shp = (ROWS, NCAM, SEGS)
    return ax0.reshape(shp), ay0.reshape(shp), dax.reshape(shp), day.reshape(shp)

def cs_q15(centi):
    r = math.radians(centi / 100.0)
    return int(round(math.cos(r) * 32768)), int(round(math.sin(r) * 32768))

def y_shift_rows(pitch_centi):
    q16 = int(round(PITCH_TR * 65536))
    num = q16 * pitch_centi
    den = 100 * 65536
    return (num + den // 2) // den if num >= 0 else -((-num + den // 2) // den)

def pixels(seg, roll_cd, pitch_cd):
    """Return per-pixel (sy, cam, lx, ax, ay) for all strips."""
    ax0, ay0, dax, day = seg
    out = []
    for cam in range(NCAM):
        # C++: rotate by -roll_cam
        c, s = cs_q15(-roll_cd[cam])
        sh = y_shift_rows(pitch_cd[cam]) << 16
        dx = ax0[:, cam, :] - CX
        dy = ay0[:, cam, :] + sh - CY
        Ax = ((c * dx + s * dy) >> 15) + CX
        Ay = ((-s * dx + c * dy) >> 15) + CY
        dax16 = dax[:, cam, :] << 11
        day16 = day[:, cam, :] << 11
        Dx = (c * dax16 + s * day16) >> 15
        Dy = (-s * dax16 + c * day16) >> 15
        lx = np.arange(CAM_W[cam])
        sg = lx // SEG
        i = lx - sg * SEG
        ax = Ax[:, sg] + i[None, :] * Dx[:, sg]
        ay = Ay[:, sg] + i[None, :] * Dy[:, sg]
        out.append((ax, ay))
    return out

def analyse(seg, roll_cd, pitch_cd, label):
    px = pixels(seg, roll_cd, pitch_cd)
    row_ymax = np.full(ROWS, -1, np.int64)
    row_ymin = np.full(ROWS, 1 << 20, np.int64)
    hist = np.zeros(H_SRC, np.int64)
    ncols_lo, ncols_hi, nrow_lo, nrow_hi = 1 << 20, -1, 1 << 20, -1
    invalid = 0; total = 0
    seg_visits = 0
    for cam, (ax, ay) in enumerate(px):
        ok = (ax >= 0) & (ax <= MAX_X) & (ay >= 0) & (ay <= MAX_Y)
        invalid += int((~ok).sum()); total += ok.size
        y0 = np.where(ok, ay >> 16, -1)
        row_ymax = np.maximum(row_ymax, y0.max(1))
        row_ymin = np.minimum(row_ymin, np.where(ok, y0, 1 << 20).min(1))
        hist += np.bincount(y0[ok], minlength=H_SRC)[:H_SRC]
        x0 = ax >> 16
        if ok.any():
            ncols_lo = min(ncols_lo, int(x0[ok].min())); ncols_hi = max(ncols_hi, int(x0[ok].max()) + 1)
            nrow_lo = min(nrow_lo, int(y0[ok].min())); nrow_hi = max(nrow_hi, int(y0[ok].max()) + 1)
        # segment visits: distinct source rows per segment
        for sg in range(SEGS):
            lo = sg * SEG; hi = min(lo + SEG, CAM_W[cam])
            if lo >= hi: continue
            ys = np.where(ok[:, lo:hi], y0[:, lo:hi], -1)
            ymx = ys.max(1); ymn = np.where(ys >= 0, ys, 1 << 20).min(1)
            v = ymx >= 0
            seg_visits += int((ymx[v] - ymn[v] + 1).sum())
    # source-driven emission: row sy done after y0 > row_ymax[sy]; in order.
    emit_after = np.maximum.accumulate(row_ymax)       # y0 after which sy leaves
    first_touch = row_ymin
    width = 0; count = 0
    for y0 in range(H_SRC - 1):
        open_rows = np.nonzero((first_touch <= y0) & (emit_after >= y0))[0]
        if open_rows.size:
            count = max(count, open_rows.size)
            sy_out = int(np.argmax(emit_after >= y0))   # first unemitted row
            width = max(width, int(open_rows.max()) - sy_out + 1)
    print(f"{label:34s} window={width:4d} open={count:4d} seg_visits={seg_visits:7d} "
          f"px/y0 max={int(hist.max()):5d} rows={nrow_lo}..{nrow_hi} cols={ncols_lo}..{ncols_hi} "
          f"invalid={100*invalid/total:5.2f}%")
    return width

if __name__ == "__main__":
    seg = load_segments()
    z = [0] * 6
    cases = [
        ("zero", z, z),
        ("roll +10 all", [1000] * 6, z),
        ("roll -10 all", [-1000] * 6, z),
        ("roll +-10 alternating", [1000, -1000] * 3, z),
        ("pitch +10 all", z, [1000] * 6),
        ("pitch -10 all", z, [-1000] * 6),
        ("pitch +-10 alternating", z, [1000, -1000] * 3),
        ("roll+10 pitch+10 all", [1000] * 6, [1000] * 6),
        ("roll+-10 pitch+-10 alt", [1000, -1000] * 3, [1000, -1000] * 3),
        ("roll+-10 pitch-+10 alt", [1000, -1000] * 3, [-1000, 1000] * 3),
        ("roll 2 pitch +-2 alt", [200] * 6, [200, -200] * 3),
        ("roll +-5 pitch +-5 alt", [500, -500] * 3, [500, -500] * 3),
    ]
    for label, r, p in cases:
        analyse(seg, r, p, label)
