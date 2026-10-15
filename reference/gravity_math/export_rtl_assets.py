#!/usr/bin/env python3
"""Export or verify RTL ROMs and raw camera-angle vectors from compiled C++.

Default mode verifies the checked-in assets. --write regenerates them, and is
restricted to MSVC because that compiler is the original numerical target.
No LUT or expected engine output is obtained from the handwritten Python model.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from test_gravity_math import check_provenance, compile_oracle

RANDOM_SEED = 0x6C50524F
RANDOM_COUNT = 1000


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical_source_hash(path):
    return sha(path.read_bytes().replace(b"\r\n", b"\n"))


def engine_inputs():
    """Raw, unclamped signed32 inputs, retained in deterministic group order."""
    vectors = []
    seen = set()
    def add(group, values):
        values = tuple(values)
        if values not in seen:
            seen.add(values)
            vectors.append((group, values))
    headings = (-72000, -36000, -18000, -9000, -1, 0, 1, 3000, 6000,
                9000, 12000, 18000, 24000, 27000, 30000, 36000, 39000, 72000)
    for yaw in headings:
        add("zero_live_heading", (0, 0, yaw, 0, 0))
    live_edges = [(-1001, 0), (-1000, 0), (-999, 0), (999, 0), (1000, 0),
                  (1001, 0), (0, -1001), (0, -1000), (0, -999), (0, 999),
                  (0, 1000), (0, 1001), (-1, 1), (1, -1), (75, -500), (125, 650)]
    for r, p in live_edges:
        for yaw in (0, 6000, 9000, 12000, 18000, 24000, 27000, 30000, 36000, 39000):
            add("ten_degree_sign_and_ring", (r, p, yaw, 0, 0))
    for r in (-18000, -9000, -1, 0, 1, 9000, 18000):
        for p in (-9001, -9000, -8999, 8999, 9000, 9001):
            for yaw, pitch, roll in ((0, 0, 0), (9000, 0, 0), (39000, -125, 75)):
                add("near_singular", (r, p, yaw, pitch, roll))
    for r, p in ((0, 0), (1, -1), (-500, 750), (1000, -1000)):
        for mount in ((0, 2500, 1500), (9000, -150, 75), (18000, 125, -250),
                      (39000, -225, 110), (-33000, 225, -110), (36000, 9000, -9000)):
            add("mixed_static_trims", (r, p, *mount))
    for field in range(5):
        for extreme in (-(1 << 31), (1 << 31) - 1):
            values = [0] * 5
            values[field] = extreme
            add("signed32_normalization", values)
    for values in [(-(1 << 31),) * 5, ((1 << 31) - 1,) * 5,
                   (-(1 << 31), (1 << 31) - 1, 39000, -9000, 9000),
                   ((1 << 31) - 1, -(1 << 31), -39000, 9000, -9000)]:
        add("signed32_normalization", values)
    rng = random.Random(RANDOM_SEED)
    for index in range(RANDOM_COUNT):
        if index % 4 == 0:
            values = [rng.randint(-(1 << 31), (1 << 31) - 1) for _ in range(5)]
            group = "random_signed32"
        else:
            values = [rng.randint(-1500, 1500), rng.randint(-1500, 1500),
                      rng.randint(-72000, 72000), rng.randint(-1000, 1000), rng.randint(-1000, 1000)]
            group = "random_operating_range"
        add(group, values)
    return vectors


def build_assets(executable, provenance, compiler):
    vectors = engine_inputs()
    requests = "LUTS\n" + "".join("ANGLE " + " ".join(map(str, values)) + "\n" for _, values in vectors)
    result = subprocess.run([str(executable)], input=requests, capture_output=True, text=True, timeout=120)
    if result.returncode or result.stderr:
        raise RuntimeError("C++ oracle failed: " + result.stderr)
    rows = result.stdout.splitlines()
    if len(rows) != len(vectors) + 1:
        raise AssertionError("Unexpected C++ oracle response count")
    lut_tokens = rows[0].split()
    if lut_tokens[0] != "LUTS" or len(lut_tokens) != 1 + 72000 + 4097:
        raise AssertionError("Unexpected C++ oracle table dimensions")
    table = list(map(int, lut_tokens[1:]))
    packed = [((table[2 * i] & 0xFFFF) << 16) | (table[2 * i + 1] & 0xFFFF) for i in range(36000)]
    trig_data = "".join("%08x\n" % value for value in packed).encode("ascii")
    atan_data = "".join("%04x\n" % value for value in table[72000:]).encode("ascii")
    vector_rows = []
    vector_records = []
    for index, ((group, values), line) in enumerate(zip(vectors, rows[1:])):
        output = line.split()
        if len(output) != 4 or output[0] != "ANGLE":
            raise AssertionError("Malformed angle response at vector " + str(index))
        expected = tuple(map(int, output[1:]))
        if any(abs(value) > 18000 for value in expected):
            raise AssertionError("Unexpected camera Euler output range")
        vector_rows.append(" ".join(map(str, values + expected)) + "\n")
        vector_records.append({"index": index, "group": group, "input": values, "expected": expected})
    vector_data = "".join(vector_rows).encode("ascii")
    vector_json = (json.dumps({"input_fields": ["sensor_roll_centi", "sensor_pitch_centi", "mount_yaw_centi", "mount_pitch_centi", "mount_roll_centi"],
                              "output_fields": ["camera_roll_centi", "camera_pitch_centi", "camera_yaw_centi"],
                              "vectors": vector_records}, indent=2) + "\n").encode("utf-8")
    paths = {
        "reference/gravity_math/angle_centi_q15.mem": trig_data,
        "reference/gravity_math/atan_ratio_centi.mem": atan_data,
        "sim/gravity_math/engine_vectors.txt": vector_data,
        "sim/gravity_math/engine_vectors.json": vector_json,
    }
    oracle_sources = ["oracle_main.cpp", "oracle.hpp", "export_rtl_assets.py"]
    manifest = {
        "schema": 1,
        "numerical_source": "Compiled source_functions.inc; no Python-generated expected values",
        "source_sha256": provenance["source_sha256"],
        "source_excerpts": {entry["file"]: entry["sha256"] for entry in provenance["excerpts"]},
        "oracle_source_sha256_canonical_lf": {name: canonical_source_hash(ROOT / "reference" / "gravity_math" / name) for name in oracle_sources},
        "generation_compiler": compiler,
        "request_sha256": sha(requests.encode("ascii")),
        "oracle_response_sha256_canonical_lf": sha(("\n".join(rows) + "\n").encode("ascii")),
        "trig_rom": {"file": "reference/gravity_math/angle_centi_q15.mem", "entries": 36000, "word_bits": 32,
                     "address": "angle centidegrees modulo 36000, nonnegative",
                     "bits_31_16": "signed int16 cosine, scaled by 32767",
                     "bits_15_0": "signed int16 sine, scaled by 32767"},
        "atan_rom": {"file": "reference/gravity_math/atan_ratio_centi.mem", "entries": 4097, "word_bits": 16,
                     "address": "rounded ratio index, 0..4096 inclusive",
                     "data": "atan(index / 4096) in integer centidegrees, 0..4500"},
        "engine_vectors": {"file": "sim/gravity_math/engine_vectors.txt", "count": len(vectors),
                           "format": "Eight signed decimal integers per line, no header; raw conversion, no global angle limit",
                           "fields": ["sensor_roll", "sensor_pitch", "mount_yaw", "mount_pitch", "mount_roll", "camera_roll", "camera_pitch", "camera_yaw"],
                           "units": "centidegrees", "random_seed": hex(RANDOM_SEED), "random_count": RANDOM_COUNT,
                           "groups": dict(Counter(group for group, _ in vectors))},
        "assets": {name: {"sha256": sha(data), "size_bytes": len(data)} for name, data in paths.items()},
    }
    paths["reference/gravity_math/rtl_assets_manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    return paths, manifest, result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate checked-in assets using MSVC")
    args = parser.parse_args()
    build = ROOT / "build" / "gravity_math" / "rtl_export"
    build.mkdir(parents=True, exist_ok=True)
    provenance = check_provenance()
    executable, compiler = compile_oracle(build)
    if args.write and compiler["family"] != "MSVC":
        raise RuntimeError("Asset generation requires original-target MSVC; use default mode to verify another compiler")
    assets, manifest, stdout = build_assets(executable, provenance, compiler)
    for name, data in assets.items():
        path = ROOT / name
        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        elif name.endswith("rtl_assets_manifest.json"):
            # A different installed compiler may reproduce the same numerical
            # assets; keep the historical generation compiler in the manifest.
            recorded = json.loads(path.read_text(encoding="utf-8"))
            current = json.loads(data.decode("utf-8"))
            current["generation_compiler"] = recorded["generation_compiler"]
            if current != recorded:
                raise AssertionError("Asset provenance differs: " + name)
        elif not path.is_file() or path.read_bytes() != data:
            raise AssertionError("Checked-in asset differs from compiled oracle: " + name)
    report = {"status": "PASS", "mode": "write" if args.write else "check",
              "vector_count": manifest["engine_vectors"]["count"],
              "trig_entries": 36000, "atan_entries": 4097,
              "oracle_binary_sha256": sha(executable.read_bytes()), "compiler": compiler,
              "assets": manifest["assets"]}
    (build / "run_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (build / "oracle_response.txt").write_text(stdout, encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
