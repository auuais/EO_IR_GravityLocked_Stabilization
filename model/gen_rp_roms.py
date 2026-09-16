#!/usr/bin/env python3
"""Emit the roll/pitch lookup ROMs and the table-builder test vectors.

  assets/rollpitch/{eo,ir}_rp_angle.mem
      1001 lines, index = |angle| in centi-degrees (0..1000), 41 bits:
      {ysh[40:33] signed rows for +|angle| pitch, sin[32:17], cos[16:0]}
      cos/sin are Q15 at scale 32768 (so index 0 is the exact identity).

  sim/vectors/rp_tables_<case>/
      params.mem      31680 x 144-bit PARAMS entries in PARAMS address order
      bucket_end.mem  1079 x 16-bit
      row_ready.mem   480 x 11-bit
      offsets.mem     12 x 16-bit: roll cam0..5 then pitch cam0..5
      meta.mem        ylo, yhi, col_lo, col_hi (16-bit each)
"""
from __future__ import annotations

import sys
from pathlib import Path


def wtext(path, text):
    with open(path, "w", newline="\n") as f:
        f.write(text)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import golden as g  # noqa: E402

ROOT = g.ROOT
IR_PITCH_TR = -8.72

CASES = {
    "zero": ([0] * 6, [0] * 6),
    "mixed": ([150, -300, 1000, -1000, 0, 777], [-1000, 250, 0, 1000, -60, 5]),
    "roll10": ([1000] * 6, [0] * 6),
    "alt10": ([1000, -1000] * 3, [1000, -1000] * 3),
}


def pack_entry(p) -> int:
    def u(v, w): return v & ((1 << w) - 1)
    return ((u(p["sy"], 9) << 135) | (u(p["cam"], 3) << 132) | (u(p["seg"], 4) << 128) |
            (u(p["i"], 6) << 122) | (u(p["dir"], 1) << 121) | (u(p["last"], 6) << 115) |
            (u(p["ax"], 32) << 83) | (u(p["ay"], 32) << 51) |
            (u(p["stx"], 24) << 27) | (u(p["sty"], 24) << 3))


def write_angle_rom(path: Path, tr: float):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="\n") as f:
        for mag in range(g.ANGLE_MAX_CD + 1):
            c, s = g.angle_lut(mag)
            ysh = g.y_shift_rows(mag, tr)
            assert 0 <= c <= 32768 and 0 <= s < 32768 and -128 <= ysh < 128
            f.write(f"{((ysh & 0xFF) << 33) | (s << 17) | c:011x}\n")


def write_vectors(rom, name, roll, pitch):
    tbl = g.build_tables(rom, roll, pitch)
    d = ROOT / "sim" / "vectors" / f"rp_tables_{name}"
    d.mkdir(parents=True, exist_ok=True)
    for p in tbl["params"]:
        assert -(1 << 23) <= p["stx"] < (1 << 23) and -(1 << 23) <= p["sty"] < (1 << 23)
        assert -(1 << 31) <= p["ax"] < (1 << 31) and -(1 << 31) <= p["ay"] < (1 << 31)
    wtext(d / "params.mem", "".join(f"{pack_entry(p):036x}\n" for p in tbl["params"]))
    wtext(d / "bucket_end.mem", "".join(f"{int(v):04x}\n" for v in tbl["bucket_end"]))
    wtext(d / "row_ready.mem", "".join(f"{int(v):03x}\n" for v in tbl["row_ready"]))
    wtext(d / "offsets.mem", "".join(f"{v & 0xFFFF:04x}\n" for v in list(roll) + list(pitch)))
    wtext(d / "meta.mem", "".join(f"{v:04x}\n" for v in (tbl["ylo"], tbl["yhi"], tbl["col_lo"], tbl["col_hi"])))
    print(f"{name}: Y={tbl['ylo']}..{tbl['yhi']} cols={tbl['col_lo']}..{tbl['col_hi']}")


if __name__ == "__main__" and "--ir" not in sys.argv:
    write_angle_rom(ROOT / "assets" / "rollpitch" / "eo_rp_angle.mem", g.EO_PITCH_TR)
    write_angle_rom(ROOT / "assets" / "rollpitch" / "ir_rp_angle.mem", IR_PITCH_TR)
    rom = g.load_rom()
    for name, (r, p) in CASES.items():
        write_vectors(rom, name, r, p)


def write_vectors_ir():
    import rpcore as rc
    rom = rc.load_rom(rc.IR)
    for name, (r, p) in CASES.items():
        tbl = rc.build_tables(rc.IR, rom, r, p)
        d = ROOT / "sim" / "vectors" / f"rp_tables_ir_{name}"
        d.mkdir(parents=True, exist_ok=True)
        wtext(d / "params.mem", "".join(f"{pack_entry(q):036x}\n" for q in tbl["params"]))
        wtext(d / "bucket_end.mem", "".join(f"{int(v):04x}\n" for v in tbl["bucket_end"]))
        wtext(d / "row_ready.mem", "".join(f"{int(v):03x}\n" for v in tbl["row_ready"]))
        wtext(d / "offsets.mem", "".join(f"{v & 0xFFFF:04x}\n" for v in list(r) + list(p)))
        wtext(d / "meta.mem", "".join(f"{v:04x}\n" for v in (tbl["ylo"], tbl["yhi"], tbl["col_lo"], tbl["col_hi"])))
        print(f"ir {name}: Y={tbl['ylo']}..{tbl['yhi']} cols={tbl['col_lo']}..{tbl['col_hi']} n={len(tbl['params'])}")


if __name__ == "__main__" and "--ir" in sys.argv:
    write_vectors_ir()
