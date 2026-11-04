# DDR4 MIG IOSTANDARD, DCI/VRP and x64/x48 review

Review date: 4 November 2026. Offline inspection; the FPGA was disconnected.
No RTL, IP settings, constraints, bitstream or board wiring was changed.

## Finding

**DCI is enabled in the generated constraints. The schematic leaves the three
required local VRP references unconnected, and DCI cascading is disabled.**
Successful MIG calibration does not resolve that electrical inconsistency.
The missing VRP references are a credible signal-integrity concern, but the
archive does not establish them as the cause of the old x16-lane corruption.

The generated electrical XDC is `ip/ddr4_sub64/par/ddr4_sub64.xdc`, not the
nearly empty `ddr4_sub64_board.xdc`. The top-level
`constraints/ddr4_sub64_firstpass.xdc` supplies package-pin assignments.
Despite its inherited name and introductory x64 comments, its working data
map is x48. The older `docs/DDR4_PINMAP.md` describes a superseded first-pass
map and must not be used to identify the current lane pins.

The generated XDC is byte-identical in RowWindow, RollPitch and GravityLocked
repositories (SHA-256
`9af9f8e33bcfddc45507b3e8674fd63547c325cbc8f10ab2016528fa165daced`).
The reviewed GravityLocked source starts at commit `884ebc1`; the saved
October 23 routed implementation was built from `5126c37`.

## Generated electrical settings

| Signal class | Count | IOSTANDARD | Example XDC line |
|---|---:|---|---:|
| DQ `[47:0]` | 48 | `POD12_DCI` | 187 |
| DM/DBI `[5:0]` | 6 | `POD12_DCI` | 188 |
| DQS T/C, six pairs | 12 pins | `DIFF_POD12_DCI` | 205 |
| Address, bank, ACT, CS, CKE, ODT | 24 | `SSTL12_DCI` | 170 |
| DDR CK T/C | 2 pins | `DIFF_SSTL12_DCI` | 127 |
| DDR reset | 1 | `LVCMOS12` | 110 |
| Controller input reference clock | 2 pins | `DIFF_SSTL12` | 149--150 |

The input reference clock is distinct from the DDR CK outputs. Its non-DCI
standard and the reset exception do not disable DCI on the memory bus.
`OUTPUT_IMPEDANCE RDRV_40_40` is applied to the 92 DCI signal pins (lines
14--105); reset instead uses DRIVE 8. `ODT RTT_40` is applied to DQ/DQS
(line 219) and DM/DBI (line 226). These are requested impedances, not an
electrical measurement of the assembled board.

The XCI records `C0.DDR4_DataWidth=48`, `C0.DDR4_TimePeriod=1071` ps
(approximately 1866 MT/s), `C0.DDR4_InputClockPeriod=4999` ps and
`DCI_Cascade=false` (line 84). **That false value disables sharing of DCI
references; it does not disable DCI.** The actual routed-checkpoint audit is
retained with this report's evidence.

Opening both the latest GravityLocked and saved RollPitch routed checkpoints
in Vivado confirms identical memory port standards and bank assignments.
Their DCI_CASCADE and MASTER_BANK properties are empty for all three banks,
with IS_MASTER=0. Bank 66 carries
DQ `[15:0]`, bank 68 carries DQ `[47:16]` and reset, and bank 67 carries
address/control and DDR CK. Banks 66/68 report INTERNAL_VREF=0.840.
There is no DCIRESET instance. Absence of that optional primitive is not
evidence that ordinary startup DCI is disabled.

Both routed designs return empty/unset values for
`BITSTREAM.STARTUP.MATCH_CYCLE` and `BITSTREAM.CONFIG.DCIUPDATEMODE`; no source
override was found. Therefore this audit does not infer an explicit final
bitstream startup-match choice from the checkpoint. UG571 describes the tool
default DCI update policy as ASREQUIRED, but that is not a measurement of this
board's DCI state or impedance. The archived query retains the unset values.

## Schematic cross-check and AMD requirement

The source schematic is
`C:/SVNProjects/IMU_Stabilize_v40/Circuit Diagram/tbt_camerasystem_251106.pdf`.
PDF page 11, printed sheet 9/17, draws the following as open pin stubs,
without a connecting wire, net label or reference resistor:

| Bank | FPGA VRP package pin | FPGA schematic unit |
|---|---|---|
| 66 | AU27 | U16-7 |
| 67 | AR29 | U16-6 |
| 68 | AP30 | U16-5 |

These package assignments also match Vivado's I/O report. A schematic is
evidence of intended wiring; it cannot establish the populated board's
revision, rework or measured resistance. The user separately reports these
pins floating on the board.

AMD's [PG150 DDR4 pin rules, item 5](https://docs.amd.com/r/en-US/pg150-ultrascale-memory-ip/DDR4-Pin-Rules)
require DCI for DDR4, including output-only address/control banks. DCI cascade
is permitted at data rates up to 2133 Mb/s. [UG571, pages 18--21](https://docs.amd.com/api/khub/documents/kFbaUC5HGcXyGNauhgU6Gw/content)
specifies a precision 240-ohm resistor from VRP to ground. Cascading permits
slave banks to share a master's reference, but still requires the master's
external resistor and valid bank/voltage grouping. With the reviewed
non-cascaded configuration, each of banks 66, 67 and 68 needs its own reference.

Two other resistor networks do **not** provide those FPGA references:

- FPGA VREF on PDF page 16, printed sheet 12/17: AG25/VREF66 to R1476,
  AR28/VREF67 to R1533, AH29/VREF68 to R1535; all are 1 kOhm to ground.
  Receiver voltage reference and DCI impedance reference are different functions.
- DRAM ZQ on pages 17--18: each memory's F9 uses its own 240-ohm resistor
  (M1/R87, M2/R88, M3/R93, M4/R142, M5/R94). Those are memory-side references,
  not connections to FPGA VRP.

## Why calibration success is insufficient

AMD defines [`init_calib_complete`](https://docs.amd.com/r/en-US/pg150-ultrascale-memory-ip/init_calib_complete)
as completion of PHY calibration. The documented
[calibration sanity checks](https://docs.amd.com/r/en-US/pg150-ultrascale-memory-ip/Calibration-Overview)
perform read and write/read comparisons while aligning the interface.
This is distinct from confirming the board's VRP resistance or qualifying
all traffic patterns and operating conditions.

A plausible explanation is that the channel has enough margin for training
under the tested conditions despite an uncontrolled impedance. That is an
inference, not a measured explanation of this board. Neither the source nor
the inspected evidence establishes an automatic switch to non-DCI standards,
a valid internal replacement for the resistor, or a specific fallback
impedance. The actual analog condition cannot be determined offline.

Dynamic PHY termination control must also be distinguished from DCI
calibration. The generated PHY uses `DCITERMDISABLE` to control termination
with bus direction/activity; that does not remove the reference requirement.
Likewise internal VREF, DRAM ZQ calibration and a healthy-looking image are
not evidence that the FPGA impedance is correctly referenced.

## What actually happened in the x64-to-x48 investigation

The resolved July 9 update in
[`CODEX_NEXT_SESSION_HANDOFF_20260708.md`](CODEX_NEXT_SESSION_HANDOFF_20260708.md)
(lines 62--104) supersedes the earlier handoff's interpretation that one
temporal BL8 transfer was faulty. It records:

1. x64 used a 512-bit application word and showed eight unstable 16-bit
   pixels per 32-pixel word: a 128-bit, x16-device contribution.
2. x48 used a 384-bit application word and still showed the same eight
   unstable pixels, now per 24 pixels. The remap retained old physical byte
   lanes 2--7; it had omitted the wrong x16 device.
3. The failing contribution was localized to application bits `[383:256]`,
   corresponding to old physical lanes 6/7, `FU_DDR4_DQ48..63` and DQS6/7.
4. The successful workaround kept all image data in `[255:0]`. MIG remained
   x48; the failing contribution remained physically configured but carried
   no image payload. This was a payload bypass, not repair or proof of a
   reliable full-width x48 interface.

The current RTL preserves that workaround:
`src/PanoramaBase_DdrBlackFrame.v:197--205` declares a 384-bit application
interface, zero guard offset and a 256-bit payload. Current data pins span
banks 66 and 68; command/address is in bank 67. Narrowing did not eliminate
the VRP requirement in any of those banks.

Original logs in `E:/Xylinx/EO_IR_HD_SDI_panorama_base` include:

- `codex_ddr_margins2.log`: July 7 calibration query; line 161 reports no
  calibration errors and lines 163--189 list 17 PASS and 10 SKIP stages,
  with no FAIL.
- `codex_retime_1866_synth2.log`: July 8 x64 configuration at 1071 ps,
  with 4999 ps input clock (lines 235--240).
- `codex_set_ddr4_x48.log`: July 9 width change to 48, before the final guard.
- `codex_x48_program.log`: intermediate x48 programming at about 04:07.
- `codex_program_component_guard_20260709_0636.log`: final payload-bypass
  programming at about 06:37.

The July 9 implementation change is retained in commit
`8caaea4d0e4f18dd95f9e4b6aab3838509170016` of the earlier panorama repository.
The x64-to-x48 transition retained 1866 MT/s; earlier 2400/1600/1866 rate
experiments had not removed the dominant corruption. The resolved handoff
records two 120-frame USB
checks and uniform temporal-phase differences after the bypass. These
observations support the workaround on that test; they do not identify VRP,
DRAM silicon, assembly or FPGA circuitry as the electrical root cause.

## Next discriminating bench test

First verify board revision and powered-off resistance/continuity at the
three **VRP** pins, separately from VREF and DRAM ZQ. Correct the hardware
reference network to the approved non-cascaded design, or validate a
supported cascade with a populated master reference. Changing only the XDC
to remove `_DCI` would not implement the documented MIG interface.

For causal testing, compare otherwise identical full-width diagnostic builds
before/after the reference correction, recording bitstream identity, rate,
resets, per-byte read/write margins and error counts. Exercise every x48
application bit, including `[383:256]`, with walking-bit, alternating,
PRBS and address-dependent patterns under sustained mixed reads/writes.
Repeat cold starts and relevant voltage/temperature conditions. Only after
full-width x48 is reliable should the x64 map be restored and tested with
the same protocol. A panorama-only test of the low-256-bit bypass cannot
answer whether the excluded x16 contribution has recovered.

No such physical test was performed during this disconnected review.

## Archived evidence and reproduction

The evidence directory is [`validation/ddr4_dci_vrp_20261104/`](validation/ddr4_dci_vrp_20261104/):

- [`mig_generated_electrical.xdc`](validation/ddr4_dci_vrp_20261104/mig_generated_electrical.xdc):
  byte-preserved copy of the generated electrical constraints.
- [`query_routed_dci.tcl`](validation/ddr4_dci_vrp_20261104/query_routed_dci.tcl),
  [`query_routed_dci_transcript.txt`](validation/ddr4_dci_vrp_20261104/query_routed_dci_transcript.txt)
  and [`query_summary.json`](validation/ddr4_dci_vrp_20261104/query_summary.json):
  read-only queries of both saved checkpoints, raw output and structured results.
  Vivado 2025.2 exited with code 0. Checkpoint identity does not establish which
  bitstream was loaded for each historical hardware observation.
- [`historical_log_excerpts.txt`](validation/ddr4_dci_vrp_20261104/historical_log_excerpts.txt):
  numbered original log excerpts and the two USB capture summaries.
- [`source_manifest.json`](validation/ddr4_dci_vrp_20261104/source_manifest.json):
  original file paths, sizes, SHA-256 hashes and extracted XDC settings.
- [`package_manifest.json`](validation/ddr4_dci_vrp_20261104/package_manifest.json):
  SHA-256 hashes of the archived evidence files and this report.

The checkpoint query can be repeated from the evidence directory in PowerShell:

```powershell
Get-Content -Raw query_routed_dci.tcl |
  & 'C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat' -mode tcl -nojournal -nolog -notrace
```

The script contains the two original checkpoint paths and only reads design
properties before closing each design. It neither builds a bitstream nor
connects to hardware. Reproduction requires those locally retained DCPs;
their large binaries and the source schematic are identified by hash rather
than copied into this evidence package.
