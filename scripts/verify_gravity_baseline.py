"""Verify recorded baseline/profile hashes without touching the FPGA or source repos."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", action="store_true", help="also verify local archived build files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    data = json.loads((root / "docs/BASELINE_PROVENANCE.json").read_text(encoding="utf-8"))
    commit = data["baseline"]["commit"]
    tree = subprocess.check_output(["git", "rev-parse", commit + "^{tree}"], cwd=root, text=True).strip()
    if tree != data["baseline"]["tree"]:
        raise SystemExit("FAIL: baseline tree differs from recorded provenance")
    subprocess.run(["git", "merge-base", "--is-ancestor", commit, "HEAD"], cwd=root, check=True)
    checks = [data["calibration"]]
    if args.archive:
        checks += data["stable_archive"]["files"]
    for entry in checks:
        path = root / entry["local_path"]
        if not path.is_file() or sha256(path) != entry["sha256"]:
            raise SystemExit("FAIL: missing or changed " + str(path))
        print("PASS:", entry["local_path"])
    print("PASS: baseline commit/tree preserved as an ancestor of this checkout")


if __name__ == "__main__":
    main()
