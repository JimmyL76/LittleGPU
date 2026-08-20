`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Memory Scoreboard Testbench
//
// Verifies allocation, tag routing, load-value formatting, multi-group
// accumulation, backpressure, and error handling for the per-core memory
// scoreboard / mshr pool.
//
// DUT: memory_scoreboard
//   Parameters: SCOREBOARD_DEPTH=2, WARPS_PER_CORE=4, THREADS_PER_WARP=8
//
// Timing convention (matches tb_mem_controller / tb_coalescer): drive inputs,
// settle with #1, then read/check combinational outputs BEFORE advancing the
// clock edge that commits the state change those outputs describe.
//   issue_accept/alloc_tag preview the allocation the next edge will perform
//   wb_valid/wb_*/tag_error preview the lookup/free the next edge will act on
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_memory_scoreboard;

    localparam int DEPTH = 2;
    localparam int WARPS = 4;
    localparam int THREADS = 8;
    localparam int TAG_W = REQ_TAG_WIDTH;

    logic clk, reset;

    // issue interface
    logic issue_valid;
    logic [$clog2(WARPS)-1:0] issue_warp_id;
    logic [4:0] issue_rd_addr;
    logic [THREADS-1:0] issue_thread_mask;
    logic issue_is_scalar;
    logic [1:0] issue_data_size;
    logic issue_usign;
    logic [1:0] issue_byte_off [THREADS];
    logic entry_available;
    logic [TAG_W-1:0] alloc_tag;
    logic issue_accept;

    // response interface - mirrors coalescer's per-thread lsu_resp_valid/data
    logic [THREADS-1:0] resp_thread_valid;
    logic [TAG_W-1:0] resp_tag;
    data_t resp_data [THREADS];

    // writeback interface
    logic wb_valid;
    logic [$clog2(WARPS)-1:0] wb_warp_id;
    logic [4:0] wb_rd_addr;
    logic [THREADS-1:0] wb_thread_mask;
    logic wb_is_scalar;
    data_t wb_data [THREADS];
    logic tag_error;

    memory_scoreboard #(
        .SCOREBOARD_DEPTH(DEPTH),
        .MSHR_COUNT(DEPTH),
        .REQ_TAG_WIDTH(TAG_W),
        .WARPS_PER_CORE(WARPS),
        .THREADS_PER_WARP(THREADS)
    ) dut (.*);

    initial begin
        generate_clock(clk, 10);
    end

    initial begin
        #500_000;
        $display("[FATAL] tb_memory_scoreboard watchdog expired");
        $fatal(1, "watchdog");
    end

    task automatic clear_inputs();
        issue_valid = 0;
        issue_warp_id = 0;
        issue_rd_addr = 0;
        issue_thread_mask = 0;
        issue_is_scalar = 0;
        issue_data_size = 0;
        issue_usign = 0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 0;
        resp_thread_valid = 0;
        resp_tag = 0;
        for (int t = 0; t < THREADS; t++) resp_data[t] = '0;
    endtask

    // drives one issue for exactly one cycle: presents the op (word-sized,
    // vector, zero byte offsets unless overridden by the caller beforehand),
    // samples the accept/tag preview, commits the edge, drops issue_valid
    task automatic do_issue(
        input logic [$clog2(WARPS)-1:0] wid,
        input logic [4:0] rd,
        input logic [THREADS-1:0] mask,
        input logic scalar,
        output logic [TAG_W-1:0] tag,
        output logic accepted
    );
        issue_valid = 1;
        issue_warp_id = wid;
        issue_rd_addr = rd;
        issue_thread_mask = mask;
        issue_is_scalar = scalar;
        #1; // settle comb: issue_accept/alloc_tag now preview this edge
        accepted = issue_accept;
        tag = alloc_tag;
        @(posedge clk); #1; // commit the allocation
        issue_valid = 0;
    endtask

    // drives one full (single-group) response for a tag: all of mask arrives
    // in one batch, so this always frees the entry. captures the full wb_*
    // preview before the freeing edge clears it.
    task automatic do_respond(
        input logic [TAG_W-1:0] tag,
        input logic [THREADS-1:0] mask,
        input data_t pattern,
        output logic saw_wb_valid,
        output logic saw_tag_error,
        output logic [$clog2(WARPS)-1:0] saw_warp_id,
        output logic [4:0] saw_rd_addr,
        output logic [THREADS-1:0] saw_thread_mask,
        output logic saw_is_scalar,
        output data_t saw_data [THREADS]
    );
        resp_thread_valid = mask;
        resp_tag = tag;
        for (int t = 0; t < THREADS; t++) resp_data[t] = pattern + t;
        #1;
        saw_wb_valid = wb_valid;
        saw_tag_error = tag_error;
        saw_warp_id = wb_warp_id;
        saw_rd_addr = wb_rd_addr;
        saw_thread_mask = wb_thread_mask;
        saw_is_scalar = wb_is_scalar;
        for (int t = 0; t < THREADS; t++) saw_data[t] = wb_data[t];
        @(posedge clk); #1; // commit the free (no-op on a miss)
        resp_thread_valid = 0;
    endtask

    task automatic run_all();
        clear_inputs();
        apply_reset(clk, reset, 3);

        test_basic_alloc_and_writeback();
        test_load_formatting();
        test_multi_group_accumulation();
        test_full_backpressure();
        test_out_of_order_response();
        test_tag_error();
        test_no_reuse_before_free();
    endtask

    // ========================================================================
    // Basic allocation and writeback
    // ========================================================================
    task automatic test_basic_alloc_and_writeback();
        logic [TAG_W-1:0] t0;
        logic accepted, saw_wb, saw_err, saw_scalar;
        logic [$clog2(WARPS)-1:0] saw_warp;
        logic [4:0] saw_rd;
        logic [THREADS-1:0] saw_mask;
        data_t saw_data [THREADS];
        $display("\n--- Basic Allocation and Writeback ---");

        issue_data_size = 2'd0; // word, no formatting applied
        issue_usign = 1'b0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        do_issue(1, 5, '1, 0, t0, accepted);
        check_true("SB", "basic_accept", accepted == 1);
        check_true("SB", "basic_alloc_valid", dut.entry_valid[t0] == 1);

        do_respond(t0, '1, 32'hD000_0000, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
        check_true("SB", "wb_valid", saw_wb == 1);
        check_true("SB", "wb_warp_id", saw_warp == 1);
        check_true("SB", "wb_rd_addr", saw_rd == 5);
        check_true("SB", "wb_thread_mask", saw_mask == {THREADS{1'b1}});
        check_true("SB", "wb_is_scalar", saw_scalar == 0);
        check_true("SB", "wb_data_0", saw_data[0] == 32'hD000_0000);
        check_true("SB", "wb_data_last", saw_data[THREADS-1] == data_t'(32'hD000_0000 + THREADS - 1));
        check_true("SB", "freed_available", entry_available == 1);
    endtask

    // ========================================================================
    // Load value formatting
    // ========================================================================
    task automatic test_load_formatting();
        logic [TAG_W-1:0] tag;
        logic accepted, saw_wb, saw_err, saw_scalar;
        logic [$clog2(WARPS)-1:0] saw_warp;
        logic [4:0] saw_rd;
        logic [THREADS-1:0] saw_mask;
        data_t saw_data [THREADS];
        $display("\n--- Load Value Formatting ---");

        // thread 0: halfword at offset 0, signed -> sign-extend upper half
        // thread 1: halfword at offset 2, unsigned -> zero-extend upper half
        // thread 2: byte at offset 3, signed
        // thread 3: byte at offset 1, unsigned
        issue_data_size = 2'd1; // overridden per-thread below via separate issues
        issue_usign = 1'b0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        // halfword, signed, offset 0: raw word 0xFFFF_0000 -> low half 0x0000 -> +0
        issue_data_size = 2'd1; issue_usign = 1'b0; issue_byte_off[0] = 2'd0;
        do_issue(0, 1, 8'h01, 0, tag, accepted);
        resp_thread_valid = 8'h01; resp_tag = tag; resp_data[0] = 32'hFFFF_8000;
        #1;
        check_true("SB", "Halfword_SignExtend_Offset0", wb_data[0] == 32'hFFFF_8000);
        @(posedge clk); #1; resp_thread_valid = 0;

        // halfword, unsigned, offset 2: raw word 0x8000_1234 -> upper half 0x8000 -> zero-extend
        issue_data_size = 2'd1; issue_usign = 1'b1; issue_byte_off[0] = 2'd2;
        do_issue(0, 1, 8'h01, 0, tag, accepted);
        resp_thread_valid = 8'h01; resp_tag = tag; resp_data[0] = 32'h8000_1234;
        #1;
        check_true("SB", "Halfword_ZeroExtend_Offset2", wb_data[0] == 32'h0000_8000);
        @(posedge clk); #1; resp_thread_valid = 0;

        // byte, signed, offset 3: raw word 0xF0_00_00_00 -> byte3 0xF0 -> sign-extend
        issue_data_size = 2'd2; issue_usign = 1'b0; issue_byte_off[0] = 2'd3;
        do_issue(0, 1, 8'h01, 0, tag, accepted);
        resp_thread_valid = 8'h01; resp_tag = tag; resp_data[0] = 32'hF000_0000;
        #1;
        check_true("SB", "Byte_SignExtend_Offset3", wb_data[0] == 32'hFFFF_FFF0);
        @(posedge clk); #1; resp_thread_valid = 0;

        // byte, unsigned, offset 1: raw word 0x0000_A000 -> byte1 0xA0 -> zero-extend
        issue_data_size = 2'd2; issue_usign = 1'b1; issue_byte_off[0] = 2'd1;
        do_issue(0, 1, 8'h01, 0, tag, accepted);
        resp_thread_valid = 8'h01; resp_tag = tag; resp_data[0] = 32'h0000_A000;
        #1;
        check_true("SB", "Byte_ZeroExtend_Offset1", wb_data[0] == 32'h0000_00A0);
        @(posedge clk); #1; resp_thread_valid = 0;
    endtask

    // ========================================================================
    // Multi-group accumulation
    // ========================================================================
    task automatic test_multi_group_accumulation();
        logic [TAG_W-1:0] tag;
        logic accepted, saw_wb, saw_err, saw_scalar;
        logic [$clog2(WARPS)-1:0] saw_warp;
        logic [4:0] saw_rd;
        logic [THREADS-1:0] saw_mask;
        data_t saw_data [THREADS];
        $display("\n--- Multi-Group Accumulation ---");

        issue_data_size = 2'd0; issue_usign = 1'b0; // word, no formatting
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        // full 8-thread mask, delivered as two groups: low 4, then high 4
        do_issue(2, 9, 8'hFF, 0, tag, accepted);
        check_true("SB", "multi_group_accept", accepted == 1);

        // first group: threads 0-3 arrive, entry must NOT free yet
        resp_thread_valid = 8'h0F;
        resp_tag = tag;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hC000_0000 + t;
        #1;
        check_true("SB", "multi_group_first_no_wb", wb_valid == 0);
        @(posedge clk); #1;
        check_true("SB", "multi_group_still_allocated", dut.entry_valid[tag] == 1);
        resp_thread_valid = 0;

        // second group: threads 4-7 arrive, this is the last group
        resp_thread_valid = 8'hF0;
        resp_tag = tag;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hC000_0000 + t;
        #1;
        check_true("SB", "multi_group_second_wb", wb_valid == 1);
        // low 4 threads' data must come from the buffered first group, not
        // from this cycle's resp_data (which also happens to hold the same
        // pattern here, so we cross-check against distinct data below)
        check_true("SB", "multi_group_data0", wb_data[0] == 32'hC000_0000);
        check_true("SB", "multi_group_data7", wb_data[7] == data_t'(32'hC000_0000 + 7));
        @(posedge clk); #1;
        resp_thread_valid = 0;
        check_true("SB", "multi_group_freed", entry_available == 1);

        // repeat with distinct data per group to prove buffering, not just
        // coincidental pattern reuse
        do_issue(2, 9, 8'hFF, 0, tag, accepted);
        resp_thread_valid = 8'h0F;
        resp_tag = tag;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hAAAA_0000 + t; // first group pattern
        #1;
        @(posedge clk); #1;
        resp_thread_valid = 8'hF0;
        resp_tag = tag;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hBBBB_0000 + t; // second group pattern
        #1;
        check_true("SB", "multi_group_distinct_wb", wb_valid == 1);
        check_true("SB", "multi_group_distinct_buffered_low", wb_data[0] == 32'hAAAA_0000);
        check_true("SB", "multi_group_distinct_fresh_high", wb_data[4] == 32'hBBBB_0004);
        @(posedge clk); #1;
        resp_thread_valid = 0;
    endtask

    // ========================================================================
    // Bounded resource use and full backpressure
    // ========================================================================
    task automatic test_full_backpressure();
        logic [TAG_W-1:0] tags [DEPTH];
        logic accepted, saw_wb, saw_err, saw_scalar;
        logic [$clog2(WARPS)-1:0] saw_warp;
        logic [4:0] saw_rd;
        logic [THREADS-1:0] saw_mask;
        data_t saw_data [THREADS];
        $display("\n--- Full Backpressure ---");

        issue_data_size = 2'd0; issue_usign = 1'b0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        for (int i = 0; i < DEPTH; i++) begin
            do_issue(i[$clog2(WARPS)-1:0], i[4:0], '1, 0, tags[i], accepted);
            check_true("SB", $sformatf("fill_%0d_accept", i), accepted == 1);
        end

        check_true("SB", "full_no_available", entry_available == 0);
        issue_valid = 1;
        issue_warp_id = 2;
        issue_rd_addr = 10;
        issue_thread_mask = '1;
        #1;
        check_true("SB", "full_no_accept", issue_accept == 0);
        issue_valid = 0;
        @(posedge clk); #1;

        do_respond(tags[0], '1, 32'h0, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
        check_true("SB", "freed_one_available", entry_available == 1);

        do_issue(3, 15, 8'hAA, 0, tags[0], accepted);
        check_true("SB", "realloc_accept", accepted == 1);

        do_respond(tags[1], '1, 32'h0, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
        do_respond(tags[0], 8'hAA, 32'h0, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
    endtask

    // ========================================================================
    // Out-of-order response routing
    // ========================================================================
    task automatic test_out_of_order_response();
        logic [TAG_W-1:0] tag_a, tag_b;
        logic accepted;
        $display("\n--- Out-of-Order Response Routing ---");

        issue_data_size = 2'd0; issue_usign = 1'b0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        do_issue(0, 7, '1, 0, tag_a, accepted);
        do_issue(2, 12, 8'h01, 1, tag_b, accepted);

        // respond B first
        resp_thread_valid = 8'h01;
        resp_tag = tag_b;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hBBBB_0000 + t;
        #1;
        check_true("SB", "ooo_B_wb_valid", wb_valid == 1);
        check_true("SB", "ooo_B_warp", wb_warp_id == 2);
        check_true("SB", "ooo_B_rd", wb_rd_addr == 12);
        check_true("SB", "ooo_B_scalar", wb_is_scalar == 1);
        @(posedge clk); #1; // frees B

        // respond A second
        resp_thread_valid = '1;
        resp_tag = tag_a;
        for (int t = 0; t < THREADS; t++) resp_data[t] = 32'hAAAA_0000 + t;
        #1;
        check_true("SB", "ooo_A_wb_valid", wb_valid == 1);
        check_true("SB", "ooo_A_warp", wb_warp_id == 0);
        check_true("SB", "ooo_A_rd", wb_rd_addr == 7);
        check_true("SB", "ooo_A_scalar", wb_is_scalar == 0);
        check_true("SB", "ooo_A_data0", wb_data[0] == 32'hAAAA_0000);
        @(posedge clk); #1; // frees A

        resp_thread_valid = 0;
    endtask

    // ========================================================================
    // Tag error path
    // ========================================================================
    task automatic test_tag_error();
        $display("\n--- Tag Error Path ---");

        resp_thread_valid = 8'h01; // no valid entry has this tag right now
        resp_tag = '1;
        for (int t = 0; t < THREADS; t++) resp_data[t] = '0;
        #1;
        check_true("SB", "tag_error_asserted", tag_error == 1);
        check_true("SB", "tag_error_no_wb", wb_valid == 0);
        @(posedge clk); #1;
        resp_thread_valid = 0;
        @(posedge clk); #1;

        check_true("SB", "post_error_available", entry_available == 1);
    endtask

    // ========================================================================
    // No reuse before free
    // ========================================================================
    task automatic test_no_reuse_before_free();
        logic [TAG_W-1:0] t0, t1;
        logic accepted, saw_wb, saw_err, saw_scalar;
        logic [$clog2(WARPS)-1:0] saw_warp;
        logic [4:0] saw_rd;
        logic [THREADS-1:0] saw_mask;
        data_t saw_data [THREADS];
        $display("\n--- No Reuse Before Free ---");

        issue_data_size = 2'd0; issue_usign = 1'b0;
        for (int t = 0; t < THREADS; t++) issue_byte_off[t] = 2'd0;

        do_issue(0, 1, '1, 0, t0, accepted);
        do_issue(1, 2, '1, 0, t1, accepted);
        check_true("SB", "distinct_tags", t0 != t1);

        do_respond(t0, '1, 32'h0, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
        do_respond(t1, '1, 32'h0, saw_wb, saw_err, saw_warp, saw_rd, saw_mask, saw_scalar, saw_data);
    endtask

    initial begin
        $display("========================================");
        $display("Memory Scoreboard Testbench Starting");
        $display("========================================");

        run_all();
        report_summary();

        $display("========================================");
        $display("Memory Scoreboard Testbench Complete");
        $display("========================================");
        $finish;
    end

endmodule
