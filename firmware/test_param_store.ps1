param(
    [string]$VcVars = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    [string]$ArmToolBin = 'C:\ST\STM32CubeIDE_2.1.0\STM32CubeIDE\plugins\com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.14.3.rel1.win32_1.0.100.202602081740\tools\bin'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'builds\param_store_host'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$source = Join-Path $PSScriptRoot 'eo_osd_remote\Core\Src'
$tests = Join-Path $PSScriptRoot 'tests'
$batch = Join-Path $buildRoot 'build_test.cmd'
@"
@echo off
call "$VcVars" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c11 /W4 /WX /I"$source" "$tests\test_param_store.c" "$source\param_store.c" /Fe:test_param_store.exe
if errorlevel 1 exit /b 1
test_param_store.exe
if errorlevel 1 exit /b 1
test_param_store.exe --profile-json >profile.json
"@ | Set-Content -LiteralPath $batch -Encoding ascii
Push-Location $buildRoot
try {
    & $env:ComSpec /d /c $batch *> 'test.log'
    $taskResult = $LASTEXITCODE
    Get-Content 'test.log'
    if ($taskResult -ne 0) { throw 'Param store host test failed' }
    & (Join-Path $ArmToolBin 'arm-none-eabi-gcc.exe') -std=gnu11 -Wall -Wextra -Werror `
        -mcpu=cortex-m0plus -mthumb -Os -fstack-usage -I $source -c `
        (Join-Path $source 'param_store.c') -o param_store_arm.o *> 'arm_compile.log'
    if ($LASTEXITCODE -ne 0) { Get-Content 'arm_compile.log'; throw 'Param store ARM compile failed' }
    Write-Output 'PASS ARM GNU11 -Wall -Wextra -Werror compile'
} finally { Pop-Location }
