param([string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/eo_capture_coverage'
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
Push-Location $taskBuild
try {
    $taskSources = @('src/EoV19DdrDesync.v','src/EoV19SingleCamReader.v',
        'sim/tb_EoV19CaptureCoverage.sv','sim/tb_EoV19SingleFrameSelect.sv',
        'sim/tb_EoV19DdrCamWriterMarker.v') | ForEach-Object { Join-Path $taskRoot $_ }
    $taskSources += Join-Path (Split-Path -Parent $VivadoBin) 'data/verilog/src/glbl.v'
    & (Join-Path $VivadoBin 'xvlog.bat') --sv --include (Join-Path $taskRoot 'src') @taskSources --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    foreach ($taskTop in @('tb_EoV19CaptureCoverage','tb_EoV19SingleFrameSelect','tb_EoV19DdrCamWriterMarker')) {
        & (Join-Path $VivadoBin 'xelab.bat') $taskTop glbl -L xpm --snapshot $taskTop --log ($taskTop+'.xelab.log')
        if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
        & (Join-Path $VivadoBin 'xsim.bat') $taskTop --runall --log ($taskTop+'.xsim.log')
        if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
        $taskLog = Get-Content -LiteralPath ($taskTop+'.xsim.log') -Raw
        if ($taskLog -notmatch 'PASS' -or $taskLog -match '(?im)^\s*(Fatal|Error):|FAIL') { throw "$taskTop failed" }
    }
} finally { Pop-Location }
