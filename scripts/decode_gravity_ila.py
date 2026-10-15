#!/usr/bin/env python3
"""Decode numeric gravity diagnostic words without accessing hardware or files.

Layout: src/PanoramaBase_DdrBlackFrame.v, v19_dbg_rows_word0/word1.
Only word0 is connected to the current ILA (probe22). Optional word1 decodes
the logical signal for simulation or a future separately reviewed probe change.
"""

import argparse
import json
import re


FLAG_NAMES = (
    "ready", "enabled", "static_fallback", "history_miss", "stale_pose",
    "calibration_mismatch", "global_limited", "out_of_range",
)


def unsigned64(text):
    if not re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)", text):
        raise argparse.ArgumentTypeError("use unsigned decimal or 0x-prefixed hexadecimal")
    value = int(text, 16 if text.lower().startswith("0x") else 10)
    if value >= 1 << 64:
        raise argparse.ArgumentTypeError("value must fit unsigned 64 bits (no truncation)")
    return value


def signed16(value):
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def decode(word0, word1=None):
    for name, value in (("word0", word0), ("word1", word1)):
        if value is not None and (type(value) is not int or not 0 <= value < 1 << 64):
            raise ValueError(name + " must be an unsigned 64-bit integer")
    if word0 is None or word0 >> 48 != 0x474C:
        raise ValueError("word0 signature must be 0x474c in bits 63:48")
    flags = (word0 >> 8) & 0xFF
    result = {
        "word0_hex": "0x%016x" % word0,
        "signature": "0x474c",
        "applied_source_epoch": (word0 >> 32) & 0xFFFF,
        "receipt_sequence_low16": (word0 >> 16) & 0xFFFF,
        "flags": {name: bool(flags & (1 << (7 - index))) for index, name in enumerate(FLAG_NAMES)},
        "renderer_status_low8": word0 & 0xFF,
        "word0_probe": "dbg_ila_0 probe22",
        "notes": [
            "Sequence is only the low 16 bits of a wrapping local receipt count, not a sensor or exposure timestamp.",
            "When ready is false, applied metadata and angles can retain the previous completed result.",
            "Logical word1 is not connected to any current top-level ILA probe.",
        ],
    }
    if word1 is not None:
        result["word1_hex"] = "0x%016x" % word1
        result["camera_angles_before_renderer_clamp"] = [
            {"camera": camera, "roll_centi_degrees": signed16(word1 >> (32 + camera * 16)),
             "pitch_centi_degrees": signed16(word1 >> (camera * 16))}
            for camera in range(2)
        ]
        result["notes"].append("Angles are before the renderer's per-camera clamp to +/-1000 centidegrees.")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("word0", type=unsigned64, help="probe22 value: unsigned decimal or 0x hexadecimal")
    parser.add_argument("word1", nargs="?", type=unsigned64,
                        help="optional logical word1; current ILA does not expose this signal")
    args = parser.parse_args()
    try:
        result = decode(args.word0, args.word1)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
