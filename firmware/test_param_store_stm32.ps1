param([string]$VcVars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'builds\firmware_param_store_stm32'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$source = Join-Path $PSScriptRoot 'eo_osd_remote\Core\Src'
$tests = Join-Path $PSScriptRoot 'tests\param_store_stm32'
# Tool setup is scoped to a child process, with no global PATH modification.
$batch = Join-Path $buildRoot 'build_test.cmd'
@"
@echo off
call "$VcVars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c11 /W4 /WX /DPARAM_STORE_STM32_TEST /I"$tests" /I"$source" "$tests\test_param_store_stm32.c" "$source\param_store_stm32.c" /Fe:test_param_store_stm32.exe
if errorlevel 1 exit /b 1
test_param_store_stm32.exe
"@ | Set-Content -LiteralPath $batch -Encoding ascii
Push-Location $buildRoot
try {
    & $env:ComSpec /d /c $batch *> 'test.log'
    $result = $LASTEXITCODE
    Get-Content 'test.log'
    if ($result -ne 0) { throw 'STM32 parameter adapter host test failed' }
} finally { Pop-Location }
