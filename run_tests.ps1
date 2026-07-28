<#
.SYNOPSIS
    Batch-run LittleGPU SystemVerilog testbenches in Vivado XSim (no GUI).

.DESCRIPTION
    Compiles the RTL + testbench with xvlog, elaborates with xelab, and runs
    with xsim -R. Each test builds in its own isolated directory so multiple
    tests can run in parallel without clobbering a shared xsim.dir.

    Each test compiles only the source files it actually needs (its DUT plus the
    common packages), mirroring the per-testbench filesets used in the Vivado
    GUI. This keeps an unrelated broken module from blocking tests that don't
    use it. A test's top module name is identical to its testbench filename.

    Setup (once per shell session), so xvlog/xelab/xsim are on PATH:
        $env:PATH = "G:\Xilinx\2025.1\Vivado\bin;$env:PATH"

.PARAMETER Tests
    One or more test names to run. Omit (or pass 'all') to run everything.

.PARAMETER Parallel
    Run the requested tests concurrently as background jobs.

.PARAMETER List
    Print the discovered test names and exit.

.EXAMPLE
    .\run_tests.ps1                       # run all tests, sequentially
    .\run_tests.ps1 tb_alu tb_lsu         # run two specific tests
    .\run_tests.ps1 -Parallel             # run all tests concurrently
    .\run_tests.ps1 -List                 # show available test names
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Tests,
    [switch]$Parallel,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$srcDir    = Join-Path $root 'Src'
$tbDir     = Join-Path $root 'Testbenches'
$buildRoot = Join-Path $root '.sim'

# --- Compile order: packages first -----------------------------------------
# common_pkg (Src\common.sv) and tb_common_pkg (Testbenches\tb_common.sv) must
# precede any file that imports them.
$commonPkg = Join-Path $srcDir 'common.sv'
$tbCommon  = Join-Path $tbDir 'tb_common.sv'

# --- Per-test DUT source map ------------------------------------------------
# test name -> the Src file(s) that test's DUT needs (relative to Src\).
# The unit DUTs are self-contained (only core.sv instantiates submodules), so
# each entry is just the module under test. common.sv + tb_common.sv are added
# automatically. Tests not listed here fall back to compiling all of Src\.
$dutMap = @{
    'tb_alu'                          = @('alu.sv')
    'tb_coalescer'                    = @('coalescer.sv')
    'tb_decoder'                      = @('decoder.sv')
    'tb_fetcher'                      = @('fetcher.sv')
    'tb_lsu'                          = @('lsu.sv')
    'tb_regs'                         = @('regs.sv')
    'tb_scalar_regs'                  = @('scalar_regs.sv')
    'tb_mem_controller'               = @('mem_controller.sv')
}

# --- Discover testbenches (top module name == file base name) ---------------
$tbFiles = Get-ChildItem $tbDir -Recurse -Filter 'tb_*.sv' |
           Where-Object { $_.Name -ne 'tb_common.sv' }
$testMap = @{}
foreach ($f in $tbFiles) { $testMap[$f.BaseName] = $f.FullName }

if ($List) {
    $testMap.Keys | Sort-Object
    return
}

# --- Resolve requested set --------------------------------------------------
if (-not $Tests -or $Tests -contains 'all') {
    $selected = $testMap.Keys | Sort-Object
} else {
    $selected = @()
    foreach ($t in $Tests) {
        if ($testMap.ContainsKey($t)) { $selected += $t }
        else { Write-Warning "Unknown test '$t' (use -List to see names)" }
    }
}
if (-not $selected) { Write-Error 'No valid tests selected.'; return }

# Build the ordered source list for one test: common pkg, DUT file(s), tb pkg, tb.
function Get-SourceList {
    param($name)
    if ($dutMap.ContainsKey($name)) {
        $duts = $dutMap[$name] | ForEach-Object { Join-Path $srcDir $_ }
    } else {
        Write-Warning "No DUT map for '$name'; compiling all of Src\ as fallback."
        $duts = Get-ChildItem $srcDir -Filter *.sv |
                Where-Object { $_.FullName -ne $commonPkg } |
                Select-Object -ExpandProperty FullName
    }
    return @($commonPkg) + $duts + @($tbCommon, $testMap[$name])
}

# --- The work performed for a single test -----------------------------------
$runOne = {
    param($name, $files, $buildRoot)

    $work = Join-Path $buildRoot $name
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $log = Join-Path $work 'run.log'

    Push-Location $work
    try {
        & xvlog -sv @files                  *>  $log
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Test=$name; Status='COMPILE_FAIL'; Log=$log } }

        & xelab $name -s "${name}_snap"     *>> $log
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Test=$name; Status='ELAB_FAIL'; Log=$log } }

        & xsim "${name}_snap" -R            *>> $log

        $text = Get-Content $log -Raw
        $status =
            if     ($text -match 'ALL TESTS PASSED')   { 'PASS' }
            elseif ($text -match '(\d+) TESTS FAILED') { "FAIL ($($Matches[1]))" }
            else                                       { 'NO_SUMMARY' }
        return [pscustomobject]@{ Test=$name; Status=$status; Log=$log }
    }
    finally { Pop-Location }
}

# --- Dispatch ---------------------------------------------------------------
Write-Host "Running $($selected.Count) test(s): $($selected -join ', ')" -ForegroundColor Cyan
$results = @()

if ($Parallel) {
    $jobs = foreach ($name in $selected) {
        Start-Job -ScriptBlock $runOne -ArgumentList $name, (Get-SourceList $name), $buildRoot
    }
    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job
} else {
    foreach ($name in $selected) {
        Write-Host "  -> $name" -ForegroundColor DarkGray
        $results += & $runOne $name (Get-SourceList $name) $buildRoot
    }
}

# --- Report -----------------------------------------------------------------
Write-Host "`n==================== RESULTS ====================" -ForegroundColor Cyan
$results | Sort-Object Test | ForEach-Object {
    $color = if ($_.Status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ('{0,-40} {1}' -f $_.Test, $_.Status) -ForegroundColor $color
}
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Logs under: $buildRoot\<test>\run.log"

if ($results | Where-Object { $_.Status -ne 'PASS' }) { exit 1 } else { exit 0 }
