`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Coalescer Testbench
//
// Verifies the per-warp memory coalescer:
//   - Coalesced read: N threads in one line -> 1 transaction, each thread
//     receives its own word sliced from the line-wide response
//   - Coalesced write: threads writing distinct words in one line are merged
//     into a single line-wide write
//   - Multi-line: threads spread across lines produce one transaction per line
//   - Partial warp: only some threads active (lsu_valid subset)
//   - Response backpressure: a not-ready thread stalls its group until ready
//
// DUT: coalescer
//   Parameters: THREADS_PER_WARP=8, MEM_LINE_BYTES=32 (8 words per line)
//
// The coalescer's line-wide memory side connects to mc_test_env (mem_controller + memory 
// model per channel). Supplies request/response tags and per-user response buffer that the 
// multi-outstanding path depends on. Byte addresses go straight to the controller, which 
// strips the line-offset and channel-select bits itself, so TB does no address shifting.
//
// Most tests drive a single round at round tag 0 - single-round behavior must be identical
// to the pre-multi-round coalescer. test_concurrent_rounds is the one test that actually
// exercises two rounds (tags 0 and 1) live at the same time.
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_coalescer_harness #(
    parameter int    THREADS_PER_WARP     = 8,
    parameter int    MEM_LINE_BYTES       = 32,
    parameter int    COAL_OUTSTANDING     = 2,
    parameter int    MAX_CONCURRENT_ROUNDS = 2,
    parameter string LABEL                 = "DEBUG"
)();

    // -----------------------------------------------------------------------
    // Derived widths
    // -----------------------------------------------------------------------
    localparam int LINE_BITS  = MEM_LINE_BYTES * 8;
    localparam int WORD_BYTES = DATA_WIDTH / 8;
    localparam int TAG_W      = REQ_TAG_WIDTH;

    // Two channels so two distinct lines can be in flight at once. 
    // Two users bc arbiter and user index need NUM_USERS >= 2 to be well sized;
    // user 1 is tied off and only user 0 carries the coalescer.
    localparam int NUM_CHANNELS = 2;
    localparam int NUM_USERS    = 2;

    // cycle budget for one round
    localparam int ROUND_TIMEOUT = 100 * THREADS_PER_WARP;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk;
    logic reset;

    // -----------------------------------------------------------------------
    // DUT - downstream (LSU side, word-wide, per thread)
    // -----------------------------------------------------------------------
    logic [THREADS_PER_WARP-1:0]  lsu_valid;
    data_mem_addr_t               lsu_addr [THREADS_PER_WARP];
    data_t                        lsu_data [THREADS_PER_WARP];
    logic [WORD_BYTES-1:0]        lsu_we   [THREADS_PER_WARP];
    logic [THREADS_PER_WARP-1:0]  lsu_resp_valid;
    logic [THREADS_PER_WARP-1:0]  lsu_resp_ready;
    data_t                        lsu_resp_data [THREADS_PER_WARP];
    logic [TAG_W-1:0]             issue_round_tag;
    logic [TAG_W-1:0]             resp_round_tag;
    logic                         round_start;

    // -----------------------------------------------------------------------
    // DUT - upstream (memory side, line-wide, one controller user port)
    // -----------------------------------------------------------------------
    logic                      mem_valid;
    logic                      mem_ready;
    data_mem_addr_t            mem_addr;
    logic [LINE_BITS-1:0]      mem_data;
    logic [MEM_LINE_BYTES-1:0] mem_we;
    logic [TAG_W-1:0]          mem_tag;
    logic                      mem_resp_valid;
    logic                      mem_resp_ready;
    logic [LINE_BITS-1:0]      mem_resp_data;
    logic [TAG_W-1:0]          mem_resp_tag;

    // -----------------------------------------------------------------------
    // Instantiate DUT
    // -----------------------------------------------------------------------
    coalescer #(
        .THREADS_PER_WARP(THREADS_PER_WARP),
        .MEM_LINE_BYTES  (MEM_LINE_BYTES),
        .COAL_OUTSTANDING(COAL_OUTSTANDING),
        .MAX_CONCURRENT_ROUNDS(MAX_CONCURRENT_ROUNDS),
        .REQ_TAG_WIDTH   (TAG_W)
    ) dut (
        .clk(clk), .reset(reset),
        .lsu_valid     (lsu_valid),
        .lsu_addr      (lsu_addr),
        .lsu_data      (lsu_data),
        .lsu_we        (lsu_we),
        .lsu_resp_valid(lsu_resp_valid),
        .lsu_resp_ready(lsu_resp_ready),
        .lsu_resp_data (lsu_resp_data),
        .issue_round_tag(issue_round_tag),
        .resp_round_tag (resp_round_tag),
        .round_start   (round_start),
        .mem_valid     (mem_valid),
        .mem_ready     (mem_ready),
        .mem_addr      (mem_addr),
        .mem_data      (mem_data),
        .mem_we        (mem_we),
        .mem_tag       (mem_tag),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_data (mem_resp_data),
        .mem_resp_tag  (mem_resp_tag)
    );

    // -----------------------------------------------------------------------
    // Memory side: real mem_controller plus one memory model per channel.
    // Controller ports are per-user unpacked arrays, so the DUT's single user
    // port is fanned into slot 0 and slot 1 is held idle.
    // -----------------------------------------------------------------------
    logic [NUM_USERS-1:0]      mc_req_ready, mc_req_valid;
    logic [MEM_LINE_BYTES-1:0] mc_req_we   [NUM_USERS];
    data_mem_addr_t            mc_req_addr [NUM_USERS];
    logic [LINE_BITS-1:0]      mc_req_data [NUM_USERS];
    logic [TAG_W-1:0]          mc_req_tag  [NUM_USERS];
    logic [NUM_USERS-1:0]      mc_resp_valid, mc_resp_ready;
    logic [LINE_BITS-1:0]      mc_resp_data [NUM_USERS];
    logic [TAG_W-1:0]          mc_resp_tag  [NUM_USERS];

    always_comb begin
        // idle defaults for every user slot, then the DUT drives slot 0
        for (int u = 0; u < NUM_USERS; u++) begin
            mc_req_valid[u]  = 1'b0;
            mc_req_we[u]     = '0;
            mc_req_addr[u]   = '0;
            mc_req_data[u]   = '0;
            mc_req_tag[u]    = '0;
            mc_resp_ready[u] = 1'b0;
        end
        mc_req_valid[0]  = mem_valid;
        mc_req_we[0]     = mem_we;
        mc_req_addr[0]   = mem_addr;
        mc_req_data[0]   = mem_data;
        mc_req_tag[0]    = mem_tag;
        mc_resp_ready[0] = mem_resp_ready;
    end

    assign mem_ready      = mc_req_ready[0];
    assign mem_resp_valid = mc_resp_valid[0];
    assign mem_resp_data  = mc_resp_data[0];
    assign mem_resp_tag   = mc_resp_tag[0];

    // MEM_DRIVEN hooks are unused here, the ideal per-channel models are used
    logic [NUM_CHANNELS-1:0] drv_mem_ready, drv_mem_resp_valid;
    logic [LINE_BITS-1:0]    drv_mem_resp_data [NUM_CHANNELS];
    always_comb begin
        drv_mem_ready      = '0;
        drv_mem_resp_valid = '0;
        for (int ch = 0; ch < NUM_CHANNELS; ch++) drv_mem_resp_data[ch] = '0;
    end

    mc_test_env #(
        .DATA_WIDTH    (LINE_BITS),
        .ADDR_WIDTH    (DATA_MEM_ADDR_WIDTH),
        .NUM_USERS     (NUM_USERS),
        .NUM_CHANNELS  (NUM_CHANNELS),
        .MEM_LINE_BYTES(MEM_LINE_BYTES),
        .MEM_DEPTH     (256),
        .RESP_BUF_DEPTH(COAL_OUTSTANDING),
        .REQ_TAG_WIDTH (TAG_W)
    ) env (
        .clk(clk), .reset(reset),
        .req_ready     (mc_req_ready),
        .req_valid     (mc_req_valid),
        .req_we        (mc_req_we),
        .req_addr      (mc_req_addr),
        .req_data      (mc_req_data),
        .req_tag       (mc_req_tag),
        .req_resp_valid(mc_resp_valid),
        .req_resp_ready(mc_resp_ready),
        .req_resp_data (mc_resp_data),
        .req_resp_tag  (mc_resp_tag),
        .mem_mode          (tb_common_pkg::MEM_IDEAL),
        .drv_mem_ready     (drv_mem_ready),
        .drv_mem_resp_valid(drv_mem_resp_valid),
        .drv_mem_resp_data (drv_mem_resp_data)
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial begin
        generate_clock(clk, 10);
    end

    // -----------------------------------------------------------------------
    // Helper: clear all thread request inputs
    // -----------------------------------------------------------------------
    task automatic clear_threads();
        lsu_valid      = '0;
        lsu_resp_ready = '0;
        issue_round_tag = '0; // single-round tests all use round tag 0
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = '0;
            lsu_data[t] = '0;
            lsu_we[t]   = '0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper: drive one coalescer round and capture per-thread responses.
    //   vmask      - which threads are active this round
    //   ready_mask - which threads assert lsu_resp_ready (use vmask normally)
    //   captured   - inout: each active thread's response word
    // Inputs (lsu_addr/data/we) must be set by the caller before calling.
    // Holds lsu_valid until all active threads have completed.
    //
    // captured is inout, not output. inout copies the caller's values in
    // first, which lets a caller preload sentinels and detect stray writes.
    // -----------------------------------------------------------------------
    task automatic run_round(
        input  logic [THREADS_PER_WARP-1:0] vmask,
        input  logic [THREADS_PER_WARP-1:0] ready_mask,
        inout  data_t captured [THREADS_PER_WARP]
    );
        logic [THREADS_PER_WARP-1:0] done;
        int timeout;
        done = '0;
        timeout = 0;

        lsu_valid      = vmask;
        lsu_resp_ready = ready_mask;

        while ((done & vmask) != vmask && timeout < ROUND_TIMEOUT) begin
            @(posedge clk); #1;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (vmask[t] && lsu_resp_valid[t] && !done[t]) begin
                    captured[t] = lsu_resp_data[t];
                    done[t] = 1'b1;
                end
            end
            timeout++;
        end
        if (timeout >= ROUND_TIMEOUT)
            $display("[FAIL] run_round: timeout after %0d cycles, done=%b vmask=%b mem_valid=%b mem_ready=%b mem_resp_valid=%b",
                     timeout, done, vmask, mem_valid, mem_ready, mem_resp_valid);

        // drop valid right away, an lsu that has its response stops requesting,
        // but hold resp_ready across one more edge so the transfer that was in
        // progress when the loop exited actually completes. Yanking ready in the
        // same cycle valid is high aborts the handshake and strands the round.
        lsu_valid = '0;
        @(posedge clk); #1;
        lsu_resp_ready = '0;
        @(posedge clk); #1;
    endtask

    // -----------------------------------------------------------------------
    // Entry point: called by the top, runs the full suite for this config
    // -----------------------------------------------------------------------
    task automatic run_all();
        $display("\n--- %s config: THREADS_PER_WARP=%0d MEM_LINE_BYTES=%0d COAL_OUTSTANDING=%0d ---",
                 LABEL, THREADS_PER_WARP, MEM_LINE_BYTES, COAL_OUTSTANDING);

        clear_threads();
        apply_reset(clk, reset, 3);

        test_coalesced_write_read();
        test_two_lines();
        test_partial_warp();
        test_backpressure();
        test_write_merge_conflict();
        test_round_stability();
        if (MAX_CONCURRENT_ROUNDS > 1) test_concurrent_rounds();
    endtask

    // ========================================================================
    // Coalesced write then read, single line.
    //   8 threads write distinct words to slots 0..7 of line 0 (arr[tid]).
    //   Then 8 threads read the same line; each must get its own word back.
    // ========================================================================
    task test_coalesced_write_read();
        data_t cap [THREADS_PER_WARP];
        $display("\n--- Coalesced Write/Read (single line) ---");

        // Write: thread t -> byte addr t*4, value 0xA0000000 + t, full word
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_data[t] = 32'hA000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, cap);

        // Read back: same addresses, no write enable
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_data[t] = '0;
            lsu_we[t]   = 4'b0000;
        end
        run_round('1, '1, cap);

        for (int t = 0; t < THREADS_PER_WARP; t++)
            compare_data($sformatf("CoalRW_T%0d", t), cap[t], 32'hA000_0000 + t);
    endtask

    // ========================================================================
    // Two lines: lower half of threads in line 0, upper half in line 1.
    //   Expect two separate transactions, each thread gets its own word.
    // ========================================================================
    task test_two_lines();
        data_t cap [THREADS_PER_WARP];
        int half;
        $display("\n--- Two-Line Coalescing ---");
        half = THREADS_PER_WARP / 2;

        // Lower half -> line 0 slots, upper half -> line 1 (byte base MEM_LINE_BYTES)
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (t < half) lsu_addr[t] = t * WORD_BYTES;                       // line 0
            else          lsu_addr[t] = MEM_LINE_BYTES + (t-half)*WORD_BYTES; // line 1
            lsu_data[t] = 32'hB000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, cap);

        for (int t = 0; t < THREADS_PER_WARP; t++) lsu_we[t] = 4'b0000;
        run_round('1, '1, cap);

        for (int t = 0; t < THREADS_PER_WARP; t++)
            compare_data($sformatf("TwoLine_T%0d", t), cap[t], 32'hB000_0000 + t);
    endtask

    // ========================================================================
    // Partial warp: only odd-indexed threads active. Inactive threads must not
    // produce responses or corrupt the active ones.
    // ========================================================================
    task test_partial_warp();
        data_t cap [THREADS_PER_WARP];
        logic [THREADS_PER_WARP-1:0] vmask;
        $display("\n--- Partial Warp ---");

        for (int t = 0; t < THREADS_PER_WARP; t++) vmask[t] = t[0]; // odd threads active

        // Preload those words (full warp write so memory is known)
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_data[t] = 32'hC000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, cap);

        // Read back only the masked threads
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_we[t]   = 4'b0000;
            cap[t]      = 32'hDEAD_DEAD;  // to catch stray writes
        end
        run_round(vmask, vmask, cap);

        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (vmask[t])
                compare_data($sformatf("Partial_T%0d", t), cap[t], 32'hC000_0000 + t);
            else
                compare_data($sformatf("Partial_T%0d_Inactive", t), cap[t], 32'hDEAD_DEAD);
        end
    endtask

    // ========================================================================
    // Response backpressure: all threads in one line, but one thread holds
    // lsu_resp_ready low. The group must stall (no thread completes) until
    // that thread becomes ready, then all complete together.
    // ========================================================================
    task test_backpressure();
        data_t cap [THREADS_PER_WARP];
        int    stall_cycles;
        int    stall_thread;
        logic  any_done;
        logic [THREADS_PER_WARP-1:0] ready_mask;
        $display("\n--- Response Backpressure ---");

        stall_thread = 0;

        // Preload line 0
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_data[t] = 32'hE000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, cap);

        // Set up read, but withhold one thread's ready
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_we[t]   = 4'b0000;
        end
        ready_mask = '1;
        ready_mask[stall_thread] = 1'b0;
        lsu_valid      = '1;
        lsu_resp_ready = ready_mask;

        // Run several cycles; no thread should complete while group is stalled
        any_done = 1'b0;
        for (stall_cycles = 0; stall_cycles < 10; stall_cycles++) begin
            @(posedge clk); #1;
            if (|lsu_resp_valid) any_done = 1'b1;
        end
        compare_data("Backpressure_Stalled_NoComplete", {31'b0, any_done}, 32'h0);

        // Now release the stalled thread; whole group should complete
        lsu_resp_ready = '1;
        begin : finish_round
            logic [THREADS_PER_WARP-1:0] done;
            int timeout;
            done = '0; timeout = 0;
            while (~(&done) && timeout < ROUND_TIMEOUT) begin
                @(posedge clk); #1;
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    if (lsu_resp_valid[t] && !done[t]) begin
                        cap[t] = lsu_resp_data[t];
                        done[t] = 1'b1;
                    end
                end
                timeout++;
            end
            check_true(LABEL, "Backpressure_Released_Completed", timeout < ROUND_TIMEOUT);
        end
        lsu_valid      = '0;
        lsu_resp_ready = '0;
        @(posedge clk); #1;

        for (int t = 0; t < THREADS_PER_WARP; t++)
            compare_data($sformatf("Backpressure_T%0d", t), cap[t], 32'hE000_0000 + t);
    endtask

    // ========================================================================
    // Write-merge conflict resolution
    // Two threads target the same word slot with different data. Lowest-index
    // thread must win per byte.
    // ========================================================================
    task test_write_merge_conflict();
        data_t cap [THREADS_PER_WARP];
        $display("\n--- Write-Merge Conflict Resolution ---");

        // thread 0 writes 0xAAAAAAAA to word slot 0, thread 1 also writes
        // 0xBBBBBBBB to the same slot. thread 0 is lower index, must win.
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = '0; // all same word slot 0
            lsu_data[t] = (t == 0) ? 32'hAAAA_AAAA : 32'hBBBB_BBBB;
            lsu_we[t]   = (t < 2) ? 4'b1111 : 4'b0000;
        end
        run_round('1, '1, cap);

        // read back slot 0
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = '0;
            lsu_we[t]   = 4'b0000;
        end
        run_round('1, '1, cap);

        // all threads read same word, should be thread 0's value
        compare_data("WriteMerge_LowestWins", cap[0], 32'hAAAA_AAAA);
        compare_data("WriteMerge_T1_SameResult", cap[1], 32'hAAAA_AAAA);
    endtask

    // ========================================================================
    // Round stability (multi-group)
    // Latched per-thread addr/data/we/word-slot must remain stable through a
    // multi-line round.
    // ========================================================================
    task test_round_stability();
        data_t cap [THREADS_PER_WARP];
        int half;
        $display("\n--- Round Stability (multi-group) ---");
        half = THREADS_PER_WARP / 2;

        // write distinct values, lower half line 0, upper half line 1
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (t < half) lsu_addr[t] = t * WORD_BYTES;
            else          lsu_addr[t] = MEM_LINE_BYTES + (t - half) * WORD_BYTES;
            lsu_data[t] = 32'hF000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, cap);

        // read back same addresses, verify every thread gets its own value
        for (int t = 0; t < THREADS_PER_WARP; t++) lsu_we[t] = 4'b0000;
        run_round('1, '1, cap);

        for (int t = 0; t < THREADS_PER_WARP; t++)
            compare_data($sformatf("RoundStable_T%0d", t), cap[t], 32'hF000_0000 + t);
    endtask

    // ========================================================================
    // Concurrent multi-round issue
    // Two rounds (tags 0 and 1) started on consecutive cycles targeting
    // different lines with full thread masks.
    // ========================================================================
    task test_concurrent_rounds();
        data_t cap0 [THREADS_PER_WARP], cap1 [THREADS_PER_WARP];
        data_t junk [THREADS_PER_WARP];
        logic [THREADS_PER_WARP-1:0] done0, done1;
        int timeout;
        $display("\n--- Concurrent Multi-Round Issue ---");

        // preload both lines with known, distinct data (ordinary single-round
        // writes at tag 0, no concurrency needed for setup)
        issue_round_tag = '0;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;             // line 0
            lsu_data[t] = 32'hD000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, junk);

        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = MEM_LINE_BYTES + t * WORD_BYTES; // line 1
            lsu_data[t] = 32'hE000_0000 + t;
            lsu_we[t]   = 4'b1111;
        end
        run_round('1, '1, junk);

        // start round 0: read line 0, full mask
        lsu_valid = '1;
        issue_round_tag = '0;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = t * WORD_BYTES;
            lsu_we[t]   = 4'b0000;
        end
        @(posedge clk); #1; // round 0 captured this edge

        check_true(LABEL, "Concurrent_Round0_Active", dut.round_active[0] == 1);

        // start round 1 on the very next cycle: read line 1, full mask,
        // while round 0 is still pending (not yet delivered)
        issue_round_tag = 1;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_addr[t] = MEM_LINE_BYTES + t * WORD_BYTES;
        end
        @(posedge clk); #1; // round 1 captured this edge

        check_true(LABEL, "Concurrent_Round1_Active", dut.round_active[1] == 1);
        check_true(LABEL, "Concurrent_Round0_StillActive", dut.round_active[0] == 1);

        lsu_valid      = '0; // shared bus done presenting both rounds
        lsu_resp_ready = '1;

        // collect deliveries for both rounds, demuxed by resp_round_tag
        done0 = '0; done1 = '0; timeout = 0;
        while (((done0 & {THREADS_PER_WARP{1'b1}}) != {THREADS_PER_WARP{1'b1}} ||
                (done1 & {THREADS_PER_WARP{1'b1}}) != {THREADS_PER_WARP{1'b1}}) &&
               timeout < ROUND_TIMEOUT) begin
            @(posedge clk); #1;
            if (|lsu_resp_valid) begin
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    if (lsu_resp_valid[t]) begin
                        if (resp_round_tag == 0 && !done0[t]) begin
                            cap0[t] = lsu_resp_data[t];
                            done0[t] = 1'b1;
                        end else if (resp_round_tag == 1 && !done1[t]) begin
                            cap1[t] = lsu_resp_data[t];
                            done1[t] = 1'b1;
                        end
                    end
                end
            end
            timeout++;
        end
        check_true(LABEL, "Concurrent_BothRoundsCompleted", timeout < ROUND_TIMEOUT);

        lsu_resp_ready  = '0;
        issue_round_tag = '0; // restore default for any test added after this one

        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("Concurrent_Round0_T%0d", t), cap0[t], 32'hD000_0000 + t);
            compare_data($sformatf("Concurrent_Round1_T%0d", t), cap1[t], 32'hE000_0000 + t);
        end
    endtask

endmodule

// ============================================================================
// Top: run DEBUG then PROD config sequentially, combined summary
// ============================================================================
module tb_coalescer;

    tb_coalescer_harness #(
        .THREADS_PER_WARP(8),  .MEM_LINE_BYTES(32),  .COAL_OUTSTANDING(2),
        .MAX_CONCURRENT_ROUNDS(2), .LABEL("DEBUG")
    ) dbg ();

    tb_coalescer_harness #(
        .THREADS_PER_WARP(32), .MEM_LINE_BYTES(128), .COAL_OUTSTANDING(2),
        .MAX_CONCURRENT_ROUNDS(2), .LABEL("PROD")
    ) prd ();

    initial begin
        #1_000_000;
        $display("[FATAL] tb_coalescer watchdog expired at %0t, simulation stalled", $time);
        $fatal(1, "tb_coalescer: watchdog timeout");
    end

    initial begin
        $display("========================================");
        $display("Coalescer Testbench Starting");
        $display("========================================");

        dbg.run_all();
        prd.run_all();

        report_summary();

        $display("========================================");
        $display("Coalescer Testbench Complete");
        $display("========================================");
        $finish;
    end

endmodule
