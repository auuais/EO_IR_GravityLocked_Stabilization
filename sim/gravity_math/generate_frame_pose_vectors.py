#!/usr/bin/env python3
"""Generate/check GlFramePose vectors: compiled C when enabled, exact Off bypass.

The selected INI supplies mounting yaw only. Pixel factors, resize, image paths
and captured test attitudes are deliberately excluded from this controller.
Default checks existing files; --write updates only the unique frame-pose files.
"""

import argparse
from collections import Counter
import configparser
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from test_gravity_math import check_provenance, compile_oracle

SEED = 0x4652414D
RANDOM_CASES = 192


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pack(values):
    return sum((value & 0xFFFF) << (index * 16) for index, value in enumerate(values))


def cases():
    output = []
    def add(name, enabled, ir, live, rolls, pitches):
        output.append({"name": name, "enabled": enabled, "sensor_ir": ir,
                       "live_roll": live[0], "live_pitch": live[1],
                       "static_roll": list(rolls), "static_pitch": list(pitches)})
    zeros = [0] * 6
    trims = [([75, -150, 225, -300, 375, -450], [-125, 250, -375, 500, -625, 750]),
             ([1500, -1300, 1750, -2000, 2100, -2250], [2500, 1200, -1500, 1700, -2300, 2600]),
             ([-32768, -1001, -1000, 1, 1001, 32767], [32767, 1001, 1000, -1, -1001, -32768])]
    for ir in (0, 1):
        prefix = "ir" if ir else "eo"
        add(prefix + "_enabled_zero", 1, ir, (0, 0), zeros, zeros)
        add(prefix + "_disabled_zero", 0, ir, (32767, -32768), zeros, zeros)
        for index, (rolls, pitches) in enumerate(trims):
            add(prefix + "_disabled_exact_trim_" + str(index), 0, ir, (1500, -2500), rolls, pitches)
            add(prefix + "_enabled_zero_live_trim_" + str(index), 1, ir, (0, 0), rolls, pitches)
            add(prefix + "_enabled_mixed_trim_" + str(index), 1, ir, (1800, -2000), rolls, pitches)
        for angle in (-1001, -1000, -999, -1, 0, 1, 999, 1000, 1001):
            add(prefix + "_roll_boundary_" + str(angle), 1, ir, (angle, 0), zeros, zeros)
            add(prefix + "_pitch_boundary_" + str(angle), 1, ir, (0, angle), zeros, zeros)
        for index, live in enumerate(((75, -500), (125, 650), (1000, 1000), (-1000, 1000),
                                      (-1000, -1000), (1000, -1000), (-32768, 32767), (32767, -32768))):
            add(prefix + "_mixed_sign_live_" + str(index), 1, ir, live, zeros, zeros)
    rng = random.Random(SEED)
    for index in range(RANDOM_CASES):
        full = index % 4 == 0
        span = 32768 if full else 2501
        live = (rng.randrange(-span, span), rng.randrange(-span, span))
        trim_span = 32768 if full else 1501
        rolls = [rng.randrange(-trim_span, trim_span) for _ in range(6)]
        pitches = [rng.randrange(-trim_span, trim_span) for _ in range(6)]
        add("random_" + str(index), int(index % 7 != 0), index % 2, live, rolls, pitches)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    profile_path = ROOT / "config/parameters_unified.ini"
    profile_bytes = profile_path.read_bytes()
    ini = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";",))
    ini.read_string(profile_bytes.decode("utf-8-sig"))
    yaws = {}
    for ir, sensor in ((0, "eo"), (1, "ir")):
        values = re.findall(r"[-+]?\d+(?:\.\d+)?", ini[sensor + "_offset"]["yaw"])
        yaws[ir] = [int(round(float(value) * 100)) for value in values]
        expected = [index * 6000 + (9000 if ir else 0) for index in range(6)]
        if yaws[ir] != expected:
            raise ValueError("Profile mounting yaw changed; review GlFramePose constants explicitly")
    provenance = check_provenance()
    build = ROOT / "build" / "gravity_math" / "frame_pose_vectors"
    build.mkdir(parents=True, exist_ok=True)
    executable, compiler = compile_oracle(build)
    all_cases = cases()
    enabled_cases = [case for case in all_cases if case["enabled"]]
    requests = []
    for case in enabled_cases:
        # factor=0 and resize=unity are unused placeholders: only angles and the
        # C global-limit outputs are consumed, never camera pixel translation.
        fields = [6, case["live_roll"], case["live_pitch"], 0, 1, 0, 65536, 1000]
        for index in range(6):
            fields += [yaws[case["sensor_ir"]][index], case["static_pitch"][index], case["static_roll"][index]]
        requests.append("FRAME " + " ".join(map(str, fields)))
    request_text = "\n".join(requests) + "\n"
    process = subprocess.run([str(executable)], input=request_text, text=True, capture_output=True, check=True, timeout=120)
    lines = process.stdout.splitlines()
    if len(lines) != len(enabled_cases) or process.stderr:
        raise AssertionError("Unexpected C++ oracle response count/output")
    responses = iter(lines)
    text_rows, records = [], []
    zero_live_quantized_cases = 0
    limited_count = 0
    final_outside_count = 0
    for case in all_cases:
        if case["enabled"]:
            response = next(responses).split()
            if response[0] != "FRAME" or len(response) != 50:
                raise AssertionError("Malformed six-camera FRAME oracle output")
            values = list(map(int, response[1:]))
            applied_roll, applied_pitch = values[0:2]
            pre_max, limited = values[3:5]
            if values[6] != 6:
                raise AssertionError("Wrong oracle camera count")
            rolls = [values[7 + cam * 7] for cam in range(6)]
            pitches = [values[8 + cam * 7] for cam in range(6)]
            if case["live_roll"] == case["live_pitch"] == 0 and (rolls != case["static_roll"] or pitches != case["static_pitch"]):
                zero_live_quantized_cases += 1
        else:
            applied_roll = applied_pitch = pre_max = limited = 0
            rolls, pitches = case["static_roll"], case["static_pitch"]
        outside = int(any(abs(value) > 1000 for value in rolls + pitches))
        limited_count += limited
        final_outside_count += outside
        expected = {"camera_roll": rolls, "camera_pitch": pitches,
                    "applied_roll": applied_roll, "applied_pitch": applied_pitch,
                    "limited": limited, "out_of_range": outside,
                    "c_prelimit_max_for_enabled": pre_max,
                    "source": "compiled C++ FRAME" if case["enabled"] else "explicit exact static bypass"}
        text_rows.append("%d %d %d %d %024x %024x %024x %024x %d %d %d %d\n" %
                         (case["enabled"], case["sensor_ir"], case["live_roll"], case["live_pitch"],
                          pack(case["static_roll"]), pack(case["static_pitch"]), pack(rolls), pack(pitches),
                          applied_roll, applied_pitch, limited, outside))
        records.append({"input": case, "expected": expected})
    if zero_live_quantized_cases == 0 or limited_count == 0 or final_outside_count == 0:
        raise AssertionError("Required controller corner-case coverage is missing")
    vector_data = "".join(text_rows).encode("ascii")
    manifest = {
        "schema": "gl-frame-pose-vectors-v1", "count": len(all_cases),
        "fields": ["enable(decimal)", "sensor_ir(decimal)", "live_roll_centi(decimal)", "live_pitch_centi(decimal)",
                   "static_roll_packed96(hex)", "static_pitch_packed96(hex)", "camera_roll_packed96(hex)", "camera_pitch_packed96(hex)",
                   "applied_roll_centi(decimal)", "applied_pitch_centi(decimal)", "limited(decimal)", "out_of_range(decimal)"],
        "packing": "camera0 in bits15:0; all camera angles signed16 centidegrees",
        "coverage": {"enabled": len(enabled_cases), "disabled_exact_bypass": len(all_cases) - len(enabled_cases),
                     "global_limited": limited_count, "final_out_of_range": final_outside_count,
                     "zero_live_C_differs_from_static": zero_live_quantized_cases,
                     "random_cases": RANDOM_CASES, "random_seed": hex(SEED),
                     "sensor_counts": dict(Counter(case["sensor_ir"] for case in all_cases))},
        "yaw_centi": {"eo": yaws[0], "ir": yaws[1]},
        "profile_sha256": sha(profile_bytes), "profile_fields_used": ["eo_offset.yaw", "ir_offset.yaw"],
        "source_sha256": provenance["source_sha256"], "source_excerpts": provenance["excerpts"],
        "compiler": compiler, "request_sha256": sha(request_text.encode()),
        "oracle_response_sha256_canonical_lf": sha(("\n".join(lines) + "\n").encode()),
        "generator_sha256_canonical_lf": sha(Path(__file__).read_bytes().replace(b"\r\n", b"\n")),
        "vectors_sha256_canonical_lf": sha(vector_data), "cases": records,
    }
    outputs = {"frame_pose_vectors.txt": vector_data,
               "frame_pose_manifest.json": (json.dumps(manifest, indent=2) + "\n").encode()}
    for name, content in outputs.items():
        path = ROOT / "sim/gravity_math" / name
        if args.write:
            if compiler["family"] != "MSVC":
                raise RuntimeError("Generating new goldens requires original-target MSVC")
            path.write_bytes(content)
        else:
            if path.read_bytes().replace(b"\r\n", b"\n") != content:
                raise AssertionError("Frame pose vectors/provenance changed: " + name)
    print("PASS frame-pose golden %s: %d cases, %d enabled C, %d exact disabled bypass, %d limited, %d outside after final result, %d zero-live trim quantization cases" %
          ("generation" if args.write else "check", len(all_cases), len(enabled_cases), len(all_cases) - len(enabled_cases),
           limited_count, final_outside_count, zero_live_quantized_cases))


if __name__ == "__main__":
    main()
