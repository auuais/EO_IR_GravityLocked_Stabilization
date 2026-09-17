#!/usr/bin/env python3
"""Grab N frames from the SDI grabber and save their per-pixel mean and
standard deviation, for build-to-build image comparison.

A single still carries ~1-2 LSB of sensor noise per pixel, which swamps the
differences an A/B comparison is looking for.  Averaging 60 frames cuts that
by ~8x; the per-pixel std is saved too, so moving content (people, leaves)
can be masked out instead of being mistaken for a rendering difference.

    python scripts/grab_average.py --device 0 --frames 60 --out captures/x/eo_pano
      -> eo_pano_mean.npy, eo_pano_std.npy, eo_pano_mean.png, eo_pano_single.png
"""
import argparse
import sys

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--out", required=True, help="output path prefix")
    a = ap.parse_args()

    cap = cv2.VideoCapture(a.device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"could not open capture device {a.device}")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    for _ in range(20):
        cap.read()

    acc = None
    acc2 = None
    first = None
    n = 0
    while n < a.frames:
        ok, f = cap.read()
        if not ok or f is None:
            continue
        x = f.astype(np.float64)
        if acc is None:
            acc = np.zeros_like(x)
            acc2 = np.zeros_like(x)
            first = f
        acc += x
        acc2 += x * x
        n += 1
    cap.release()

    mean = acc / n
    std = np.sqrt(np.maximum(acc2 / n - mean * mean, 0.0))
    np.save(a.out + "_mean.npy", mean.astype(np.float32))
    np.save(a.out + "_std.npy", std.astype(np.float32))
    cv2.imwrite(a.out + "_mean.png", np.clip(mean + 0.5, 0, 255).astype(np.uint8))
    cv2.imwrite(a.out + "_single.png", first)
    print(f"  {n} frames -> {a.out}_mean.npy  mean {mean.mean():.2f}  "
          f"median temporal std {np.median(std):.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
