param([string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'builds\pose_epoch_history'
$xvlog = Join-Path $VivadoBin 'xvlog.bat'
$xelab = Join-Path $VivadoBin 'xelab.bat'
$xsim = Join-Path $VivadoBin 'xsim.bat'
foreach ($exe in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Vivado tool: $exe" }
}
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
function Invoke-VivadoTool {
    param([string]$Exe, [string[]]$ToolArgs, [string]$LogPath)
    & $Exe @ToolArgs *> $LogPath
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $LogPath | Write-Host
        throw "Vivado tool failed ($LASTEXITCODE): $Exe"
    }
}
Push-Location $buildRoot
try {
    Invoke-VivadoTool $xvlog @('-sv',
        (Join-Path $repoRoot 'src\GlPoseEpochHistory.v'),
        (Join-Path $repoRoot 'sim\tb_GlPoseEpochHistory.sv')
    ) (Join-Path $buildRoot 'compile.console.log')
    $cases = @(
        @{ Depth = 1; AgeWidth = 1 },
        @{ Depth = 1; AgeWidth = 4 },
        @{ Depth = 4; AgeWidth = 4 },
        @{ Depth = 16; AgeWidth = 4 }
    )
    foreach ($case in $cases) {
        $snapshot = 'gl_pose_history_' + $case.Depth + '_' + $case.AgeWidth
        Invoke-VivadoTool $xelab @('tb_GlPoseEpochHistory', '-s', $snapshot,
            '-generic_top', ('"HISTORY_DEPTH=' + $case.Depth + '"'),
            '-generic_top', ('"AGE_WIDTH=' + $case.AgeWidth + '"')
        ) (Join-Path $buildRoot ($snapshot + '.elaborate.console.log'))
        $runLog = Join-Path $buildRoot ($snapshot + '.run.console.log')
        Invoke-VivadoTool $xsim @($snapshot, '-runall') $runLog
        $contents = Get-Content -LiteralPath $runLog -Raw
        if ($contents -notmatch 'PASS GlPoseEpochHistory' -or $contents -match '(?im)^\s*(Fatal|Error):') {
            Write-Host $contents
            throw "GlPoseEpochHistory simulation failed: depth $($case.Depth), age width $($case.AgeWidth)"
        }
        ($contents -split "`r?`n" | Where-Object { $_ -match 'PASS GlPoseEpochHistory' }) | Write-Host
    }
} finally {
    Pop-Location
}
