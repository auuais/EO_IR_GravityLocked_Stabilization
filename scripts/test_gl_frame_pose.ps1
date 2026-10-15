param(
    [string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin',
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $taskRoot 'builds/frame_pose'
$taskProjection = Join-Path $taskRoot 'src/GlCameraProjection.v'
$taskRtl = Join-Path $taskRoot 'src/GlFramePose.v'
$taskTb = Join-Path $taskRoot 'sim/tb_GlFramePose.sv'
$taskGenerator = Join-Path $taskRoot 'sim/gravity_math/generate_frame_pose_vectors.py'
$taskManifest = Join-Path $taskRoot 'sim/gravity_math/frame_pose_manifest.json'
$taskXvlog = Join-Path $VivadoBin 'xvlog.bat'
$taskXelab = Join-Path $VivadoBin 'xelab.bat'
$taskXsim = Join-Path $VivadoBin 'xsim.bat'
$taskAssets = @(
    (Join-Path $taskRoot 'reference/gravity_math/angle_centi_q15.mem'),
    (Join-Path $taskRoot 'reference/gravity_math/atan_ratio_centi.mem'),
    (Join-Path $taskRoot 'sim/gravity_math/frame_pose_vectors.txt')
)
foreach ($taskFile in (@($taskProjection, $taskRtl, $taskTb, $taskGenerator, $taskManifest, $taskXvlog, $taskXelab, $taskXsim) + $taskAssets)) {
    if (-not (Test-Path -LiteralPath $taskFile -PathType Leaf)) { throw "Required file is missing: $taskFile" }
}

# Recompile the original C++ oracle and verify deterministic fixtures before RTL.
& $Python $taskGenerator
if ($LASTEXITCODE -ne 0) { throw "Compiled-C frame-pose fixture verification failed: $LASTEXITCODE" }
$taskCount = (Get-Content -LiteralPath $taskManifest -Raw | ConvertFrom-Json).count
if ($taskCount -le 0) { throw 'Frame-pose manifest count is missing or invalid' }
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
Push-Location -LiteralPath $taskBuild
try {
    & $taskXvlog --sv $taskProjection $taskRtl $taskTb --log xvlog.log
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }
    & $taskXelab tb_GlFramePose --generic_top ('"EXPECTED_VECTOR_COUNT=' + $taskCount + '"') --snapshot gl_frame_pose --log xelab.log
    if ($LASTEXITCODE -ne 0) { throw "xelab failed with exit code $LASTEXITCODE" }
    & $taskXsim gl_frame_pose --runall --log xsim.log
    if ($LASTEXITCODE -ne 0) { throw "xsim failed with exit code $LASTEXITCODE" }
    $taskLog = Get-Content -LiteralPath (Join-Path $taskBuild 'xsim.log') -Raw
    if ($taskLog -notmatch 'PASS GlFramePose:' -or $taskLog -match '(?im)^\s*(Fatal|Error):') {
        throw 'Simulation did not report a clean GlFramePose PASS; inspect builds/frame_pose/xsim.log'
    }
    Write-Host "GlFramePose verified. Logs: $taskBuild"
} finally {
    Pop-Location
}
