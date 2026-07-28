# Convenience wrapper: put Vivado's bin on PATH for this process, then run tests.
# Usage: .\run_sim.ps1 tb_mem_controller
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Tests)

$vivado = 'G:\Xilinx\2025.1\Vivado\bin'
if (Test-Path $vivado) {
    if ($env:PATH -notlike "*$vivado*") { $env:PATH = "$vivado;" + $env:PATH }
} else {
    Write-Error "Vivado bin not found at $vivado"
    exit 1
}

& (Join-Path $PSScriptRoot 'run_tests.ps1') @Tests
exit $LASTEXITCODE
