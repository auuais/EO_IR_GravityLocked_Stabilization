# Initial gravity-lock verification — 2026-10-15

The selected baseline is 3479cacf2e512a5bde9aa3e0243755826e071ef4.
These are standalone functional tests, not integrated FPGA timing or image tests.

| Check | Result |
| --- | --- |
| Baseline commit/tree and calibration hash | PASS |
| All 8 copied stable archive files, source versus copy SHA-256 | PASS |
| Python versus exact extracted C++, MSVC /O2 /fp:precise | PASS: 79,397 requests, 245,237 integer comparisons |
| Full trig and atan tables, regenerated from fresh C++ executable | PASS: byte-identical deterministic assets |
| Atomic I2C pose receipt, Vivado 2025.2 xsim | PASS: 190 state checks |
| CDC source/destination half-periods 5/7 ns, phase 3 ns | PASS |
| CDC source/destination half-periods 11/3 ns, phase 1 ns | PASS |
| CDC source/destination half-periods 7/13 ns, phase 8 ns | PASS |

The C comparison uses the copied user-selected config/parameters_unified.ini
(SHA-256 7106b1f1ad56d545c6b3eef5b29f9608fdb1cfb02ce364b1ca85ca096c3eea3c).
Its report is gravity_math_20261015.json. Exact C excerpt and generated ROM/vector
hashes are recorded under reference/gravity_math. Test scripts reproduce results;
local compiler/simulator logs are retained in ignored build/ and builds/ directories.

The pose receiver rejects partial/misordered/restarted/excess-byte transactions.
The CDC tests exercise bursts, coherent pairs, no duplicates, latest eventual
arrival, receipt-counter wrap and common reset in flight. They do not prove
physical CDC timing or sensor-to-exposure alignment.
