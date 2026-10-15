#!/usr/bin/env python3
"""Read-only audit of existing EO maps, segment coordinates and pitch scaling.

The default prints a deterministic JSON report. --output writes only that report;
this script never regenerates or edits production maps, ROMs, INIs or RTL. The
original external C source is optional: checked-in provenance is sufficient to
audit the local coefficient path, and external availability is reported explicitly.
Uses Python 3.9+ and the standard library; no compiler, NumPy or hardware needed.
"""

import argparse
import ast
import configparser
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "model"))
from gravity_reference import div_round_i64, float_to_q16

PROFILE_KEYS = ("width", "height", "num_cams", "fx", "fy", "cx_ratio", "cy_ratio",
                "resize_factor", "cylindrical_h_fov_deg", "cylindrical_v_fov_deg",
                "panorama_crop_height_scale", "panorama_crop_width_scale",
                "pitch_to_translation_factor", "overlap_px", "pano_width", "pano_height")


def display_path(path):
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def identity(path):
    info = {"path": display_path(path), "available": path.is_file()}
    if info["available"]:
        data = path.read_bytes()
        info.update(size_bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    return info


def evidence(path, pattern):
    regex = re.compile(pattern)
    return [{"path": display_path(path), "line": index, "text": line.strip()}
            for index, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1)
            if regex.search(line)]


def profile(path):
    result = identity(path)
    if not result["available"]:
        result["optional"] = True
        return result
    ini = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";",))
    ini.read(str(path), encoding="utf-8-sig")
    result["sensors"] = {}
    for sensor in ("eo", "ir"):
        section = sensor + "_camera"
        if section in ini:
            result["sensors"][sensor] = {key: ini.getfloat(section, key) for key in PROFILE_KEYS if key in ini[section]}
    return result


def baseline_model_config():
    tree = ast.parse((ROOT / "model/rpcore.py").read_text(encoding="utf-8-sig"))
    constants, sensors = {}, {}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
            continue
        name = node.targets[0].id
        if name in ("SEG", "ROWS", "NCAM", "ANGLE_MAX_CD"):
            constants[name] = ast.literal_eval(node.value)
        elif name in ("EO", "IR") and isinstance(node.value, ast.Call):
            sensors[name.lower()] = {kw.arg: ast.literal_eval(kw.value) for kw in node.value.keywords
                                     if kw.arg in ("src_w", "src_h", "rom_file", "rom_bits", "segs", "drun_to_q16", "pitch_tr", "cam_w")}
    return constants, sensors


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def map_audit(folder, records, geometry):
    xp, yp = folder / "eo_base_x_q16.bin", folder / "eo_base_y_q16.bin"
    result = {"folder": display_path(folder), "x": identity(xp), "y": identity(yp)}
    if not xp.is_file() or not yp.is_file():
        result["optional"] = True
        return result
    xb, yb = xp.read_bytes(), yp.read_bytes()
    if len(xb) != len(yb) or len(xb) % 4:
        raise ValueError("Malformed Q16 map pair: " + str(folder))
    x = [item[0] for item in struct.iter_unpack("<i", xb)]
    y = [item[0] for item in struct.iter_unpack("<i", yb)]
    rows, cams, segs, segment_width = (geometry[key] for key in ("rows", "cameras", "segments", "segment_width"))
    if len(x) % rows:
        raise ValueError("Map entry count is not divisible by configured row count")
    width = len(x) // rows
    result.update(entries=len(x), width_inferred_from_renderer_rows=width, rows=rows,
                  x_source_pixel_range=[min(x) / 65536.0, max(x) / 65536.0],
                  y_source_pixel_range=[min(y) / 65536.0, max(y) / 65536.0])
    matches, mismatches = 0, []
    if (segs - 1) * segment_width >= width:
        result["origin_comparison"] = {"status": "incompatible_shape", "record_count": len(records)}
        return result
    for sy in range(rows):
        for cam in range(cams):
            for seg in range(segs):
                index = (sy * cams + cam) * segs + seg
                record = records[index]
                ax = signed((record >> 48) & 0xFFFFFFFF, 32)
                ay = signed((record >> 80) & 0xFFFFFFFF, 32)
                base_index = sy * width + seg * segment_width
                if ax == x[base_index] and ay == y[base_index]:
                    matches += 1
                elif len(mismatches) < 8:
                    mismatches.append({"row": sy, "camera": cam, "segment": seg,
                                       "rom_origin_q16": [ax, ay], "map_origin_q16": [x[base_index], y[base_index]]})
    probe_row, probe_x = rows // 2, min(320, width - 1)
    probe_index = probe_row * width + probe_x
    result["origin_comparison"] = {"status": "all_match" if matches == len(records) else "differences",
                                    "matched_records": matches, "record_count": len(records),
                                    "first_mismatches": mismatches}
    result["probe"] = {"destination_row": probe_row, "local_x": probe_x,
                        "source_q16": [x[probe_index], y[probe_index]],
                        "source_pixels": [x[probe_index] / 65536.0, y[probe_index] / 65536.0]}
    return result


def register_width(path, name):
    found = evidence(path, r"signed\s+\[(\d+):(\d+)\]\s+" + re.escape(name) + r"\b")
    if len(found) != 1:
        raise ValueError("Could not identify unique signed width for " + name)
    match = re.search(r"signed\s+\[(\d+):(\d+)\]", found[0]["text"])
    width = int(match.group(1)) - int(match.group(2)) + 1
    return {"signal": name, "bits": width, "range": [-(1 << (width - 1)), (1 << (width - 1)) - 1], "evidence": found[0]}


def audit():
    constants, sensors = baseline_model_config()
    eo = sensors["eo"]
    if eo["rom_bits"] != 144:
        raise ValueError("This audit supports the selected baseline's documented 144-bit EO records")
    geometry = {"rows": constants["ROWS"], "cameras": constants["NCAM"], "segments": eo["segs"],
                "segment_width": constants["SEG"], "source_width": eo["src_w"], "source_height": eo["src_h"]}
    rom_path = ROOT / "assets/rowruns" / eo["rom_file"]
    records = [int(word, 16) for word in rom_path.read_text(encoding="ascii").split()]
    if len(records) != geometry["rows"] * geometry["cameras"] * geometry["segments"]:
        raise ValueError("EO ROM count does not match the selected renderer geometry")
    selected = profile(ROOT / "config/parameters_unified.ini")
    package = profile(ROOT / "assets/packages/eo_20260806/source_parameters_unified.ini")
    maps = [map_audit(ROOT / folder, records, geometry) for folder in
            ("assets/maps", "assets/packages/eo_20260806", "assets/packages/eo_20260831")]
    if maps[0].get("optional"):
        raise ValueError("Current assets/maps EO pair is required")

    shift_paths = [register_width(ROOT / "src/RpTables.v", "cam_ysh"),
                   register_width(ROOT / "src/RpTables.v", "xf_ysh"),
                   register_width(ROOT / "src/RpSegXform.v", "in_ysh")]
    shift_width = min(item["bits"] for item in shift_paths)
    lo, hi = -(1 << (shift_width - 1)), (1 << (shift_width - 1)) - 1
    factors = {}
    for sensor, baseline in sensors.items():
        cfg = selected["sensors"][sensor]
        configured = float_to_q16(cfg["pitch_to_translation_factor"])
        resize = float_to_q16(cfg["resize_factor"])
        effective = div_round_i64(configured << 16, resize or 65536)
        stable = float_to_q16(baseline["pitch_tr"])
        rom_words = [int(word, 16) for word in (ROOT / "assets/rollpitch" / (sensor + "_rp_angle.mem")).read_text().split()]
        probes = []
        for pitch in (-1000, -500, -100, 0, 100, 500, 1000):
            expected = div_round_i64(effective * pitch, 100 * 65536)
            stable_shift = div_round_i64(stable * pitch, 100 * 65536)
            encoded_shift = signed((rom_words[abs(pitch)] >> 33) & 0xFF, 8)
            if pitch < 0:
                encoded_shift = -encoded_shift
            probes.append({"camera_pitch_centi": pitch, "stable_shift_rows": stable_shift,
                           "decoded_stable_rom_shift_rows": encoded_shift,
                           "current_c_shift_rows": expected, "fits_current_shift_path": lo <= expected <= hi,
                           "if_narrowed_to_current_width": signed(expected & ((1 << shift_width) - 1), shift_width)})
        largest = max(abs(item["current_c_shift_rows"]) for item in probes)
        min_bits = next(bits for bits in range(2, 33) if largest <= (1 << (bits - 1)) - 1)
        factors[sensor] = {"configured_pitch_factor": cfg["pitch_to_translation_factor"],
                           "configured_pitch_factor_q16": configured, "configured_resize": cfg["resize_factor"],
                           "configured_resize_q16": resize, "source_normalized_factor_q16": effective,
                           "source_normalized_pixels_per_degree": effective / 65536.0,
                           "stable_factor_q16": stable, "stable_pixels_per_degree": baseline["pitch_tr"],
                           "stable_angle_rom": identity(ROOT / "assets/rollpitch" / (sensor + "_rp_angle.mem")),
                           "probes": probes, "minimum_signed_bits_for_these_plus_minus_10deg_probes": min_bits}

    frozen = json.loads((ROOT / "reference/gravity_math/provenance.json").read_text())
    original = Path(frozen["source_path"])
    external = identity(original)
    external["optional"] = True
    external["expected_frozen_source_sha256"] = frozen["source_sha256"]
    if external["available"]:
        external["matches_frozen_source"] = external["sha256"] == frozen["source_sha256"]
        if external["matches_frozen_source"]:
            external["source_evidence"] = evidence(original, r"PITCH_TO_TRANSLATION_FACTOR_q16 = div_round|src_[xy] = src_[xy]_r \* inv_resize")

    differences = {}
    if package["available"]:
        differences = {key: {"installed_map_package_profile": package["sensors"]["eo"].get(key),
                             "selected_profile": selected["sensors"]["eo"].get(key)}
                       for key in PROFILE_KEYS if package["sensors"]["eo"].get(key) != selected["sensors"]["eo"].get(key)}
    baseline_provenance_path = ROOT / "docs/BASELINE_PROVENANCE.json"
    baseline = json.loads(baseline_provenance_path.read_text()) if baseline_provenance_path.is_file() else {}
    return {
        "schema": "gravity-geometry-readonly-audit-v1",
        "scope": "Existing artifacts only: no production ROM/map/INI/RTL writes and no hardware access",
        "selected_baseline_commit": baseline.get("baseline", {}).get("commit"),
        "script": identity(Path(__file__)),
        "renderer_geometry": geometry, "segment_rom": identity(rom_path), "map_packages": maps,
        "selected_profile": selected, "installed_map_package_profile": package,
        "eo_profile_differences": differences, "pitch_factors": factors, "shift_path_widths": shift_paths,
        "source_evidence": {
            "rom_origins_copied_without_scaling": evidence(ROOT / "scripts/v19_generate_render_runs.py", r"ax0, ay0 = x\[i0\], y\[i0\]"),
            "model_translation_in_source_q16": evidence(ROOT / "model/rpcore.py", r"cx, cy = s\.src_w|dy = rom\[\"ay0\"\]|Ay ="),
            "rtl_translation_in_source_q16": evidence(ROOT / "src/RpSegXform.v", r"localparam signed.*EO_C[XY]|dy1\s+<="),
            "rom_shift_field_and_generator_range": evidence(ROOT / "model/gen_rp_roms.py", r"ysh\[40:33\]|-128 <= ysh < 128|ysh & 0xFF"),
            "frozen_c_contract": [item for item in frozen["additional_source_contract"] if item["start_line"] == 1007],
        },
        "optional_external_original_c": external,
        "proven_findings": [
            "Installed EO segment origins are directly compared against every available package map; match counts above identify equivalence without relying on folder dates.",
            "Baseline translation is in original-source Q16 pixels around width/2,height/2; there is no resize multiplication in the local transform.",
            "Current C normalizes configured pitch Q16 by configured resize Q16 before applying source-pixel translation.",
            "The listed pitch probes distinguish stable offsets from the current selected-INI C behavior and expose signed shift-path overflow.",
        ],
        "limits_and_required_regression": [
            "Numerical coordinate/factor evidence does not select the user's optical-geometry policy or authorize changing production assets.",
            "Package profile provenance and byte-identical maps do not prove that maps were regenerated from the selected INI; the differing profile values are listed explicitly.",
            "To isolate gravity math, hold identical base maps and trig coefficients and compare source-coordinate probes at zero and +/-1/5/10-degree camera pitch.",
            "Widening shifts or adopting normalized EO translation requires new row-window occupancy, source coverage, clipping and rendered-image regressions; this audit does not run a renderer.",
            "The minimum shift widths reported cover the specified +/-10-degree probes only; arbitrary static trims can exceed a one-pass global limit.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write only this JSON evidence report; default prints to stdout")
    args = parser.parse_args()
    report = audit()
    payload = json.dumps(report, indent=2) + "\n"
    if args.output:
        path = args.output.resolve()
        if path.suffix.lower() != ".json":
            parser.error("--output must name a JSON report")
        protected = [ROOT / folder for folder in ("assets", "config", "src", "reference", "model", "scripts", "sim")]
        if any(folder.resolve() == path or folder.resolve() in path.parents for folder in protected):
            parser.error("Refusing to write a report into a production/source-artifact directory")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload.encode("utf-8"))
        print("Wrote read-only geometry evidence:", path)
        print("EO origin matches:", report["map_packages"][0]["origin_comparison"])
        print("EO normalized factor Q16:", report["pitch_factors"]["eo"]["source_normalized_factor_q16"])
        print("Current shift bits:", report["shift_path_widths"][0]["bits"],
              "required for +/-10 degree probes:", report["pitch_factors"]["eo"]["minimum_signed_bits_for_these_plus_minus_10deg_probes"])
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()
