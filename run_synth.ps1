# Convenience wrapper: put Vivado on PATH and run synthesis.
# Usage:
#   .\run_synth.ps1 <name> <cores> <warps> <threads> <line> <dch> <ich> [part]
# Example:
#   .\run_synth.ps1 C1W1_T4 1 1 4 16 4 4
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$ConfigName = "C1W1_T4",
    [Parameter(Position=1)]
    [int]$Cores = 1,
    [Parameter(Position=2)]
    [int]$Warps = 1,
    [Parameter(Position=3)]
    [int]$Threads = 4,
    [Parameter(Position=4)]
    [int]$LineBytes = 16,
    [Parameter(Position=5)]
    [int]$DataCh = 4,
    [Parameter(Position=6)]
    [int]$InstrCh = 4,
    [Parameter(Position=7)]
    [string]$Part = ""
)

$candidates = @(
    'G:\Xilinx\2025.1\Vivado\bin',
    'C:\Xilinx\2025.1\Vivado\bin'
)

$vivado = $null
foreach ($p in $candidates) {
    if (Test-Path $p) {
        $vivado = $p
        break
    }
}

if ($vivado) {
    if ($env:PATH -notlike "*$vivado*") { $env:PATH = "$vivado;" + $env:PATH }
} else {
    Write-Error "Vivado bin not found at candidate paths: $($candidates -join ', ')"
    exit 1
}

$tclArgs = "$ConfigName $Cores $Warps $Threads $LineBytes $DataCh $InstrCh"
if ($Part) {
    $tclArgs = "$tclArgs $Part"
}

$logFile = Join-Path $PSScriptRoot ".synth\log_$ConfigName.txt"
if (-not (Test-Path (Join-Path $PSScriptRoot ".synth"))) {
    New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot ".synth") -Force | Out-Null
}

Write-Host "Running synthesis: $tclArgs"
Write-Host "Logging to: $logFile"

Remove-Item -Recurse -Force (Join-Path $PSScriptRoot ".Xil") -ErrorAction SilentlyContinue

& vivado -mode batch -notrace -source (Join-Path $PSScriptRoot "Synth\synth_one.tcl") -tclargs $ConfigName $Cores $Warps $Threads $LineBytes $DataCh $InstrCh $Part 2>&1 | Tee-Object -FilePath $logFile

exit $LASTEXITCODE
