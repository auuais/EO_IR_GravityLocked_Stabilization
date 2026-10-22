param([string]$OriginalRoot = '')
$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $PSScriptRoot 'source_provenance.json') -Raw | ConvertFrom-Json
if (-not $OriginalRoot) { $OriginalRoot = $manifest.source_root }
$edited = @('.cproject', '.gitignore', 'Core/Src/fpga_regs.h', 'Core/Src/fpga_i2c.h', 'Core/Src/fpga_i2c.c', 'Core/Src/mcu_fsm.c')
$localChanges = @()
foreach ($entry in $manifest.files) {
    $original = Join-Path $OriginalRoot $entry.path
    if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Original differs from import: $($entry.path)" }
    $local = Join-Path (Join-Path $PSScriptRoot 'eo_osd_remote') $entry.path
    if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $entry.sha256) {
        $localChanges += $entry.path
        if ($entry.path -notin $edited) { throw "Unexpected imported-file edit: $($entry.path)" }
    }
}
Write-Host "PASS provenance: $($manifest.files.Count) original file hashes unchanged; expected local edits: $($localChanges -join ', ')"
