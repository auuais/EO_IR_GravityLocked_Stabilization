# One-time INI mounting calibration

The user selected this policy on 2026-10-19: apply the selected INI mounting
values once, then preserve subsequent UI calibration changes. This change is
in the copied MCU firmware. It does not alter FPGA RTL, optical maps or the
timing-passing FPGA candidate from 2026-10-16.

## Startup behavior

On the first successful migration, replace only the two banks' six yaw,
pitch and roll arrays. EO yaw is 0/60/120/180/240/300 degrees; IR yaw is
90/150/210/270/330/390 degrees. All mounting roll/pitch values become zero.
Yaw remains unsigned centidegrees, including 33000 and 39000. Preserve valid
stored overlap, feather strength, mode and unrelated/reserved payload fields.
If no valid configuration exists, retain the existing optical defaults of
EO overlap 100, IR overlap 30 and feather strength 1.0.

The source is `config/parameters_unified.ini`, SHA-256
`7106b1f1ad56d545c6b3eef5b29f9608fdb1cfb02ce364b1ca85ca096c3eea3c`.
Its orientation test poses, stabilization flags and optical settings are not
startup calibration. The journal stores profile revision `0x7106B1F1`;
migration is determined by this metadata, never by whether an angle is zero.
A nonzero profile revision is preserved by later saves and prevents reapplication.

Subsequent boots load the saved UI values and do not erase/program flash.
The existing runtime startup mode remains EO panorama (`0x15`). Migration
preserves the stored mode; forcing the runtime startup mode no longer rewrites
flash on every boot. Later explicit mode/configuration saves store the runtime
mode with the current calibration.

Current FPGA gravity projection uses fixed INI mounting yaw constants. UI yaw
edits are retained and read back, but do not change those RTL constants. Runtime
roll/pitch trims feed the existing renderer and gravity projection. This change
does not add dynamic mounting-yaw support to the FPGA.

## Flash journal and recovery

The linker reserves the final 4 KB of the 512 KB STM32G0C1RE flash. Application
FLASH is limited to 508 KB. Slot 0 is `0x0807F000`, slot 1 is `0x0807F800`, each
2 KB. The adapter refuses unsupported device size or mismatched linker bounds.
It does not change option bytes.
The linker also reserves a 4 KB minimum stack allowance: compiler stack reports
put the nested migration path above the old 1 KB minimum before MCU/HAL callers.
This is a link-time space guard, not a measured whole-firmware stack high-water mark.

The old v3 record is an exact 112-byte payload at slot 1. The new v4 envelope
contains a 32-byte header, that compatible payload, and a separate 8-byte commit
marker at offset 144. Header metadata, generation, profile and payload are
CRC-protected. The payload also retains its v3 CRC and validation rules.

Migration writes slot 0 while leaving a valid legacy slot 1 untouched. Later
saves alternate slots, writing and verifying the body before programming the
commit marker last. A completed record must pass marker, CRC, semantic and
readback checks. Only then are the RAM generation and successful-write count
advanced. Startup selects the newest valid committed generation, including wrap.

An interrupted erase/program leaves the other committed copy available. An
unreadable inactive slot can be erased for a retry only when another valid copy
survives. With no trustworthy surviving copy and a read error, writes are
blocked rather than replacing possibly recoverable calibration with defaults.
An unsupported flash layout similarly blocks writes. Boot diagnostics remain
in `s_cfg_boot_result`, `s_cfg_geometry_ok` and `s_cfg_journal` for debugger review.

A failed final program call is reconciled by reading the actual commit record.
If completion cannot be read back, the save fails with `PARAM_STORE_COMMIT_UNCERTAIN`;
reboot may select the physically committed record. This is distinct from a
verified successful save. A later save rescans before choosing an erase target.

The 512 KB device always has two physical banks. The last two logical pages map
to physical bank 2, pages 126/127, when `nSWAP_BANK=1`, and physical bank 1 at the
same page indices when `nSWAP_BANK=0`. Programming/readback use logical addresses;
erase uses the explicit physical bank. The 256 KB-only `DUAL_BANK` option is
not used to infer a single bank on this 512 KB target. See ST's
[RM0444 reference manual](https://www.st.com/resource/en/reference_manual/rm0444-stm32g0x1-advanced-armbased-32bit-mcus-stmicroelectronics.pdf)
and the bundled HAL flash implementation.

The NMI hook handles only double-bit ECCD matching the exact guarded journal read;
the read helper also rejects matching single-bit ECCC corrections.
Unrelated NMI causes retain the existing fail-stop handler. A faulted slot is
quarantined until erased, preventing a cached reread from accepting bad data.
Host fault injection cannot establish electrical brownout behavior or actual
device ECC/NMI return behavior; these remain hardware qualification items.

## UI compatibility

In ICD mode, the existing manual OSD command remains available. Calibration
Get (`0x30`) and Apply (`0x31`) are also accepted through the existing COBS/CRC
transport. Apply still requires operational state. Only replies belonging to
an explicit calibration request are enabled; periodic legacy logs and other
legacy commands remain disabled.

Apply requires exactly one 42-byte bank payload. Pitch/roll remain limited to
plus/minus 500 centidegrees, overlap to 1920 pixels, and feather to 0.1–10.0.
The decoder accepts the existing Q16 feather representation and the supplied
PC UI source's IEEE binary32 representation. Their valid bit-pattern ranges
do not overlap. NaN, infinity and out-of-range values are rejected. Readback
continues to use Q16. The installed UI executable has not been identified by
these source checks.

Firmware programming must preserve the two journal pages if existing saved
calibration is to survive. A mass erase removes both calibration and the
one-time marker, so the next successful startup applies the INI again. The
linker reservation prevents firmware image growth into the journal; it cannot
prevent a programmer's explicit mass erase. Downgrading to old single-page
firmware does not preserve the new journal contract.

## Verification and bench boundary

Run `firmware/test_param_store.ps1`, `firmware/test_param_store_stm32.ps1`,
`firmware/test_param_payload.ps1`, `firmware/test_gl_control.ps1`, then
`firmware/build_firmware.ps1`. Retain test logs and the exact ELF/HEX hashes with
the candidate. The storage tests model interrupted erase/program/commit,
corruption, generation wrap, legacy migration and repeated UI saves/reboots.
Adapter tests exercise address/bank selection and guarded fault handling.

The 2026-10-19 candidate from commit `e18eda2` passed:

- 363 journal interruption/callback-failure cases and 1,216 single-bit record
  corruption cases, including one-time migration and later UI saves/reboots.
- 795 STM32 adapter mock checks and 5,908,422 payload/protocol checks.
- The existing control regression: 65,536 UI pairs and 256 modes, including
  retry, reset and refresh behavior.
- Strict host/ARM compilation of the new modules and the complete ARM build.
  The full build has 10 warnings, all already present in the earlier build;
  none are from the new modules. The old packed-member warnings are removed.
- Compiled mounting defaults match the selected INI. The linked image excludes
  both journal pages. All 129 original MCU source/provenance files and the
  existing FPGA candidate's 137 inputs, 14 staged ROMs and 3 scripts match
  their recorded hashes.

MCU version 1.1 artifacts are in `builds/firmware_20261019_ini_once_final/`.
The [validation record](validation/mcu_ini_once_20261019.json) records the exact
ELF/HEX hashes, source input hashes, warning messages and test log hashes. Local
logs are copied into that candidate's `test_evidence/` directory. Code size is
76,912 bytes; BSS is 9,392 bytes including the heap/stack reservation. The linker
reserves a 4 KB minimum stack; full runtime stack high-water is unmeasured.
Use this MCU with the timing-passing FPGA candidate in
`builds/gravity_20261016_020605/`. The MCU copy inside the older FPGA archive
predates migration and is retained only as historical evidence.

Before declaring hardware persistence accepted, verify the installed device,
programmer erase policy and option bytes; save existing calibration; confirm
first-start migration, change both banks through the UI, and read back the same
values after repeated power cycles. Keep actual device power-interruption tests
separate from host-model results. No MCU programming is performed by the build
or test scripts.
