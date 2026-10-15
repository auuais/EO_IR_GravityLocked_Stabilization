param(
    [ValidateSet('Tables', 'Legacy', 'Gravity', 'All')][string]$Suite = 'All',
    [string]$VivadoBin = 'C:/AMDDesignTools/2025.2/Vivado/bin',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$taskRoot = (Split-Path -Parent $PSScriptRoot).Replace('\', '/')
$taskSuites = if ($Suite -eq 'All') { @('Tables', 'Legacy', 'Gravity') } else { @($Suite) }
foreach ($taskSuite in $taskSuites) {
    $taskBuild = Join-Path $taskRoot ('builds/rp_renderer_' + $taskSuite.ToLower())
    $taskOutput = (Join-Path $taskBuild 'sim_out').Replace('\', '/')
    New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
    $taskTop = if ($taskSuite -eq 'Tables') { 'tb_RpTables' } else { 'tb_RpRenderer' }
    $taskSources = @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'src') -Filter 'Rp*.v' | ForEach-Object FullName)
    $taskSources += @((Join-Path $taskRoot 'src/EoV19RunRom.v'), (Join-Path $taskRoot 'src/IrV19RunRom.v'))
    $taskSources += Join-Path $taskRoot ('sim/' + $taskTop + '.v')
    Push-Location -LiteralPath $taskBuild
    try {
        & (Join-Path $VivadoBin 'xvlog.bat') --sv --include (Join-Path $taskRoot 'src') @taskSources --log xvlog.log
        if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
        $taskGenerics = @('--generic_top', ('"ROOT=' + $taskRoot + '"'))
        if ($taskSuite -ne 'Tables') {
            $taskMode = if ($taskSuite -eq 'Gravity') { 1 } else { 0 }
            $taskGenerics += @('--generic_top', ('"OUTDIR=' + $taskOutput + '"'), '--generic_top', ('"GRAVITY_POSE_INPUTS=' + $taskMode + '"'))
        }
        & (Join-Path $VivadoBin 'xelab.bat') $taskTop @taskGenerics --snapshot rp_test --log xelab.log
        if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
        & (Join-Path $VivadoBin 'xsim.bat') rp_test --runall --log xsim.log
        if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
        $taskLog = Get-Content -LiteralPath 'xsim.log' -Raw
        $taskCompletion = if ($taskSuite -eq 'Tables') { 'PASS tb_RpTables' } else { 'DONE tb_RpRenderer' }
        if ($taskLog -notmatch $taskCompletion -or $taskLog -match '(?im)FAIL|^\s*(Fatal|Error):') {
            throw "Simulation did not finish cleanly: $taskBuild/xsim.log"
        }
        if ($taskSuite -ne 'Tables') {
            & $Python (Join-Path $taskRoot 'scripts/compare_rp_renderer.py') $taskOutput
            if ($LASTEXITCODE -ne 0) { throw 'Renderer pixel comparison failed' }
        }
        Write-Host "PASS $taskSuite. Logs: $taskBuild"
    } finally { Pop-Location }
}
