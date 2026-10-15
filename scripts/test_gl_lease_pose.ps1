param([string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/lease_pose'
New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
Push-Location $taskBuild
try {
    $taskSources = @('GlCameraProjection.v','GlFramePose.v','GlPoseEpochHistory.v','GlLeasePose.v') |
        ForEach-Object { Join-Path $taskRoot ('src/' + $_) }
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @taskSources `
        (Join-Path $taskRoot 'sim/tb_GlLeasePose.sv') `
        (Join-Path $taskRoot 'sim/tb_GlTriggerEpoch.sv') --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    foreach ($taskTop in @('GlLeasePose','GlTriggerEpoch')) {
        & (Join-Path $VivadoBin 'xelab.bat') ('tb_' + $taskTop) -s $taskTop --log ($taskTop + '_xelab.log')
        if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
        & (Join-Path $VivadoBin 'xsim.bat') $taskTop -runall --log ($taskTop + '_xsim.log')
        if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
        $taskLog = Get-Content ($taskTop + '_xsim.log') -Raw
        if ($taskLog -notmatch ('PASS ' + $taskTop + ':') -or $taskLog -match '(?im)^\s*(Fatal|Error):') {
            throw ('Simulation failed: ' + $taskTop)
        }
    }
} finally { Pop-Location }
