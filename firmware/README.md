# Gravity-control MCU source

`eo_osd_remote` is the source project copied on 2026-10-16 from
`C:/SVNProjects/IMU_Stabilize_v40/EO_OSD_Remote_20260812/ST_Link-test`.
The original project was read only. `source_provenance.json` records all 129
selected source/build-metadata files with their original SHA-256 and byte size.
The copy includes Core, Drivers, .settings, CubeIDE project metadata, root IOC,
linker scripts and launch metadata. Generated Debug/Release directories,
binaries, logs, caches, reference archives and maintenance tools are excluded.

The original `.launch` files are retained as provenance, including their old
project names, output names and ST-Link log paths. They are not this repository's
build entry point and have not been executed. `.cproject` builder paths alone
were made relocatable (`${workspace_loc:/${ProjName}}`).

## Reproducible build and checks

From the repository root in PowerShell:

```powershell
./firmware/build_firmware.ps1
./firmware/test_gl_control.ps1
./firmware/verify_source_provenance.ps1
./scripts/test_gl_i2c_input.ps1
```

`build_firmware.ps1` accepts `-ToolBin` for an installed ARM GNU toolchain and
defaults to the local STM32CubeIDE 2.1.0 ARM GCC 14.3.1 bundle. It compiles every
copied Core/Src C file, the selected HAL sources and startup assembly, then links
with the copied STM32G0C1RETX_FLASH.ld. The CPU, defines, size optimization,
newlib-nano, floating printf and linker flags follow the original Debug makefile.
All outputs are under ignored `builds/firmware`; no global PATH modification,
programmer invocation or hardware access occurs. The host test accepts `-VcVars`
and confines Visual Studio environment changes to its child process.

Verified 2026-10-16: ARM build/link passed, text 70,848 bytes, data 0, BSS 6,072.
The inherited source/linker produces 22 warnings, including unused code,
addresses of packed members and an RWX load segment. The control host test passed
all 65,536 byte-valued UI pairs and all 256 modes, plus write/read/mismatch
failures, 100 ms retries, tick wrap, 1 s refresh and Off superseding a pending On.
Vivado 2025.2 I2C wire simulation passed 109 checks. These are software and RTL
functional checks, not hardware or physical CDC signoff.

## Wire contract

I2C slave address remains 7-bit `0x36`. A **single-byte** write to register
`0x04`, with its ACK completed and a STOP, commits the new control:

| Byte | Valid | Enabled |
| --- | --- | --- |
| `0xA0` | yes | no |
| `0xA1` | yes | yes |
| any other value / reset / no write | no | no |

The existing UI values are stabilization 0=N/A, 1=On, 2=Off and method 0=N/A,
1=Attitude Sensor, 2=Horizon Information. Only the exact pair `(1,1)` emits A1;
all other pairs emit A0. Startup requests A0. UI changes request the new code
immediately. A write failure, read failure or readback mismatch stays pending
and retries at 100 ms intervals during operation. Successful state refreshes
every 1 s so FPGA-only resets recover. A new Off supersedes a failed On without
waiting for its retry deadline. Readback verifies the I2C register transport; it
does not acknowledge a rendered frame. No new UI or serial-message schema is
introduced, and the existing UI response is not proof of FPGA application.

The existing pose burst is unchanged: `0x10` roll low, `0x11` roll high, `0x12`
pitch low, `0x13` pitch high; both signed int16 centi-degrees. FPGA publication
requires all four ACK-completed bytes followed by STOP. A repeated START abandons
the previous candidate. Partial/excess writes do not publish. Baseline raw
register-bank writes/readback remain in place. A source-generated FPGA receipt
sequence counts accepted bursts; it is not an IMU sample ID or exposure timestamp.

The MCU VSYNC test now recognizes stored/on-wire panorama modes `0x14` and
`0x15` and preserves legacy `0x01`/`0x02`. Each serviced pending VSYNC snapshots
the existing filtered roll/pitch. No yaw field, IMU filtering, axis convention,
camera mounting default, parameter bank or selected optics/INI value was changed.
Pose transmission still uses the inherited pending-VSYNC/latest-pose behavior;
it does not assert exposure synchronization.

## Source provenance

The verifier rehashes the original selected files and compares the local copy.
Expected local edits are `.cproject`, `.gitignore`, `fpga_regs.h`, `fpga_i2c.h/.c` and
`mcu_fsm.c`. `gl_control.h/.c`, the build/tests and this documentation are new.
The original hash manifest is not rewritten after local edits. To reproduce the
unmodified import in a separate empty directory, copy only paths enumerated in
the manifest from its source_root and verify those hashes before applying the
tracked local changes. The firmware build itself only reads this repository.
