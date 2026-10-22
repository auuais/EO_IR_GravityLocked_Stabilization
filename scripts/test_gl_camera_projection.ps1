param(
    [string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin'
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/camera_projection'
$taskRtl = Join-Path $taskRoot 'src/GlCameraProjection.v'
$taskTb = Join-Path $taskRoot 'sim/tb_GlCameraProjection.sv'
$taskXvlog = Join-Path $VivadoBin 'xvlog.bat'
$taskXelab = Join-Path $VivadoBin 'xelab.bat'
$taskXsim = Join-Path $VivadoBin 'xsim.bat'
$taskAssets = @(
    (Join-Path $taskRoot 'reference/gravity_math/angle_centi_q15.mem'),
    (Join-Path $taskRoot 'reference/gravity_math/atan_ratio_centi.mem'),
    (Join-Path $taskRoot 'sim/gravity_math/engine_vectors.txt')
)
foreach ($taskFile in (@($taskRtl, $taskTb, $taskXvlog, $taskXelab, $taskXsim) + $taskAssets)) {
    if (-not (Test-Path -LiteralPath $taskFile -PathType Leaf)) {
        throw "Required file is missing: $taskFile"
    }
}

New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
Push-Location -LiteralPath $taskBuild
try {
    & $taskXvlog --sv $taskRtl $taskTb --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }
    & $taskXelab tb_GlCameraProjection --snapshot gl_camera_projection --log xelab.log
    if ($LASTEXITCODE -ne 0) { throw "xelab failed with exit code $LASTEXITCODE" }
    & $taskXsim gl_camera_projection --runall --log xsim.log
    if ($LASTEXITCODE -ne 0) { throw "xsim failed with exit code $LASTEXITCODE" }
    $taskLog = Get-Content -LiteralPath (Join-Path $taskBuild 'xsim.log') -Raw
    if ($taskLog -notmatch 'PASS GlCameraProjection:' -or $taskLog -match '(?im)^\s*(Fatal|Error):') {
        throw 'Simulation did not report a clean GlCameraProjection PASS; inspect builds/camera_projection/xsim.log'
    }
    Write-Host "GlCameraProjection verified. Logs: $taskBuild"
} finally {
    Pop-Location
}
