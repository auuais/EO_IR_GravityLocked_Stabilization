param(
    [string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin'
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/pose_receiver'
$taskRtl = Join-Path $taskRoot 'src/GlPoseReceiver.v'
$taskTb = Join-Path $taskRoot 'sim/tb_GlPoseReceiver.sv'
$taskXvlog = Join-Path $VivadoBin 'xvlog.bat'
$taskXelab = Join-Path $VivadoBin 'xelab.bat'
$taskXsim = Join-Path $VivadoBin 'xsim.bat'

foreach ($taskFile in @($taskRtl, $taskTb, $taskXvlog, $taskXelab, $taskXsim)) {
    if (-not (Test-Path -LiteralPath $taskFile -PathType Leaf)) {
        throw "Required file is missing: $taskFile"
    }
}

New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
Push-Location -LiteralPath $taskBuild
try {
    & $taskXvlog --sv $taskRtl $taskTb --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }

    & $taskXelab tb_GlPoseReceiver --snapshot gl_pose_receiver --log xelab.log
    if ($LASTEXITCODE -ne 0) { throw "xelab failed with exit code $LASTEXITCODE" }

    & $taskXsim gl_pose_receiver --runall --log xsim.log
    if ($LASTEXITCODE -ne 0) { throw "xsim failed with exit code $LASTEXITCODE" }
    $taskLog = Get-Content -LiteralPath (Join-Path $taskBuild 'xsim.log') -Raw
    if ($taskLog -notmatch 'PASS GlPoseReceiver:' -or $taskLog -match '(?im)^\s*(Fatal|Error):') {
        throw 'Simulation did not report a clean GlPoseReceiver PASS; inspect builds/pose_receiver/xsim.log'
    }
    Write-Host "GlPoseReceiver verified. Logs: $taskBuild"
} finally {
    Pop-Location
}
