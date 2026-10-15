#!/usr/bin/env python3
"""Read build_gravity.tcl evidence; print JSON without touching build inputs.

Usage: python scripts/summarize_gravity_build.py builds/gravity_TIMESTAMP
       ... --output build/summary.json [--log builds/vivado_project/full_build.log]

An explicit --log must belong to this build; shared Vivado logs are never guessed.
Pending means incomplete evidence, not proof that Vivado is still running.
Completion validates recorded build guards, not hardware or blanket CDC safety.
Exit status: 0 for complete/pending evidence, 1 for failed/missing/superseded builds, 2 for
CLI errors. Automation must inspect overall_state before treating a build as complete.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re


NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
GL_CHECKS = ("no_clock", "constant_clock", "multiple_clock",
             "unconstrained_internal_endpoints", "loops", "latch_loops")
TOP = "KintexTop_EO_IR_HD_SDI_panorama_base"


def fingerprint(path):
    result = {"exists": path.is_file()}
    if not result["exists"]:
        return result
    try:
        before = path.stat()
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        after = path.stat()
        result.update(bytes=after.st_size, sha256=digest.hexdigest(),
                      stable_during_read=(before.st_size, before.st_mtime_ns) ==
                      (after.st_size, after.st_mtime_ns))
    except OSError as exc:
        result["read_error"] = str(exc)
    return result


def read_report(root, name):
    path = root / name
    evidence = {"path": name, **fingerprint(path)}
    text = ""
    if evidence["exists"]:
        try:
            text = path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError as exc:
            evidence["read_error"] = str(exc)
    evidence["state"] = "unparsed" if text else ("empty" if evidence["exists"] else "missing")
    return text, evidence


def timing(text, result):
    result["check_timing_counts"] = check_counts(text)
    section = text.split("| Design Timing Summary", 1)
    if len(section) != 2:
        return result
    names = ("WNS", "TNS", "setup_failing_endpoints", "setup_total_endpoints",
             "WHS", "THS", "hold_failing_endpoints", "hold_total_endpoints",
             "WPWS", "TPWS", "pulse_failing_endpoints", "pulse_total_endpoints")
    for line in section[1].splitlines():
        values = line.split()
        if len(values) == 12 and all(re.fullmatch(NUMBER if i % 4 < 2 else r"\d+", v)
                                     for i, v in enumerate(values)):
            summary = dict(zip(names, [float(v) if i % 4 < 2 else int(v)
                                       for i, v in enumerate(values)]))
            result["summary"] = summary
            bad = any(summary[n] < 0 for n in ("WNS", "TNS", "WHS", "THS", "WPWS", "TPWS"))
            bad |= any(summary[n] != 0 for n in names if "failing" in n)
            result["state"] = "fail" if bad else ("pass" if all(
                summary[n] > 0 for n in names if "total_endpoints" in n) else "incomplete_evidence")
            return result
    return result


def check_counts(text):
    counts = {}
    for name, value in re.findall(r"checking\s+(\w+)\s+\((\d+)\)", text):
        counts[name] = max(counts.get(name, 0), int(value))
    return counts


def route(text, result, guards):
    counts = {}
    for name, value in re.findall(r"(?m)^\s*#?\s*(?:of\s+)?([^:\n]+?)\s*:\s*(\d[\d,]*)\s*:?\s*$", text):
        counts[name.strip().rstrip(".").strip().lower()] = int(value.replace(",", ""))
    result["counts"] = counts
    bad_names = ("routing errors", "unrouted", "unplaced", "partially routed")
    bad = {k: v for k, v in counts.items() if v and any(n in k for n in bad_names)}
    full = counts.get("fully routed nets")
    total = counts.get("routable nets")
    if bad:
        result.update(state="fail", violations=bad)
    elif full is not None and total is not None and total > 0:
        result["state"] = "fail" if full != total else ("pass" if guards else "awaiting_guard")
    result["placed_fully_routed_fully_no_route_errors_guard"] = guards
    return result


def utilization(text, result):
    names = {"CLB LUTs", "CLB Registers", "Register as Latch", "Block RAM Tile", "URAM", "DSPs"}
    used = {}
    for line in text.splitlines():
        cells = [v.strip().rstrip("*") for v in line.split("|")[1:-1]]
        if len(cells) >= 2 and cells[0] in names and re.fullmatch(NUMBER, cells[1]):
            used[cells[0]] = float(cells[1])
    result["used"] = used
    if used:
        result["state"] = "reported"
    return result


def bus_skew(text, result):
    # Restrict numbers to the summary, excluding duplicate per-constraint paths.
    summaries = text.split("1. Bus Skew Report Summary")
    section = summaries[-1].split("2. Bus Skew Report Per Constraint")[0] if len(summaries) > 1 else ""
    values = [tuple(map(float, v)) for v in re.findall(
        r"(?:Slow|Fast)\s+(" + NUMBER + r")\s+(" + NUMBER + r")\s+(" + NUMBER + r")", section)]
    result["summary_constraints"] = len(values)
    result["gravity_mailboxes_present"] = all(n in section for n in ("u_pose_cdc", "u_control_cdc"))
    if values:
        result["minimum_slack_ns"] = min(v[2] for v in values)
        result["state"] = "fail" if result["minimum_slack_ns"] < 0 else "pass"
    if "Slack (VIOLATED)" in text:
        result["state"] = "fail"
    return result


def cdc_summary(text, result):
    entries = [{"id": code, "severity": severity, "count": int(count), "description": desc.strip()}
               for code, severity, count, desc in re.findall(
                   r"(?m)^\s*(CDC-\d+)\s+(Critical|Warning|Info)\s+(\d+)\s+([^\n]+)", text)]
    result["rules"] = entries
    result["counts_by_severity"] = {s: sum(e["count"] for e in entries if e["severity"] == s)
                                    for s in ("Critical", "Warning", "Info")}
    if entries:
        result["state"] = "reported_review_required" if any(
            e["severity"] != "Info" and e["count"] for e in entries) else "reported"
    return result


def logic_audit(root, stage, returned):
    text, result = read_report(root, "gravity_timing_%s.rpt" % stage)
    counts = check_counts(text)
    scope = re.search(r"(?m)^Scope: (.+)$", text)
    seq = re.search(r"(?m)^Sequential cells: (\d+)", text)
    ignored, ignored_info = read_report(root, "gravity_ignored_%s.rpt" % stage)
    no_cuts = bool(re.fullmatch(r"PASS: no internal user-ignored paths in .+ \(\d+ sequential cells\)\.\s*", ignored))
    result.update(check_timing_counts=counts, scope=scope.group(1).strip() if scope else None,
                  sequential_cells=int(seq.group(1)) if seq else None,
                  ignored_paths_report=ignored_info, no_internal_cuts=no_cuts,
                  audit_returned_before_next_phase=returned)
    if any(counts.get(n, 0) for n in GL_CHECKS):
        result["state"] = "fail"
    elif all(n in counts for n in GL_CHECKS) and scope and seq and int(seq.group(1)) > 0 and no_cuts:
        result["state"] = "pass" if returned else "awaiting_guard"
    elif text and returned:
        result["state"] = "incomplete_evidence"
    return result


def cdc_audit(root, stage, returned):
    result = {"state": "missing", "audit_returned_before_next_phase": returned, "mailboxes": {}}
    for mailbox, expected in (("pose", 64), ("control", 8)):
        text, item = read_report(root, "cdc_%s/%s_max_delay.rpt" % (stage, mailbox))
        requirements = [float(v) for v in re.findall(r"Requirement:\s+(" + NUMBER + r")ns", text)]
        slacks = [float(v) for v in re.findall(r"Slack \((?:MET|VIOLATED)\)\s*:\s*(" + NUMBER + r")ns", text)]
        destinations = set(re.findall(r"(?m)^\s*Destination:\s+(\S+)", text))
        item.update(expected_paths=expected, reported_paths=len(slacks), unique_destinations=len(destinations),
                    requirements_ns=sorted(set(requirements)), minimum_slack_ns=min(slacks) if slacks else None)
        if text:
            valid = len(requirements) == len(slacks) == len(destinations) == expected
            valid &= all(3.999 <= r <= 4.001 for r in requirements)
            # Synthesis route estimates are not the final timing verdict.
            item["state"] = "pass" if valid and (stage == "synth" or min(slacks, default=-1) >= 0) else "fail"
        result["mailboxes"][mailbox] = item
    text, info = read_report(root, "cdc_%s/bus_skew.rpt" % stage)
    result["bus_skew"] = bus_skew(text, info)
    text, info = read_report(root, "cdc_%s/cdc.rpt" % stage)
    result["full_cdc_report"] = cdc_summary(text, info)
    _, result["ignored_exceptions"] = read_report(root, "cdc_%s/ignored_exceptions.rpt" % stage)
    bus_state = result["bus_skew"]["state"]
    if stage == "synth" and bus_state == "fail" and result["bus_skew"]["summary_constraints"]:
        bus_state = "pass"  # Keep the negative estimate visible, without calling a routed build failed.
    states = [r["state"] for r in result["mailboxes"].values()] + [bus_state]
    if "fail" in states:
        result["state"] = "fail"
    elif all(s == "pass" for s in states) and result["bus_skew"]["gravity_mailboxes_present"] and result["ignored_exceptions"]["exists"] and result["full_cdc_report"]["rules"]:
        result["state"] = "pass" if returned else "awaiting_guard"
    elif any(s != "missing" for s in states):
        result["state"] = "incomplete_evidence"
    return result


def summarize(root, log=None):
    root = root.resolve()
    progress, progress_info = read_report(root, "progress.txt")
    events = [{"timestamp_local": m.group(1), "message": m.group(2)} for m in re.finditer(
        r"(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.+)$", progress)]
    messages = [e["message"] for e in events]
    has = lambda prefix: any(m.startswith(prefix) for m in messages)
    required_order = ("Synthesis complete", "Optimization started", "Placement started",
                      "Physical optimization started", "Routing started", "Routing complete",
                      "Timing passed:", "Guards passed; writing bitstream", "BITSTREAM COMPLETE")
    ordered = [next((i for i, message in enumerate(messages) if message.startswith(prefix)), -1)
               for prefix in required_order]
    progress_order_valid = all(a >= 0 and a < b for a, b in zip(ordered, ordered[1:]))
    guards = has("Guards passed; writing bitstream")
    complete = has("BITSTREAM COMPLETE (not programmed):")
    synth_returned = has("Optimization started")
    raw, manifest_info = read_report(root, "source_manifest.json")
    manifest = None
    if raw:
        try:
            manifest = json.loads(raw)
            if not isinstance(manifest, dict):
                raise ValueError("manifest must be an object")
            manifest_info["state"] = "reported"
        except (ValueError, TypeError) as exc:
            manifest_info.update(state="invalid", error=str(exc))
    inputs, inputs_info = read_report(root, "inputs.txt")
    metadata = dict(re.findall(r"(?m)^(Vivado|Top|Part|Place): (.+)$", inputs))
    reports = {}
    for name, parser in (("route_status", lambda t, r: route(t, r, guards)),
                         ("timing_routed", timing), ("bus_skew_routed", bus_skew),
                         ("utilization_synth", utilization), ("utilization_routed", utilization),
                         ("cdc_synth", cdc_summary), ("cdc_routed", cdc_summary)):
        text, info = read_report(root, name + ".rpt")
        reports[name] = parser(text, info)
    drc, reports["drc_routed"] = read_report(root, "drc_routed.rpt")
    drc_errors = re.findall(r"(?mi)^.*(?:\|\s*Error\s*\||^ERROR:|^\s*\S+\s+Error\s+).*$", drc)
    reports["drc_routed"]["error_rows"] = drc_errors
    if drc:
        reports["drc_routed"]["state"] = "fail" if drc_errors else ("pass_by_guard" if guards else "awaiting_guard")
    audits = {stage: {"logic": logic_audit(root, stage, synth_returned if stage == "synth" else guards),
                      "cdc_constraints": cdc_audit(root, stage, synth_returned if stage == "synth" else guards)}
              for stage in ("synth", "routed")}
    artifact_names = {"synthesized.dcp", "optimized.dcp", "placed.dcp", "physopt.dcp", "routed.dcp",
                      TOP + ".bit", TOP + ".ltx"}
    if root.is_dir():
        artifact_names.update(p.name for p in root.iterdir() if p.suffix.lower() in (".bit", ".ltx", ".dcp"))
    artifacts = {n: fingerprint(root / n) for n in sorted(artifact_names)}
    errors = re.findall(r"(?mi)^.*(?:^ERROR:|Refusing bitstream:|Synthesis failed:).*$", progress)
    log_info = None
    if log:
        log_text, log_info = read_report(log.resolve().parent, log.name)
        log_info["path"] = str(log.resolve())
        log_info["association"] = "explicit caller-supplied log; not independently associated"
        errors += re.findall(r"(?mi)^.*(?:^ERROR:|Refusing bitstream:|Synthesis failed:).*$", log_text)
    stages = {}
    for name, start, end in (("synthesis", "Synthesis started", "Synthesis complete"),
                             ("optimization", "Optimization started", "Placement started"),
                             ("placement", "Placement started", "Physical optimization started"),
                             ("physical_optimization", "Physical optimization started", "Routing started"),
                             ("routing", "Routing started", "Routing complete"),
                             ("bitstream", "Guards passed; writing bitstream", "BITSTREAM COMPLETE")):
        stages[name] = "complete_by_progress" if has(end) else ("started_not_completed" if has(start) else "not_observed")
    required = {"completion_marker": complete, "guards_marker": guards,
                "ordered_completion_progress": progress_order_valid,
                "timing_guard_marker": has("Timing passed:"), "routing_complete_marker": has("Routing complete"),
                "manifest": manifest_info["state"] == "reported" and bool(manifest and
                    re.fullmatch(r"[0-9a-fA-F]{40}", str(manifest.get("source_commit", ""))) and
                    isinstance(manifest.get("inputs"), dict) and manifest["inputs"] and
                    all(re.fullmatch(r"[0-9a-fA-F]{64}", str(v)) for v in manifest["inputs"].values())),
                "inputs_metadata": bool(metadata.get("Vivado")) and metadata.get("Top") == TOP and
                    metadata.get("Part") == "xcku15p-ffve1517-2-i"}
    for name in ("route_status", "timing_routed", "bus_skew_routed"):
        required[name] = reports[name]["state"] == "pass"
    required["drc_routed"] = reports["drc_routed"]["state"] == "pass_by_guard"
    required["utilization_routed"] = reports["utilization_routed"]["state"] == "reported"
    required["cdc_routed_report"] = bool(reports["cdc_routed"]["rules"])
    for stage, group in audits.items():
        for name, audit in group.items():
            required[stage + "_" + name] = audit["state"] == "pass"
    for name in (TOP + ".bit", TOP + ".ltx", "routed.dcp"):
        artifact = artifacts[name]
        required[name] = artifact.get("bytes", 0) > 0 and artifact.get("stable_during_read", False)
    failed = bool(errors) or any(r["state"] == "fail" for r in reports.values()) or any(
        a["state"] == "fail" for group in audits.values() for a in group.values())
    missing = [k for k, ok in required.items() if not ok]
    state = "superseded" if has("SUPERSEDED ") else ("failed" if failed else
            ("complete_verified" if not missing else
             ("missing" if not root.is_dir() else "pending_or_incomplete")))
    return {"schema_version": 1, "build_dir": str(root),
            "observed_at_utc": datetime.now(timezone.utc).isoformat(), "overall_state": state,
            "completion_requirements_not_met": missing, "explicit_errors": errors,
            "source_manifest": {"file": manifest_info, "declared": manifest,
                                "note": "Declared source hashes/status are preserved, not revalidated against today's checkout."},
            "build_metadata": metadata, "inputs_file": inputs_info,
            "progress": {"file": progress_info, "events": events, "last_event": events[-1] if events else None},
            "stages": stages, "artifacts": artifacts, "reports": reports, "gravity_audits": audits,
            "explicit_log": log_info,
            "notes": ["Read-only snapshot; pending does not prove a process is running.",
                      "complete_verified requires progress markers, parsed reports, scoped audits and stable nonempty artifacts.",
                      "Full CDC warnings and baseline external I/O timing exceptions require contextual review; no blanket CDC-clean claim.",
                      "No programming, capture, hardware operation or optical validation is established by this report."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("build_dir", type=Path)
    parser.add_argument("--output", type=Path, help="also write this JSON file; existing files are refused")
    parser.add_argument("--log", type=Path, help="optional log explicitly associated with this build")
    args = parser.parse_args()
    result = summarize(args.build_dir, args.log)
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        # Exclusive creation prevents accidental overwrite of reports/manifests.
        try:
            with args.output.open("x", encoding="utf-8", newline="\n") as stream:
                stream.write(encoded)
        except OSError as exc:
            parser.error(str(exc))
    print(encoded, end="")
    return 1 if result["overall_state"] in ("failed", "missing", "superseded") else 0


if __name__ == "__main__":
    raise SystemExit(main())
