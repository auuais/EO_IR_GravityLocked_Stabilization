#!/usr/bin/env python3
"""Build exact C++ excerpts and compare the Python reference, without hardware.

Outputs go only to build/gravity_math/. The source excerpt hashes are checked
before compilation. A production INI is optional and used only as an explicit
fixture; its stored orientations never become default live poses.
"""

import argparse
import configparser
from dataclasses import astuple
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
import gravity_reference as ref


def check_provenance():
    folder = ROOT / "reference" / "gravity_math"
    manifest = json.loads((folder / "provenance.json").read_text(encoding="utf-8"))
    for item in manifest["excerpts"]:
        actual = hashlib.sha256((folder / item["file"]).read_bytes()).hexdigest()
        if actual != item["sha256"]:
            raise AssertionError("Extracted C++ source changed: " + item["file"])
    return manifest


def compile_oracle(build):
    source = ROOT / "reference" / "gravity_math" / "oracle_main.cpp"
    if os.name == "nt":
        installation = None
        vswhere = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        if vswhere.exists():
            result = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires",
                                     "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
                                    check=True, capture_output=True, text=True)
            if result.stdout.strip():
                installation = Path(result.stdout.strip())
        if installation is None:
            raise RuntimeError("MSVC C++ tools not found; no compiler installation was attempted")
        vcvars = installation / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
        executable = build / "gravity_oracle.exe"
        batch = build / "compile_oracle.cmd"
        command = ('@echo off\ncall "' + str(vcvars) + '" >nul\n'
                   'if errorlevel 1 exit /b %errorlevel%\n'
                   'cl /nologo /std:c++17 /EHsc /W4 /O2 /fp:precise /Fe:"' + str(executable) +
                   '" /Fo:"' + str(build / "gravity_oracle.obj") + '" "' + str(source) + '"\n'
                   'exit /b %errorlevel%\n')
        batch.write_text(command, encoding="utf-8")
        result = subprocess.run([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(batch)],
                                cwd=build, capture_output=True, text=True)
        compiler = {"family": "MSVC", "installation": str(installation), "flags": "/std:c++17 /EHsc /W4 /O2 /fp:precise"}
    else:
        compiler_path = shutil.which("c++") or shutil.which("g++") or shutil.which("clang++")
        if not compiler_path:
            raise RuntimeError("No C++ compiler found; no installation was attempted")
        executable = build / "gravity_oracle"
        result = subprocess.run([compiler_path, "-std=c++17", "-O2", "-Wall", "-Wextra", str(source), "-o", str(executable)],
                                cwd=build, capture_output=True, text=True)
        compiler = {"family": "system C++", "path": compiler_path, "flags": "-std=c++17 -O2 -Wall -Wextra"}
    (build / "compiler.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Oracle build failed:\n" + result.stdout + result.stderr)
    return executable, compiler


def ini_cases(path):
    ini = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";",))
    ini.read(str(path), encoding="utf-8-sig")
    cases = []
    for sensor in ("eo", "ir"):
        if sensor + "_camera" not in ini:
            continue
        camera = ini[sensor + "_camera"]
        offsets = ini[sensor + "_offset"]
        orientation = ini[sensor + "_orientation"] if sensor + "_orientation" in ini else ini["Sensor_Orientation"]
        def angle(section, key):
            if key in section:
                return ref.degrees_to_centi(float(section[key]))
            return int(section[key + "_centi"] if key + "_centi" in section else section.get(key + "_cdeg", "0"))
        def angle_array(key):
            if key in offsets:
                return [ref.degrees_to_centi(float(v)) for v in re.findall(r"[-+]?\d+(?:\.\d+)?", offsets[key])]
            return [int(v) for v in re.findall(r"[-+]?\d+", offsets.get(key + "_centi", offsets.get(key + "_cdeg", "")))]
        yaw, pitch, roll = (angle_array(key) for key in ("yaw", "pitch", "roll"))
        count = int(camera["num_cams"])
        if not len(yaw) == len(pitch) == len(roll) == count:
            raise AssertionError("Explicit production mount arrays must contain num_cams values")
        mounts = [list(values) for values in zip(yaw, pitch, roll)]
        for enabled in (True, False):
            cases.append({"name": "production_" + sensor + ("_enabled" if enabled else "_disabled"),
                          "live": [angle(orientation, key) for key in ("roll", "pitch", "yaw")],
                          "mounts": mounts, "enabled": enabled,
                          "factor": ref.float_to_q16(float(camera["pitch_to_translation_factor"])),
                          "resize": ref.float_to_q16(float(camera["resize_factor"]))})
    return cases


def run_suite(executable, build, random_cases, ini_path):
    rng = random.Random(0xC0DE6015)
    requests, expected, labels = [], [], []
    counts = {}
    def add(op, args, values, label):
        requests.append(op + (" " + " ".join(str(v) for v in args) if args else ""))
        expected.append([op] + [str(int(value)) for value in values])
        labels.append(label)
        counts[op] = counts.get(op, 0) + 1

    trig, atan = ref.angle_tables()
    add("LUTS", [], [value for entry in trig for value in entry] + list(atan), "full trig and atan tables")
    for value in range(-32768, 32769):
        add("ASIN", [value], [ref.asin_centi_q15(value)], "asin " + str(value))
    for value in [-(1 << 31), -1000000, 1000000, (1 << 31) - 1]:
        add("ASIN", [value], [ref.asin_centi_q15(value)], "asin saturation " + str(value))
    q15_edges = [-32768, -32767, -16384, -8, -1, 0, 1, 8, 16384, 32767]
    pairs = [(y, x) for y in q15_edges for x in q15_edges]
    pairs += [(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(1000)]
    for y, x in pairs:
        add("ATAN", [y, x], [ref.atan2_centi_q15(y, x)], "atan quadrant/ratio")
    roots = [0, 1, 2, 3, 4, (1 << 30) - 1, 1 << 30, (1 << 64) - 1]
    roots += [rng.randrange(1 << 64) for _ in range(1000)]
    for value in roots:
        add("SQRT", [value], [ref.isqrt_u64(value)], "unsigned integer sqrt")
    for num in [-1001, -65536, -32769, -32768, -101, -100, -99, -3, -2, -1, 0, 1, 2, 3, 99, 100, 101, 32768, 32769, 65536, 1001]:
        for den in [-65536, -100, -3, -2, -1, 0, 1, 2, 3, 100, 65536]:
            add("DIV", [num, den], [ref.div_round_i64(num, den)], "C signed rounded division")
    for value in [-179.995, -10.005, -9.80, -8.72, -1.005, -0.005, 0, 0.005, 0.56296, 1.005, 10.005, 359.995]:
        add("FLOAT", [value], [ref.degrees_to_centi(value), ref.float_to_q16(value)], "float32 input quantization")

    cases = json.loads((ROOT / "sim" / "gravity_math" / "cases.json").read_text(encoding="utf-8"))["cases"]
    for angle in [-1001, -1000, -999, -1, 0, 1, 999, 1000, 1001]:
        for axis in (0, 1):
            live = [0, 0, 0]
            live[axis] = angle
            cases.append({"name": "limit_boundary_" + str(axis) + "_" + str(angle), "live": live,
                          "mounts": [[yaw, 0, 0] for yaw in (0, 6000, 12000, 18000, 24000, 30000)],
                          "enabled": True, "factor": -655360, "resize": 65536})
    production_cases = ini_cases(ini_path) if ini_path else []
    cases.extend(production_cases)
    for index in range(random_cases):
        count = rng.randint(1, 6)
        mounts = [[rng.randint(-72000, 72000), rng.randint(-2500, 2500), rng.randint(-2500, 2500)] for _ in range(count)]
        cases.append({"name": "random_" + str(index), "live": [rng.randint(-18000, 18000), rng.randint(-18000, 18000), rng.randint(-72000, 72000)],
                      "mounts": mounts, "enabled": bool(rng.randrange(8)),
                      "factor": rng.choice([-642253, -571474, -655360, 655360, 0]),
                      "resize": rng.choice([32768, 36894, 65536, 0])})
    case_results = []
    for case in cases:
        r, p, y = case["live"]
        mounts = [ref.CameraMount(*mount) for mount in case["mounts"]]
        frame = ref.compute_frame(r, p, mounts, yaw_centi=y, enabled=case["enabled"],
                                  pitch_factor_q16=case["factor"], resize_factor_q16=case["resize"])
        args = [len(mounts), r, p, y, int(case["enabled"]), case["factor"], case["resize"], 1000]
        args += [value for mount in case["mounts"] for value in mount]
        values = list(frame.applied_orientation) + [frame.max_camera_angle_before_limit, frame.limit_applied,
                  frame.effective_pitch_factor_q16, len(mounts)]
        values += [value for pose in frame.cameras for value in astuple(pose)]
        add("FRAME", args, values, case["name"])
        if not case["name"].startswith("random_"):
            case_results.append({"case": case, "result": {"applied_orientation": frame.applied_orientation,
                                 "max_camera_angle_before_limit": frame.max_camera_angle_before_limit,
                                 "limit_applied": frame.limit_applied,
                                 "effective_pitch_factor_q16": frame.effective_pitch_factor_q16,
                                 "cameras": [astuple(pose) for pose in frame.cameras]}})
        for pose in frame.cameras:
            width, height = rng.choice([(1920, 1080), (640, 512)])
            bx = rng.randint(-20 << 16, (width + 20) << 16)
            by = rng.randint(-20 << 16, (height + 20) << 16)
            mapped = ref.project_base_coordinate(bx, by, width, height, pose)
            add("MAP", [width, height, bx, by, pose.y_shift_q16, pose.cos_q15, pose.sin_q15],
                [mapped.valid, mapped.x_q16, mapped.y_q16, mapped.source_row if mapped.valid else -1], case["name"] + " map")

    # Unclamped angles exercise extraction near gimbal lock and every yaw quadrant.
    angle_vectors = [(r, p, yo, po, ro) for r in (-18000, -9000, -1, 0, 1, 9000, 18000)
                     for p in (-9001, -9000, -8999, 0, 8999, 9000, 9001)
                     for yo, po, ro in [(0, 0, 0), (9000, 0, 0), (39000, -125, 75)]]
    angle_vectors += [(rng.randint(-72000, 72000), rng.randint(-72000, 72000),
                       rng.randint(-72000, 72000), rng.randint(-18000, 18000), rng.randint(-18000, 18000))
                      for _ in range(random_cases)]
    for r, p, yo, po, ro in angle_vectors:
        angles = ref.convert_rpy_sensor_to_cam_centi(r, p, ref.CameraMount(yo, po, ro))
        add("ANGLE", [r, p, yo, po, ro], astuple(angles), "unclamped matrix/extraction")

    # Semantic checks are independent of matching a duplicate implementation.
    disabled = ref.compute_frame(700, -400, [ref.CameraMount(9000, 150, -75)],
                                 pitch_factor_q16=-655360, resize_factor_q16=65536, enabled=False)
    assert disabled.applied_orientation == (0, 0, 0)
    assert disabled.cameras[0].pitch_centi != 0 and disabled.cameras[0].roll_centi != 0
    for yaw in (0, 3000, 9000, -33000):
        assert ref.convert_rpy_sensor_to_cam_centi(75, -500, ref.CameraMount(yaw, 0, 0)) == ref.convert_rpy_sensor_to_cam_centi(75, -500, ref.CameraMount(yaw + 36000, 0, 0))
    zero_live = ref.compute_frame(0, 0, [ref.CameraMount(0, 2500, 1500)], pitch_factor_q16=-655360, resize_factor_q16=65536)
    assert not zero_live.limit_applied and zero_live.max_camera_angle_before_limit == 0
    assert max(abs(zero_live.cameras[0].roll_centi), abs(zero_live.cameras[0].pitch_centi)) > 1000

    request_text = "\n".join(requests) + "\n"
    result = subprocess.run([str(executable)], input=request_text, capture_output=True, text=True, timeout=180)
    (build / "oracle_stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Oracle failed: " + result.stderr)
    responses = result.stdout.splitlines()
    if len(responses) != len(expected):
        raise AssertionError("Oracle response count differs: %d != %d" % (len(responses), len(expected)))
    total_values = 0
    for index, (actual_line, wanted) in enumerate(zip(responses, expected)):
        actual = actual_line.split()
        if actual != wanted:
            mismatch = next((i for i, (a, b) in enumerate(zip(actual, wanted)) if a != b), min(len(actual), len(wanted)))
            failure = {"label": labels[index], "request": requests[index], "actual": actual,
                       "expected": wanted, "first_mismatch_token": mismatch}
            (build / "failure.json").write_text(json.dumps(failure, indent=2), encoding="utf-8")
            raise AssertionError("Bit mismatch: %s, token %d (see build/gravity_math/failure.json)" % (labels[index], mismatch))
        total_values += len(wanted) - 1
    (build / "directed_results.json").write_text(json.dumps(case_results, indent=2) + "\n", encoding="utf-8")
    return {"requests": len(requests), "integer_values_compared": total_values, "counts": counts,
            "random_seed": "0xC0DE6015", "random_frames": random_cases,
            "production_fixture": str(ini_path) if ini_path else None,
            "production_fixture_sha256": hashlib.sha256(ini_path.read_bytes()).hexdigest() if ini_path else None,
            "production_fixture_cases": len(production_cases),
            "request_sha256": hashlib.sha256(request_text.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--random-cases", type=int, default=2000)
    parser.add_argument("--ini", type=Path, help="Explicit optional calibration fixture; never a startup default")
    args = parser.parse_args()
    if args.random_cases < 0:
        parser.error("--random-cases must be nonnegative")
    if args.ini and not args.ini.is_file():
        parser.error("--ini file does not exist")
    build = ROOT / "build" / "gravity_math"
    build.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    provenance = check_provenance()
    executable, compiler = compile_oracle(build)
    report = run_suite(executable, build, args.random_cases, args.ini.resolve() if args.ini else None)
    report.update({"status": "PASS", "source_sha256": provenance["source_sha256"],
                   "oracle_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                   "compiler": compiler, "elapsed_seconds": round(time.monotonic() - start, 3)})
    (build / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
