# =============================================================================
# LittleGPU - out-of-context synthesis of a SINGLE configuration.
#
# One config per Vivado invocation, on purpose: an in-memory project that fails
# mid-synthesis leaves the .Xil scratch directory locked, which makes every
# subsequent config in the same process fail for an unrelated reason.
#
# Usage:
#   vivado -mode batch -source Synth/synth_one.tcl -tclargs <name> <cores> <warps> <threads> <line> <dch> <ich>
# =============================================================================

if {[llength $argv] < 7} {
    puts "ERROR: expected at least 7 args: name cores warps threads line dch ich [part]"
    exit 1
}
lassign $argv name cores warps threads line dch ich part_arg

set REPO   [file normalize [file join [file dirname [info script]] ".."]]
set PART   "xc7a35tcpg236-1"
if {$part_arg ne ""} {
    set PART $part_arg
}
set CLK_NS 10.0
set OUTDIR [file join $REPO ".synth"]
file mkdir $OUTDIR

set SRCS [list \
    [file join $REPO Src common.sv] \
    [file join $REPO Src alu.sv] \
    [file join $REPO Src decoder.sv] \
    [file join $REPO Src fetcher.sv] \
    [file join $REPO Src lsu.sv] \
    [file join $REPO Src regs.sv] \
    [file join $REPO Src scalar_regs.sv] \
    [file join $REPO Src memory_scoreboard.sv] \
    [file join $REPO Src coalescer.sv] \
    [file join $REPO Src mem_controller.sv] \
    [file join $REPO Src dispatcher.sv] \
    [file join $REPO Src core.sv] \
    [file join $REPO Src gpu.sv] \
]

puts "\n#### CONFIG $name : cores=$cores warps=$warps threads=$threads line=$line ch=$dch/$ich part=$PART"
flush stdout

create_project -in_memory -part $PART
read_verilog -sv $SRCS

set failed [catch {
    synth_design -top gpu -part $PART -mode out_of_context \
        -directive RuntimeOptimized \
        -generic NUM_CORES=$cores \
        -generic WARPS_PER_CORE=$warps \
        -generic THREADS_PER_WARP=$threads \
        -generic MEM_LINE_BYTES=$line \
        -generic NUM_DATA_CHANNELS=$dch \
        -generic NUM_INSTR_CHANNELS=$ich
} err]

if {$failed} {
    puts "\n#### SYNTH FAILED for $name"
    puts $err
    exit 2
}

create_clock -period $CLK_NS -name clk [get_ports clk]

report_utilization    -file [file join $OUTDIR "util_$name.rpt"]
report_timing_summary -delay_type max -max_paths 10 -file [file join $OUTDIR "timing_$name.rpt"]
report_timing         -delay_type max -max_paths 1 -nworst 1 -file [file join $OUTDIR "critpath_$name.rpt"]

set luts  [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ CLB.lut.* || PRIMITIVE_GROUP == LUT} -quiet]]
set regs  [llength [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ CLB.flop.* || PRIMITIVE_SUBGROUP =~ *flop* || LIB_CELL =~ "FD*"} -quiet]]
set brams [llength [get_cells -hierarchical -filter {PRIMITIVE_GROUP == BLOCKRAM || PRIMITIVE_SUBGROUP =~ *blockram*} -quiet]]
set dsps  [llength [get_cells -hierarchical -filter {PRIMITIVE_GROUP == ARITHMETIC || PRIMITIVE_SUBGROUP =~ *dsp*} -quiet]]

set slack "n/a"
catch { set slack [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] }

set line_out [format "%-10s lanes=%-4d LUT=%-7d FF=%-7d BRAMprim=%-4d DSP=%-4d WNS=%s" \
                 $name [expr {$cores * $warps * $threads}] $luts $regs $brams $dsps $slack]

puts "\n#### RESULT: $line_out"

set fh [open [file join $OUTDIR "sweep_summary.txt"] a]
puts $fh $line_out
close $fh
