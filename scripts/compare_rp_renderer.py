"""Compare isolated renderer test products against the unchanged stable model."""
import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'model'))
from compare_rp_tb import CASES, rc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_directory', type=Path)
    args = parser.parse_args()
    roms, frames = {}, {}
    total = 0
    for name, (sensor, roll, pitch, present) in CASES.items():
        if sensor.name not in roms:
            roms[sensor.name] = rc.load_rom(sensor)
            frames[sensor.name] = rc.synthetic_frames(sensor)
        got = np.array([int(word, 16) for word in
                        (args.output_directory / ('rp_' + name + '.hex')).read_text().split()], np.int64)
        expected = rc.render_offsets(sensor, roms[sensor.name], frames[sensor.name],
                                     roll, pitch, present).reshape(-1)
        if got.shape != expected.shape:
            raise AssertionError(f'{name}: shape {got.shape}, expected {expected.shape}')
        bad = np.flatnonzero(got != expected)
        if bad.size:
            raise AssertionError(f'{name}: {bad.size} mismatches; first indices {bad[:6]}')
        total += got.size
        print(f'{name}: bit-exact ({got.size} pixels)', flush=True)
    print(f'PASS RpRenderer: {len(CASES)} rasters, {total} bit-exact pixels')


if __name__ == '__main__':
    main()
