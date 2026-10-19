param(
    [string]$ToolBin = 'C:\ST\STM32CubeIDE_2.1.0\STM32CubeIDE\plugins\com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.14.3.rel1.win32_1.0.100.202602081740\tools\bin',
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $PSScriptRoot 'eo_osd_remote'
$buildRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repoRoot 'builds\firmware'
} elseif ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$gcc = Join-Path $ToolBin 'arm-none-eabi-gcc.exe'
if (-not (Test-Path -LiteralPath $gcc)) { throw "Missing ARM compiler: $gcc" }
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$common = @('-mcpu=cortex-m0plus', '-mfloat-abi=soft', '-mthumb', '--specs=nano.specs', '-g3', '-Os', '-DDEBUG', '-DUSE_HAL_DRIVER', '-DSTM32G0C1xx', '-ffunction-sections', '-fdata-sections', '-Wall')
$includes = @('Core/Inc', 'Core/Src', 'Drivers/STM32G0xx_HAL_Driver/Inc', 'Drivers/STM32G0xx_HAL_Driver/Inc/Legacy', 'Drivers/CMSIS/Device/ST/STM32G0xx/Include', 'Drivers/CMSIS/Include') | ForEach-Object { '-I' + (Join-Path $sourceRoot $_) }
$sources = @((Get-ChildItem (Join-Path $sourceRoot 'Core/Src') -Filter '*.c'), (Get-ChildItem (Join-Path $sourceRoot 'Drivers/STM32G0xx_HAL_Driver/Src') -Filter '*.c')) | ForEach-Object { $_ } | Sort-Object FullName
$objects = @()
$log = Join-Path $buildRoot 'build.log'
& $gcc --version | Set-Content $log
foreach ($source in $sources) {
    $object = Join-Path $buildRoot ($source.BaseName + '.o')
    & $gcc @common @includes '-std=gnu11' '-fstack-usage' '-c' $source.FullName '-o' $object *>> $log
    if ($LASTEXITCODE -ne 0) { Get-Content $log; throw "Compile failed: $($source.Name)" }
    $objects += $object
}
$startup = Join-Path $buildRoot 'startup.o'
& $gcc @common '-x' 'assembler-with-cpp' '-c' (Join-Path $sourceRoot 'Core/Startup/startup_stm32g0c1retx.s') '-o' $startup *>> $log
if ($LASTEXITCODE -ne 0) { Get-Content $log; throw 'Startup compile failed' }
$objects += $startup
$elf = Join-Path $buildRoot 'gravity_mcu.elf'
& $gcc @common @objects ('-T' + (Join-Path $sourceRoot 'STM32G0C1RETX_FLASH.ld')) '--specs=nosys.specs' ('-Wl,-Map=' + (Join-Path $buildRoot 'gravity_mcu.map')) '-Wl,--gc-sections' '-static' '-u' '_printf_float' '-Wl,--start-group' '-lc' '-lm' '-Wl,--end-group' '-o' $elf *>> $log
if ($LASTEXITCODE -ne 0) { Get-Content $log; throw 'Link failed' }
& (Join-Path $ToolBin 'arm-none-eabi-size.exe') $elf | Tee-Object -FilePath (Join-Path $buildRoot 'size.txt')
if ($LASTEXITCODE -ne 0) { throw 'Size failed' }
& (Join-Path $ToolBin 'arm-none-eabi-objcopy.exe') '-O' 'ihex' $elf (Join-Path $buildRoot 'gravity_mcu.hex')
if ($LASTEXITCODE -ne 0) { throw 'Objcopy failed' }
Write-Host "PASS ARM firmware build: $elf (no programming performed)"
