param([string]$VcVars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds\firmware_param_payload'
$taskSource = Join-Path $PSScriptRoot 'eo_osd_remote\Core\Src'
$taskTests = Join-Path $PSScriptRoot 'tests'
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
$taskBatch = Join-Path $taskBuild 'test_param_payload.cmd'
@"
@echo off
call "$VcVars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c11 /O2 /W4 /WX /I"$taskSource" "$taskTests\test_param_payload.c" "$taskSource\param_payload.c" "$taskSource\param_store.c" /Fe:test_param_payload.exe
if errorlevel 1 exit /b 1
test_param_payload.exe
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $taskBatch -Encoding ascii
Push-Location $taskBuild
try {
    & $env:ComSpec /d /c $taskBatch *> 'test.log'
    $taskResult = $LASTEXITCODE
    Get-Content 'test.log'
    if ($taskResult -ne 0) { throw 'Parameter payload host test failed' }
} finally { Pop-Location }
