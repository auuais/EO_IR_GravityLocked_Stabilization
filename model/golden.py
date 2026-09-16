#!/usr/bin/env python3
"""Golden model for the source-driven EO panorama renderer with live offsets.

Three independent pieces, deliberately not sharing the per-pixel math:

  render_m1()        the M1 output-driven renderer's math, transcribed from
                     EoV19StreamingRendererII1.v (affine_q16/qx_phase/qy/qf).
  render_offsets()   the new renderer's functional result: transform each
                     segment, sample per pixel, black invalid pixels, blend
                     seams at emission.
  build_tables() +   the table builder and the walker/queue/emission
  simulate_walk()    semantics the RTL implements; checks every pixel is taken
                     exactly once, at the source row it samples, before its
                     row is emitted, and reports the RowWindow window.

Usage:
  python model/golden.py --selftest
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
RR = ROOT / "assets" / "rowruns"

SRC_W, SRC_H = 1920, 1080
CX, CY = SRC_W << 15, SRC_H << 15
MAX_X, MAX_Y = (SRC_W - 2) << 16, (SRC_H - 2) << 16
ROWS, NCAM, SEGS, SEG = 480, 6, 11, 64
PANO_W = 3840
CAM_W = [650, 655, 655, 655, 655, 655]
CAM_START = [0, 633, 1271, 1909, 2547, 3185]
CAM_END = [649, 1287, 1925, 2563, 3201, 3839]
STRIP_BASE = [0, 650, 1305, 1960, 2615, 3270]   # cumulative CAM_W
STRIP_TOTAL = 3925
BLACK = 0x1080
DRUN_TO_Q16 = 11
EO_PITCH_TR = -9.80
ANGLE_MAX_CD = 1000


# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
def load_rom(path: Path = RR / "eo_v19_render_runs.mem"):
    def s32(v): return v - (1 << 32) if v & (1 << 31) else v
    def s16(v): return v - (1 << 16) if v & (1 << 15) else v
    recs = [int(l, 16) for l in path.read_text().split()]
    assert len(recs) == ROWS * NCAM * SEGS, len(recs)
    f = lambda sh, w, sg: np.array([sg((r >> sh) & ((1 << w) - 1)) for r in recs], np.int64).reshape(ROWS, NCAM, SEGS)
    return {"ox0": f(16, 16, lambda v: v), "ax0": f(48, 32, s32), "ay0": f(80, 32, s32),
            "dax": f(112, 16, s16), "day": f(128, 16, s16)}


def load_alpha():
    ay = [int(l, 16) for l in (RR / "eo_v19_alpha_y.mem").read_text().split()]
    ac = [int(l, 16) for l in (RR / "eo_v19_alpha_c.mem").read_text().split()]
    return ay, ac


def synthetic_frames(seed: int = 1) -> np.ndarray:
    """Six textured 1920x1080 frames of 16-bit {Y,C}. Texture is designed so a
    one-pixel error in x, y, row selection or camera shows up."""
    y, x = np.mgrid[0:SRC_H, 0:SRC_W].astype(np.int64)
    out = np.empty((NCAM, SRC_H, SRC_W), np.int64)
    for cam in range(NCAM):
        luma = (x * 7 + y * 13 + cam * 41 + ((x * y) >> 6) + (x >> 3) * (y >> 4) * (seed + cam)) & 0xFF
        chroma = (x * 3 + y * 5 + cam * 17 + ((x ^ (y << 1)) >> 2)) & 0xFF
        out[cam] = (luma << 8) | chroma
    return out


# --------------------------------------------------------------------------
# Offset math shared with the RTL ROM generator
# --------------------------------------------------------------------------
def round_half_away(num: int, den: int) -> int:
    return (num + den // 2) // den if num >= 0 else -((-num + den // 2) // den)


def clamp_cd(v: int) -> int:
    return max(-ANGLE_MAX_CD, min(ANGLE_MAX_CD, v))


def angle_lut(mag_cd: int):
    """(cos, sin, y_shift) for |angle| in centi-degrees; sin/y_shift for +mag."""
    r = math.radians(mag_cd / 100.0)
    c = int(math.floor(math.cos(r) * 32768 + 0.5))
    s = int(math.floor(math.sin(r) * 32768 + 0.5))
    return c, s


def y_shift_rows(pitch_cd: int, tr: float = EO_PITCH_TR) -> int:
    tr_q16 = int(math.floor(tr * 65536 + 0.5)) if tr >= 0 else -int(math.floor(-tr * 65536 + 0.5))
    return round_half_away(tr_q16 * pitch_cd, 100 * 65536)


def cam_transform(roll_cd: int, pitch_cd: int):
    roll_cd, pitch_cd = clamp_cd(roll_cd), clamp_cd(pitch_cd)
    c, s_mag = angle_lut(abs(roll_cd))
    # C++ rotates by -roll: sin(-roll) = -sign(roll) * sin(|roll|)
    s = -s_mag if roll_cd > 0 else s_mag if roll_cd < 0 else 0
    return c, s, y_shift_rows(pitch_cd)


def seg_transform(rom, cam, c, s, ysh):
    dx = rom["ax0"][:, cam, :] - CX
    dy = rom["ay0"][:, cam, :] + (ysh << 16) - CY
    Ax = ((c * dx + s * dy) >> 15) + CX
    Ay = ((-s * dx + c * dy) >> 15) + CY
    dax = rom["dax"][:, cam, :] << DRUN_TO_Q16
    day = rom["day"][:, cam, :] << DRUN_TO_Q16
    Dx = (c * dax + s * day) >> 15
    Dy = (-s * dax + c * day) >> 15
    return Ax, Ay, Dx, Dy


# --------------------------------------------------------------------------
# Per-pixel sampling (RTL functions)
# --------------------------------------------------------------------------
def qx_phase(ax: np.ndarray, parity: np.ndarray) -> np.ndarray:
    q = np.where(ax < 0, 0, np.where(ax > (1918 << 16), 1918, (ax >> 16) & 0x7FF))
    mid = (q & ~1) | parity
    return np.where(q == 0, parity, np.where(q >= 1918, np.where(parity == 1, 1919, 1918), mid))


def interp8(a, b, f):
    return ((a * (65536 - f) + b * f + 32768) >> 16) & 0xFF


def sample(frame, ax, ay, parity, valid):
    x = qx_phase(ax, parity)
    y0 = np.clip(ay >> 16, 0, 1078)
    fr = np.where(valid, ay & 0xFFFF, 0)
    p0 = frame[y0, x]
    p1 = frame[y0 + 1, x]
    Y = interp8(p0 >> 8, p1 >> 8, fr)
    C = interp8(p0 & 0xFF, p1 & 0xFF, fr)
    return np.where(valid, (Y << 8) | C, BLACK)


def strips_offsets(rom, frames, roll, pitch):
    """RowWindow content: per camera strip [ROWS, CAM_W]."""
    strips = []
    for cam in range(NCAM):
        c, s, ysh = cam_transform(roll[cam], pitch[cam])
        Ax, Ay, Dx, Dy = seg_transform(rom, cam, c, s, ysh)
        lx = np.arange(CAM_W[cam])
        sg, i = lx // SEG, lx % SEG
        ax = Ax[:, sg] + i * Dx[:, sg]
        ay = Ay[:, sg] + i * Dy[:, sg]
        valid = (ax >= 0) & (ax <= MAX_X) & (ay >= 0) & (ay <= MAX_Y)
        parity = (CAM_START[cam] + lx) & 1
        strips.append(sample(frames[cam], ax, ay, np.broadcast_to(parity, ax.shape), valid))
    return strips


def blend8(a, b, f):
    return ((a * (65536 - f) + b * f + 32768) >> 16) & 0xFF


def compose(strips, cam_present=(1,) * 6):
    ay_tab, ac_tab = load_alpha()
    out = np.full((ROWS, PANO_W), BLACK, np.int64)
    # M1 map: pano_x < CAM1_START -> cam0; <= CAM0_END -> blend(cam0, cam1); ...
    # camera A is the lower-numbered camera throughout an overlap.
    for k in range(NCAM):
        lo = CAM_START[k] if k == 0 else CAM_END[k - 1] + 1
        hi = (CAM_START[k + 1] - 1) if k < NCAM - 1 else CAM_END[k]
        xs = np.arange(lo, hi + 1)
        v = strips[k][:, xs - CAM_START[k]]
        out[:, lo:hi + 1] = v if cam_present[k] else BLACK
        if k < NCAM - 1:
            xs = np.arange(CAM_START[k + 1], CAM_END[k] + 1)
            apos = xs - CAM_START[k + 1]
            a = strips[k][:, xs - CAM_START[k]]
            b = strips[k + 1][:, apos]
            fy = np.array([ay_tab[p] for p in apos])
            fc = np.array([ac_tab[7 if p > 15 else p >> 1] for p in apos])
            bl = (blend8(a >> 8, b >> 8, fy) << 8) | blend8(a & 0xFF, b & 0xFF, fc)
            if not cam_present[k]:
                seg = np.full_like(a, BLACK)
            elif cam_present[k + 1]:
                seg = bl
            else:
                seg = a
            out[:, CAM_START[k + 1]:CAM_END[k] + 1] = seg
    return out


def render_offsets(rom, frames, roll, pitch, cam_present=(1,) * 6):
    return compose(strips_offsets(rom, frames, roll, pitch), cam_present)


# --------------------------------------------------------------------------
# M1 renderer, transcribed independently from EoV19StreamingRendererII1.v
# --------------------------------------------------------------------------
def render_m1(rom, frames):
    ay_tab, ac_tab = load_alpha()
    out = np.empty((ROWS, PANO_W), np.int64)
    px = np.arange(PANO_W)
    cam_a = np.zeros(PANO_W, int); cam_b = np.zeros(PANO_W, int)
    lx_a = px.copy(); lx_b = np.zeros(PANO_W, int); blend = np.zeros(PANO_W, bool); apos = np.zeros(PANO_W, int)
    for k in range(NCAM):
        solo = (px >= (CAM_START[k] if k == 0 else CAM_END[k - 1] + 1)) & (px < (CAM_START[k + 1] if k < 5 else PANO_W))
        cam_a[solo] = k; lx_a[solo] = px[solo] - CAM_START[k]
        if k < 5:
            ov = (px >= CAM_START[k + 1]) & (px <= CAM_END[k])
            cam_a[ov] = k; cam_b[ov] = k + 1; blend[ov] = True
            lx_a[ov] = px[ov] - CAM_START[k]; lx_b[ov] = px[ov] - CAM_START[k + 1]; apos[ov] = px[ov] - CAM_START[k + 1]
    par = px & 1

    def cam_sample(sy, cams, lxs):
        seg = lxs // SEG
        rec = lambda f: rom[f][sy, cams, seg]
        off = lxs - rec("ox0")
        cx = rec("ax0") + ((off * rec("dax")) << DRUN_TO_Q16)
        cy = rec("ay0") + ((off * rec("day")) << DRUN_TO_Q16)
        qy = np.where(cy < 0, 0, np.where(cy > (1078 << 16), 1078, (cy >> 16) & 0x7FF))
        qf = np.where((cy < 0) | (cy > (1078 << 16)), 0, cy & 0xFFFF)
        x = qx_phase(cx, par)
        f = frames[cams, qy, x]; g = frames[cams, qy + 1, x]
        return interp8(f >> 8, g >> 8, qf), interp8(f & 0xFF, g & 0xFF, qf)

    fy = np.array([ay_tab[p] if b else 0 for p, b in zip(apos, blend)])
    fc = np.array([ac_tab[7 if p > 15 else p >> 1] if b else 0 for p, b in zip(apos, blend)])
    for sy in range(ROWS):
        ya, ca = cam_sample(sy, cam_a, lx_a)
        yb, cb = cam_sample(sy, cam_b, lx_b)
        bl = (blend8(ya, yb, fy) << 8) | blend8(ca, cb, fc)
        out[sy] = np.where(blend, bl, (ya << 8) | ca)
    return out


# --------------------------------------------------------------------------
# Tables + walker/queue/emission semantics
# --------------------------------------------------------------------------
def seg_len(cam: int, seg: int) -> int:
    return min(SEG, CAM_W[cam] - seg * SEG)


def build_tables(rom, roll, pitch):
    """Mirror of the RTL table builder. Returns dict with PARAMS (list of
    tuples in PARAMS address order), BUCKET_END[1079], ROW_READY[480], Ylo, Yhi,
    and the source column/row envelope."""
    ents = []            # per camera (Ax, Ay, Dx, Dy) arrays [ROWS, SEGS]
    xs_lo, xs_hi = 1 << 30, -1
    for cam in range(NCAM):
        c, s, ysh = cam_transform(roll[cam], pitch[cam])
        ents.append(seg_transform(rom, cam, c, s, ysh))
    ylo, yhi = 1 << 30, -1
    # PARAMS scan order is ROM address order: sy -> cam -> seg.
    params = []
    for sy in range(ROWS):
        for cam in range(NCAM):
            Ax, Ay, Dx, Dy = ents[cam]
            for sg in range(SEGS):
                ln = seg_len(cam, sg)
                if ln <= 0:
                    continue
                ax0, ay0, dx, dy = int(Ax[sy, sg]), int(Ay[sy, sg]), int(Dx[sy, sg]), int(Dy[sy, sg])
                last = ln - 1
                d = dy >= 0
                i0 = 0 if d else last
                ax_s, ay_s = ax0 + i0 * dx, ay0 + i0 * dy
                ay_e = ay0 + (last - i0) * dy if d else ay0
                sx, sy_step = (dx, dy) if d else (-dx, -dy)
                st = min(1078, max(0, ay_s >> 16))
                en = min(1078, max(0, ay_e >> 16))
                # envelope from the two endpoints (x and y)
                ax_e = ax0 + last * dx
                for axv in (ax0, ax_e):
                    xc = min(1918, max(0, axv >> 16))
                    xs_lo, xs_hi = min(xs_lo, xc), max(xs_hi, xc + 1)
                ylo, yhi = min(ylo, st), max(yhi, en)
                params.append(dict(sy=sy, cam=cam, seg=sg, i=i0, dir=int(d), last=last,
                                   ax=ax_s, ay=ay_s, stx=sx, sty=sy_step, st=st, en=en))
    # clamp start/end into [Ylo, Yhi]
    for p in params:
        p["st"] = min(yhi, max(ylo, p["st"]))
        p["en"] = min(yhi, max(ylo, p["en"]))
    row_ready = [ylo] * ROWS
    for p in params:
        row_ready[p["sy"]] = max(row_ready[p["sy"]], p["en"])
    # counting sort by st, stable in ROM scan order
    order = sorted(range(len(params)), key=lambda k: (params[k]["st"], k))
    sorted_params = [params[k] for k in order]
    counts = np.bincount([p["st"] for p in params], minlength=SRC_H - 1)
    bucket_end = np.cumsum(counts)
    return dict(params=sorted_params, bucket_end=bucket_end, row_ready=row_ready,
                ylo=ylo, yhi=yhi, col_lo=xs_lo, col_hi=xs_hi)


def simulate_walk(tbl, slots: int = 256):
    """Walker/queue/emission at the granularity of whole y0 steps.
    Returns (ok, stats). Checks exactly-once, correct source row for valid
    pixels, written-before-emitted, and the RowWindow window."""
    ylo, yhi = tbl["ylo"], tbl["yhi"]
    params = tbl["params"]; bend = tbl["bucket_end"]; rr = tbl["row_ready"]
    taken = np.zeros((ROWS, STRIP_TOTAL), np.int32)
    take_y = np.full((ROWS, STRIP_TOTAL), -1, np.int32)
    queue = []
    p_next = 0
    sy_out = 0
    max_window = 0
    visits = 0
    errors = []
    for y0 in range(ylo, yhi + 1):
        last = y0 == yhi
        work = queue
        queue = []
        while p_next < bend[y0]:
            work.append(dict(params[p_next])); p_next += 1
        for e in work:
            visits += 1
            ln_last = e["last"]
            while True:
                ay = e["ay"]
                take = last or ay < 0 or (ay >> 16) <= y0
                if not take:
                    queue.append(e)
                    break
                sy, cam = e["sy"], e["cam"]
                lx = e["seg"] * SEG + e["i"]
                sx = STRIP_BASE[cam] + lx
                taken[sy, sx] += 1
                take_y[sy, sx] = y0
                valid = (e["ax"] >= 0) and (e["ax"] <= MAX_X) and (0 <= ay <= MAX_Y)
                if valid and (ay >> 16) != y0:
                    errors.append(("wrong_row", sy, cam, lx, ay >> 16, y0))
                max_window = max(max_window, sy - sy_out + 1)
                exhausted = (e["i"] == ln_last) if e["dir"] else (e["i"] == 0)
                if exhausted:
                    break
                e["i"] += 1 if e["dir"] else -1
                e["ax"] += e["stx"]; e["ay"] += e["sty"]
        # y0 committed: emit ready rows
        while sy_out < ROWS and (rr[sy_out] <= y0):
            if (taken[sy_out] != 1).any():
                errors.append(("row_incomplete_at_emit", sy_out, y0))
            sy_out += 1
    if sy_out != ROWS:
        errors.append(("rows_left", sy_out))
    if (taken != 1).any():
        bad = np.argwhere(taken != 1)
        errors.append(("not_exactly_once", len(bad), bad[:5].tolist()))
    return (not errors), dict(visits=visits, max_window=max_window, errors=errors[:10],
                              p_consumed=p_next, n_params=len(params))


# --------------------------------------------------------------------------
def selftest():
    rom = load_rom()
    frames = synthetic_frames()
    z = [0] * 6
    print("M1 vs offsets-renderer at zero offset ...", flush=True)
    m1 = render_m1(rom, frames)
    new = render_offsets(rom, frames, z, z)
    diff = int((m1 != new).sum())
    print(f"  mismatching pixels: {diff}")
    ok = diff == 0
    for label, r, p in [("zero", z, z), ("roll+10", [1000] * 6, z), ("mixed", [150, -300, 1000, -1000, 0, 777], [-1000, 250, 0, 1000, -60, 5]),
                        ("roll+-10 pitch+-10 alt", [1000, -1000] * 3, [1000, -1000] * 3)]:
        tbl = build_tables(rom, r, p)
        good, st = simulate_walk(tbl)
        print(f"  walk {label:24s} ok={good} Y={tbl['ylo']}..{tbl['yhi']} cols={tbl['col_lo']}..{tbl['col_hi']} {st}")
        ok &= good
    return ok


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(0 if selftest() else 1)
