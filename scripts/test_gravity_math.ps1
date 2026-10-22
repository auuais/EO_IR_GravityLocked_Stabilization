param(
    [int]$RandomCases = 2000,
    [string]$Ini = ""
)

$ErrorActionPreference = 'Stop'
$taskScript = Join-Path $PSScriptRoot 'test_gravity_math.py'
$taskArguments = @($taskScript, '--random-cases', $RandomCases)
if ($Ini) { $taskArguments += @('--ini', $Ini) }
& python @taskArguments
exit $LASTEXITCODE
