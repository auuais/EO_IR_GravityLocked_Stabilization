# Gravity project entry point

`scripts/create_gravity_project.tcl` creates the development project in
`builds/vivado_project/EO_IR_GravityLocked_Stabilization.xpr`, using this
repository's source tree and the selected `3479cac` baseline settings.
The inherited root XPR is read for settings checks and is never opened or
rewritten. The original panorama repository is not accessed.

Run from a PowerShell terminal, with the working directory anywhere:

```powershell
$repo = 'E:\Xylinx\EO_IR_GravityLocked_Stabilization'
$out = Join-Path $repo 'builds\vivado_project'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Push-Location $out
try {
    & 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
        -source (Join-Path $repo 'scripts\create_gravity_project.tcl') `
        -log (Join-Path $out 'create_project.log') `
        -journal (Join-Path $out 'create_project.jou')
    if ($LASTEXITCODE -ne 0) { throw 'Project creation failed' }
} finally {
    Pop-Location
}
```

Change `$repo` after moving or cloning the repository. The script derives all
paths from its own location; recreate the generated project after relocation.
Vivado 2025.2 is required to match the selected baseline. Re-running replaces
generated project metadata and refreshes staged ROM files under the ignored
build directory.

## Preserved settings and files

- Part: `xcku15p-ffve1517-2-i`.
- Top: `KintexTop_EO_IR_HD_SDI_panorama_base`.
- Verilog source language, mixed simulation, `xil_defaultlib`.
- `Vivado Synthesis Defaults` and `Vivado Implementation Defaults`, 2025 flows;
  incremental checkpoint reuse disabled and no inherited generated checkpoint.
- Checked-in `ddr4_sub64`, `dbg_ila_0`, and `dbg_ila_1` IP definitions, unchanged.
  XPM CDC/FIFO/memory libraries are enabled as in the baseline full-build flow.
- Both baseline board constraint files, all `src/*.v` and `src/*.vh`, all
  `sim/*.v` and `sim/*.sv`, and the row-run/rollpitch `.mem` files.

The script calls `v19_refresh_fileset`, which includes new `Gl*.v` modules
automatically, then adds SystemVerilog testbenches and the IR memory files that
the inherited helper does not enumerate. All registered user source paths are
checked to remain inside the current repository. IP generation/upgrade and
synthesis/implementation are not run.

Inherited renderer RTL loads ROMs through `../../assets/...`, relative to a
synthesis run directory. Because this project lives under `builds`, the entry
point copies ROMs into `builds/vivado_project/assets` and byte-compares each
copy with its source. Run the entry point again after changing source ROMs.
The original assets and DDR XCI are not modified.

The standalone gravity projection/math modules and assets under
`reference/gravity_math` are not yet connected to the production top. Their
unit-test scripts own their ROM setup; inclusion of a module in this project
does not establish production integration or coefficient/profile correctness.
Likewise, full-top behavioral simulation may require ROM staging appropriate
to its simulator working directory; this creation-only check does not run it.

## Verification outputs and limits

The generated directory contains `project_manifest.txt`, `compile_order.txt`,
`ip_status.txt`, and the batch log. The manifest records the selected baseline,
part, top, run strategies, source counts, and every registered input. The script
fails if a required source/IP is missing, a source path escapes the repository,
or the inherited XPR/IP definition bytes change during creation.

This verifies project creation, loaded top, and fileset completeness. It does
not prove elaboration, ROM consumption by synthesis, physical CDC correctness,
timing closure, hardware behavior, or a working gravity-stabilized image.
IP output products may need generation during a subsequent full build.

Creation was verified on 2026-10-15 with Vivado 2025.2: 49 RTL `.v` files,
66 design inputs, 43 simulation inputs, and 12 staged ROMs. SHA-256 checks
matched all 12 source/staged ROM pairs and confirmed that the inherited XPR
and all three XCI files were unchanged. The verification record is
`builds/vivado_project/source_hash_verification.json`. Counts can grow as new
modules and tests are added; each new invocation records its current counts.
The IP status report listed all three cores as up to date. Vivado emitted
relocation notices saying future IP products will be generated under this
repository's `ip/<core>` directories, plus a performance notice for the
inherited helper's individual `add_files` calls and a deprecated report-switch
notice. No IP repair or upgrade was required or performed.

Use this entry point instead of inherited `codex_*`/legacy project helpers:
several helpers still name `E:/Xylinx/EO_IR_HD_SDI_panorama_base` directly, and
other inherited entry points open the root baseline XPR. This script invokes
neither group. The historical x64 DDR regeneration helpers must not replace
the checked-in, selected-baseline x48 DDR configuration.
