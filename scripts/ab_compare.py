#!/usr/bin/env python3
"""Compare 60-frame average stills from two builds, against a control.

    python scripts/ab_compare.py --a <dirA> --b <dirB> --control <dirB2> --out <dir>

A vs B is the build difference; B vs control is the SAME build grabbed again a
few minutes later, i.e. sensor noise + auto-exposure + scene drift + grabber.
A rendering difference only exists where A vs B clearly exceeds the control.

Pixels that moved during either grab (temporal std above --motion-std in any
of the grabs compared) are masked out, so a person shifting in a chair does
not read as a rendering fault.

Reported per mode:
  * masked mean |diff| and PSNR over the content area, and SSIM (luma)
  * the same restricted to seam bands and to the top/bottom 8 content rows
  * rows whose maximum is black (the letterbox; edge-row defects show here)
  * columns/rows with the largest excess difference, to localise any fault
and a x8 amplified difference image per pair.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from skimage.metrics import structural_similarity

MODES = ("eo_panorama", "ir_panorama")
# Folded 1920x960 raster: seams of the 3840-wide logical panorama.
SEAMS = {
    "eo_panorama": [633, 1271, 1909, 2547, 3185],
    "ir_panorama": [587, 1179, 1771, 2363, 2955],
}


def load(d, mode):
    m = np.load(Path(d) / f"{mode}_mean.npy").astype(np.float64)
    s = np.load(Path(d) / f"{mode}_std.npy").astype(np.float64)
    return m, s


def seam_mask(mode, h=1080, w=1920, half=24):
    mask = np.zeros((h, w), bool)
    for px in SEAMS[mode]:
        row0 = 0 if px < 1920 else 480
        x = px if px < 1920 else px - 1920
        mask[row0:row0 + 480, max(0, x - half):min(w, x + half + 48)] = True
    return mask


def stats(a, b, mask):
    d = np.abs(a - b).mean(axis=2)
    if mask.sum() == 0:
        return {"mad": None, "psnr": None}
    mse = ((a - b) ** 2).mean(axis=2)[mask].mean()
    return {"mad": float(d[mask].mean()), "p99": float(np.percentile(d[mask], 99)),
            "psnr": float(10 * np.log10(255 ** 2 / max(mse, 1e-9)))}


def compare(a_dir, b_dir, mode, motion_std, out, tag):
    a, sa = load(a_dir, mode)
    b, sb = load(b_dir, mode)
    still = (sa.max(axis=2) < motion_std) & (sb.max(axis=2) < motion_std)
    content = np.zeros(still.shape, bool)
    content[:960, :] = True
    lit = (a.max(axis=2) > 24) | (b.max(axis=2) > 24)
    m_all = still & content & lit
    ya = cv2.cvtColor(np.clip(a, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY)
    yb = cv2.cvtColor(np.clip(b, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY)
    _, ssim_map = structural_similarity(ya[:960], yb[:960], full=True, data_range=255)
    edge = np.zeros(still.shape, bool)
    edge[0:8, :] = edge[472:488, :] = edge[952:960, :] = True
    r = {
        "moving_fraction": float(1 - (still & content).sum() / content.sum()),
        "all": stats(a, b, m_all),
        "seams": stats(a, b, m_all & seam_mask(mode)),
        "edge_rows": stats(a, b, m_all & edge),
        "ssim_still": float(ssim_map[m_all[:960]].mean()),
    }
    d = np.abs(a - b).mean(axis=2) * still
    r["worst_rows"] = [int(i) for i in np.argsort(d[:960].mean(axis=1))[-5:][::-1]]
    r["worst_cols"] = [int(i) for i in np.argsort(d[:960].mean(axis=0))[-5:][::-1]]
    amp = np.clip(np.abs(a - b) * 8, 0, 255).astype(np.uint8)
    cv2.imwrite(str(Path(out) / f"diff_{tag}_{mode}.png"), amp)
    return r


def black_rows(d, mode):
    a, _ = load(d, mode)
    rmax = a.max(axis=(1, 2))
    rows = np.nonzero(rmax <= 24)[0]
    return {"count": int(rows.size), "first": [int(x) for x in rows[:6]],
            "content_black": [int(x) for x in rows if x < 960]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--control", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--motion-std", type=float, default=4.0)
    x = ap.parse_args()
    Path(x.out).mkdir(parents=True, exist_ok=True)
    report = {}
    for mode in MODES:
        report[mode] = {
            "A_vs_B": compare(x.a, x.b, mode, x.motion_std, x.out, "AB"),
            "B_vs_control": compare(x.b, x.control, mode, x.motion_std, x.out, "BB"),
            "black_rows": {"A": black_rows(x.a, mode), "B": black_rows(x.b, mode),
                           "control": black_rows(x.control, mode)},
        }
    (Path(x.out) / "report.json").write_text(json.dumps(report, indent=2))
    for mode, r in report.items():
        print(f"== {mode}")
        for k in ("A_vs_B", "B_vs_control"):
            v = r[k]
            print(f"  {k:13s} moving {v['moving_fraction']*100:4.1f}%  "
                  f"all MAD {v['all']['mad']:.2f} p99 {v['all']['p99']:.1f} PSNR {v['all']['psnr']:.1f} dB  "
                  f"SSIM {v['ssim_still']:.4f} | seams MAD {v['seams']['mad']:.2f} | "
                  f"edge rows MAD {v['edge_rows']['mad']:.2f}  worst rows {v['worst_rows']} cols {v['worst_cols']}")
        br = r["black_rows"]
        print(f"  black rows  A {br['A']['count']} (content {br['A']['content_black']})  "
              f"B {br['B']['count']} (content {br['B']['content_black']})  "
              f"control {br['control']['count']}")


if __name__ == "__main__":
    main()
