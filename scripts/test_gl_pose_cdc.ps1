param(
    [string]$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'builds\pose_cdc'
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
    Invoke-VivadoTool $xvlog @(
        '-sv', (Join-Path $repoRoot 'src\GlPoseCdc.v'),
        (Join-Path $repoRoot 'sim\tb_GlPoseCdc.sv')
    ) (Join-Path $buildRoot 'compile.console.log')

    $cases = @(
        @{ Name = 'source_faster'; Src = 5; Dst = 7; Phase = 3 },
        @{ Name = 'destination_faster'; Src = 11; Dst = 3; Phase = 1 },
        @{ Name = 'offset_phase'; Src = 7; Dst = 13; Phase = 8 }
    )
    foreach ($case in $cases) {
        $snapshot = 'gl_pose_' + $case.Name
        Invoke-VivadoTool $xelab @(
            'tb_GlPoseCdc', '-s', $snapshot,
            '-generic_top', ('"SRC_HALF_NS=' + $case.Src + '"'),
            '-generic_top', ('"DST_HALF_NS=' + $case.Dst + '"'),
            '-generic_top', ('"DST_PHASE_NS=' + $case.Phase + '"')
        ) (Join-Path $buildRoot ($case.Name + '.elaborate.console.log'))
        $runLog = Join-Path $buildRoot ($case.Name + '.run.console.log')
        Invoke-VivadoTool $xsim @($snapshot, '-runall') $runLog
        $contents = Get-Content -LiteralPath $runLog -Raw
        if ($contents -notmatch 'PASS GlPoseCdc' -or $contents -match '(?im)^\s*(Fatal|Error):') {
            Write-Host $contents
            throw "GlPoseCdc simulation failed: $($case.Name)"
        }
        ($contents -split "`r?`n" | Where-Object { $_ -match 'PASS GlPoseCdc' }) | Write-Host
    }
    Write-Host 'All GlPoseCdc functional simulations passed. Physical CDC constraints/review remain required.'
} finally {
    Pop-Location
}
