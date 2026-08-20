`timescale 1ns / 1ps

import common_pkg::*;

// per-core memory scoreboard / mshr pool
// lives inside core.sv between warp scheduler and lsus/coalescer
//
// issue side: scheduler picks a warp for memory, presents the op here
//   if a free entry exists (issue_accept), records warp id, destination
//   register, thread mask, scalar flag, load-format info (data_size, usign,
//   per-thread byte offset), returns alloc_tag, which rides through the
//   lsus -> coalescer -> mem_controller. the core parks the warp
//   (STALL_WAIT_MEM) and frees the memory stage for the next warp immediately
//
//   the per-thread byte offset must be captured here rather than read live
//   from the warp's registered operands: those registers (rs1_mem etc in
//   core.sv) get overwritten by the next warp granted the memory stage while
//   this warp is still parked waiting on its response
//
// response side: mirrors the coalescer's per-thread lsu_resp_valid/lsu_resp_data
// exactly (see coalescer.sv) - the coalescer resolves tags internally and never
// exposes one on that port, so resp_tag here must be supplied by core.sv, which
// remembers which entry's round is currently active in the coalescer. this
// works because only one warp's round can be active in the coalescer at a time
// (single round_active flag) - once the coalescer is made warp-aware this
// single-active-tag assumption needs revisiting
//
// a warp's response can arrive across multiple cycles (multi-line access), so
// each entry tracks a pending_mask or which threads still owe data, buffers
// formatted words as they arrive, and only asserts wb_valid once every bit in
// pending_mask has been satisfied - never partially
//
// on tag miss (stale/corrupt), asserts tag_error and discards, changing nothing
module memory_scoreboard #(
    // concurrent outstanding entries
    parameter int SCOREBOARD_DEPTH = 2,
    // bounded mshr pool size
    parameter int MSHR_COUNT = 2,
    parameter int REQ_TAG_WIDTH = common_pkg::REQ_TAG_WIDTH,
    parameter int WARPS_PER_CORE = 2,
    parameter int THREADS_PER_WARP = 32
    )(
    input logic clk, reset,

    // issue interface - core presents a memory op, scoreboard decides accept
    input logic issue_valid,
    input logic [$clog2(WARPS_PER_CORE)-1:0] issue_warp_id,
    input logic [4:0] issue_rd_addr,
    input logic [THREADS_PER_WARP-1:0] issue_thread_mask,
    input logic issue_is_scalar,
    input logic [1:0] issue_data_size, // 0 word, 1 halfword, 2 byte (matches lsu.sv)
    input logic issue_usign,
    input logic [1:0] issue_byte_off [THREADS_PER_WARP], // addr[1:0] per thread, captured at issue
    output logic entry_available,
    output logic [REQ_TAG_WIDTH-1:0] alloc_tag,
    output logic issue_accept,

    // response interface - mirrors coalescer's lsu_resp_valid/lsu_resp_data
    // (per-thread, raw/unformatted), resp_tag names which entry this batch
    // belongs to (supplied by core, see module header)
    input logic [THREADS_PER_WARP-1:0] resp_thread_valid,
    input logic [REQ_TAG_WIDTH-1:0] resp_tag,
    input data_t resp_data [THREADS_PER_WARP],

    // writeback interface - scoreboard drives register file write, data
    // already formatted per data_size/usign/byte_off, fires once per entry
    output logic wb_valid,
    output logic [$clog2(WARPS_PER_CORE)-1:0] wb_warp_id,
    output logic [4:0] wb_rd_addr,
    output logic [THREADS_PER_WARP-1:0] wb_thread_mask,
    output logic wb_is_scalar,
    output data_t wb_data [THREADS_PER_WARP],

    // error
    output logic tag_error
    );

    localparam int ENTRY_BITS = (SCOREBOARD_DEPTH > 1) ? $clog2(SCOREBOARD_DEPTH) : 1;

    // elab checks
    initial begin
        if (SCOREBOARD_DEPTH < 1)
            $fatal(1, "memory_scoreboard: SCOREBOARD_DEPTH (%0d) must be >= 1", SCOREBOARD_DEPTH);
        if (MSHR_COUNT < 1)
            $fatal(1, "memory_scoreboard: MSHR_COUNT (%0d) must be >= 1", MSHR_COUNT);
        if (SCOREBOARD_DEPTH > (1 << REQ_TAG_WIDTH))
            $fatal(1, "memory_scoreboard: SCOREBOARD_DEPTH (%0d) exceeds tag space", SCOREBOARD_DEPTH);
    end

    // load-value formatting, lifted from lsu.sv's load_result case, now
    // applied at writeback instead of at the (now fire-and-forget) lsu
    function automatic data_t format_load(
        input data_t raw, input logic [1:0] dsize, input logic usign, input logic [1:0] boff
    );
        logic [15:0] hw; logic [7:0] b; logic sign;
        case (dsize)
            0: format_load = raw; // word
            1: begin // halfword
                hw = (boff == 2'd2) ? raw[31:16] : raw[15:0];
                sign = usign ? 1'b0 : hw[15];
                format_load = {{16{sign}}, hw};
            end
            2: begin // byte
                b = raw[boff*8 +: 8];
                sign = usign ? 1'b0 : b[7];
                format_load = {{24{sign}}, b};
            end
            default: format_load = raw;
        endcase
    endfunction

    // entry storage
    logic entry_valid [SCOREBOARD_DEPTH];
    logic [REQ_TAG_WIDTH-1:0] entry_tag [SCOREBOARD_DEPTH];
    logic [$clog2(WARPS_PER_CORE)-1:0] entry_warp_id [SCOREBOARD_DEPTH];
    logic [4:0] entry_rd_addr [SCOREBOARD_DEPTH];
    logic [THREADS_PER_WARP-1:0] entry_thread_mask [SCOREBOARD_DEPTH];
    logic entry_is_scalar [SCOREBOARD_DEPTH];
    logic [1:0] entry_data_size [SCOREBOARD_DEPTH];
    logic entry_usign [SCOREBOARD_DEPTH];
    logic [1:0] entry_byte_off [SCOREBOARD_DEPTH][THREADS_PER_WARP];
    // which threads still owe data, and formatted words as they arrive
    logic [THREADS_PER_WARP-1:0] entry_pending [SCOREBOARD_DEPTH];
    data_t entry_data_buf [SCOREBOARD_DEPTH][THREADS_PER_WARP];

    // lowest free entry
    logic [ENTRY_BITS-1:0] alloc_idx;
    logic has_free;
    always_comb begin
        has_free = 1'b0;
        alloc_idx = '0;
        for (int e = SCOREBOARD_DEPTH - 1; e >= 0; e--) begin
            if (!entry_valid[e]) begin
                has_free = 1'b1;
                alloc_idx = e[ENTRY_BITS-1:0];
            end
        end
    end

    assign entry_available = has_free;
    assign alloc_tag = alloc_idx;
    assign issue_accept = issue_valid && entry_available;

    // response lookup by tag
    logic resp_hit;
    logic [ENTRY_BITS-1:0] resp_idx;
    logic have_resp;
    assign have_resp = |resp_thread_valid;
    always_comb begin
        resp_hit = 1'b0;
        resp_idx = '0;
        for (int e = 0; e < SCOREBOARD_DEPTH; e++) begin
            if (entry_valid[e] && (entry_tag[e] == resp_tag)) begin
                resp_hit = 1'b1;
                resp_idx = e[ENTRY_BITS-1:0];
            end
        end
    end
    assign tag_error = have_resp && !resp_hit;

    // this response batch clears every bit still pending for the matched
    // entry - if so, it is the last group and writeback fires this cycle
    logic last_group;
    assign last_group = resp_hit && ((entry_pending[resp_idx] & ~resp_thread_valid) == '0);
    assign wb_valid = have_resp && last_group;

    always_comb begin
        wb_warp_id = entry_warp_id[resp_idx];
        wb_rd_addr = entry_rd_addr[resp_idx];
        wb_thread_mask = entry_thread_mask[resp_idx];
        wb_is_scalar = entry_is_scalar[resp_idx];
        // threads arriving this cycle format fresh, threads that arrived in an
        // earlier group of the same multi-line response use their buffered value
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            wb_data[t] = resp_thread_valid[t]
                ? format_load(resp_data[t], entry_data_size[resp_idx], entry_usign[resp_idx], entry_byte_off[resp_idx][t])
                : entry_data_buf[resp_idx][t];
        end
    end

    // sequential - allocate on issue, accumulate/free on response
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            for (int e = 0; e < SCOREBOARD_DEPTH; e++) begin
                entry_valid[e] <= 1'b0;
                entry_tag[e] <= '0;
                entry_warp_id[e] <= '0;
                entry_rd_addr[e] <= '0;
                entry_thread_mask[e] <= '0;
                entry_is_scalar[e] <= 1'b0;
                entry_data_size[e] <= '0;
                entry_usign[e] <= 1'b0;
                entry_pending[e] <= '0;
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    entry_byte_off[e][t] <= '0;
                    entry_data_buf[e][t] <= '0;
                end
            end
        end else begin
            // allocate on accepted issue
            if (issue_accept) begin
                entry_valid[alloc_idx] <= 1'b1;
                entry_tag[alloc_idx] <= alloc_idx;
                entry_warp_id[alloc_idx] <= issue_warp_id;
                entry_rd_addr[alloc_idx] <= issue_rd_addr;
                entry_thread_mask[alloc_idx] <= issue_thread_mask;
                entry_is_scalar[alloc_idx] <= issue_is_scalar;
                entry_data_size[alloc_idx] <= issue_data_size;
                entry_usign[alloc_idx] <= issue_usign;
                entry_pending[alloc_idx] <= issue_thread_mask; // every active thread owes a response
                for (int t = 0; t < THREADS_PER_WARP; t++)
                    entry_byte_off[alloc_idx][t] <= issue_byte_off[t];
            end
            // response: free on the last group, else buffer and keep waiting
            if (have_resp && resp_hit) begin
                if (last_group) begin
                    entry_valid[resp_idx] <= 1'b0;
                end else begin
                    entry_pending[resp_idx] <= entry_pending[resp_idx] & ~resp_thread_valid;
                    for (int t = 0; t < THREADS_PER_WARP; t++) begin
                        if (resp_thread_valid[t])
                            entry_data_buf[resp_idx][t] <= format_load(resp_data[t], entry_data_size[resp_idx], entry_usign[resp_idx], entry_byte_off[resp_idx][t]);
                    end
                end
            end
        end
    end

endmodule
