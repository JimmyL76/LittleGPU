# Convenience wrapper: put Vivado's bin on PATH for this process, then run tests.
# Usage:
#   .\run_sim.ps1                       # run all tests, sequentially
#   .\run_sim.ps1 tb_mem_controller     # run specific test
#   .\run_sim.ps1 --parallel (or -p)    # run all tests concurrently
#   .\run_sim.ps1 --list (or -l)        # show available test names
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Tests,
    [Alias('p')]
    [switch]$Parallel,
    [Alias('l')]
    [switch]$List
)

# Normalize POSIX-style flags (--parallel, --list, -p, -l) if passed as remaining args
$cleanTests = @()
foreach ($t in $Tests) {
    switch -Regex ($t) {
        '^(--parallel|-p)$' { $Parallel = $true; break }
        '^(--list|-l)$'     { $List = $true; break }
        default             { $cleanTests += $t }
    }
}
$Tests = $cleanTests

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

$forwardArgs = @{}
if ($Parallel) { $forwardArgs['Parallel'] = $true }
if ($List)     { $forwardArgs['List'] = $true }
if ($Tests)    { $forwardArgs['Tests'] = $Tests }

& (Join-Path $PSScriptRoot 'run_tests.ps1') @forwardArgs
exit $LASTEXITCODE


