param([string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/lease_pose'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
Push-Location $taskBuild
try {
    $taskSources = @('GlCameraProjection.v','GlFramePose.v','GlPoseEpochHistory.v','GlLeasePose.v') |
        ForEach-Object { Join-Path $taskRoot ('src/' + $_) }
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @taskSources (Join-Path $taskRoot 'sim/tb_GlLeasePose.sv') --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_GlLeasePose -s gl_lease_pose --log xelab.log
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') gl_lease_pose -runall --log xsim.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    $taskLog = Get-Content xsim.log -Raw
    if ($taskLog -notmatch 'PASS GlLeasePose:' -or $taskLog -match '(?im)^\s*(Fatal|Error):') { throw 'Lease pose simulation failed' }
} finally { Pop-Location }
