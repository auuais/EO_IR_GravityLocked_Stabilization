param([string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'builds\i2c_input'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
function Run-Tool([string]$Name, [string[]]$ToolArgs, [string]$Log) {
    & (Join-Path $VivadoBin ($Name + '.bat')) @ToolArgs *> $Log
    if ($LASTEXITCODE -ne 0) { Get-Content $Log; throw "$Name failed" }
}
Push-Location $buildRoot
try {
    Run-Tool xvlog @('-sv', "$repoRoot/src/GlPoseCdc.v", "$repoRoot/src/GlPoseReceiver.v", "$repoRoot/src/Kintex_top_I2C_test.v", "$repoRoot/sim/tb_GlI2cInput.sv") 'compile.console.log'
    Run-Tool xelab @('tb_GlI2cInput', '-s', 'gl_i2c_input') 'elaborate.console.log'
    Run-Tool xsim @('gl_i2c_input', '-runall') 'run.console.log'
    $result = Get-Content 'run.console.log' -Raw
    if ($result -notmatch 'PASS GlI2cInput' -or $result -match '(?im)^\s*(Fatal|Error):') { throw $result }
    ($result -split "`r?`n" | Where-Object { $_ -match 'PASS GlI2cInput' }) | Write-Host
} finally { Pop-Location }
