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
// The coalescer's line-wide memory side connects to a line-wide memory_model.
// The TB applies addr >> $clog2(MEM_LINE_BYTES) to collapse any byte offset
// within a line to one line address. There are no channels here (single memory),
// so only the line-offset bits are stripped, unlike mem_controller which also
// strips channel-select bits.
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_coalescer_harness #(
    parameter int    THREADS_PER_WARP = 8,
    parameter int    MEM_LINE_BYTES   = 32,
    parameter string LABEL            = "DEBUG"
)();

    // -----------------------------------------------------------------------
    // Derived widths
    // -----------------------------------------------------------------------
    localparam int LINE_BITS  = MEM_LINE_BYTES * 8;
    localparam int WORD_BYTES = DATA_WIDTH / 8;
    localparam int LINE_SHIFT = $clog2(MEM_LINE_BYTES);

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

    // -----------------------------------------------------------------------
    // DUT - upstream (memory side, line-wide)
    // -----------------------------------------------------------------------
    logic                  mem_valid;
    data_mem_addr_t        mem_addr;
    logic [LINE_BITS-1:0]  mem_data;
    logic [MEM_LINE_BYTES-1:0] mem_we;
    logic                  mem_resp_valid;
    logic                  mem_resp_ready;
    logic [LINE_BITS-1:0]  mem_resp_data;

    // -----------------------------------------------------------------------
    // Instantiate DUT
    // -----------------------------------------------------------------------
    coalescer #(
        .THREADS_PER_WARP(THREADS_PER_WARP),
        .MEM_LINE_BYTES  (MEM_LINE_BYTES)
    ) dut (
        .clk(clk), .reset(reset),
        .lsu_valid     (lsu_valid),
        .lsu_addr      (lsu_addr),
        .lsu_data      (lsu_data),
        .lsu_we        (lsu_we),
        .lsu_resp_valid(lsu_resp_valid),
        .lsu_resp_ready(lsu_resp_ready),
        .lsu_resp_data (lsu_resp_data),
        .mem_valid     (mem_valid),
        .mem_addr      (mem_addr),
        .mem_data      (mem_data),
        .mem_we        (mem_we),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_data (mem_resp_data)
    );

    // -----------------------------------------------------------------------
    // Line-wide memory model. addr is line-shifted to mirror mem_controller.
    // -----------------------------------------------------------------------
    data_mem_addr_t mem_line_addr;
    assign mem_line_addr = mem_addr >> LINE_SHIFT;

    memory_model #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(LINE_BITS),
        .MEM_SIZE  (256)
    ) line_mem (
        .clk       (clk),
        .reset     (reset),
        .valid     (mem_valid),
        .addr      (mem_line_addr),
        .wdata     (mem_data),
        .we        (mem_we),
        .ready     (),              // Always ready
        .resp_valid(mem_resp_valid),
        .resp_ready(mem_resp_ready),
        .rdata     (mem_resp_data)
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
    //   captured   - output: each active thread's response word
    // Inputs (lsu_addr/data/we) must be set by the caller before calling.
    // Holds lsu_valid until all active threads have completed.
    // -----------------------------------------------------------------------
    task automatic run_round(
        input  logic [THREADS_PER_WARP-1:0] vmask,
        input  logic [THREADS_PER_WARP-1:0] ready_mask,
        output data_t captured [THREADS_PER_WARP]
    );
        logic [THREADS_PER_WARP-1:0] done;
        int timeout;
        done = '0;
        timeout = 0;

        lsu_valid      = vmask;
        lsu_resp_ready = ready_mask;

        while ((done & vmask) != vmask && timeout < 300) begin
            @(posedge clk); #1;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (vmask[t] && lsu_resp_valid[t] && !done[t]) begin
                    captured[t] = lsu_resp_data[t];
                    done[t] = 1'b1;
                end
            end
        end
        if (timeout >= 300)
            $display("[WARN] run_round: timeout, done=%b vmask=%b", done, vmask);

        lsu_valid      = '0;
        lsu_resp_ready = '0;
        @(posedge clk); #1;
    endtask

    // -----------------------------------------------------------------------
    // Entry point: called by the top, runs the full suite for this config
    // -----------------------------------------------------------------------
    task automatic run_all();
        $display("\n--- %s config: THREADS_PER_WARP=%0d MEM_LINE_BYTES=%0d ---",
                 LABEL, THREADS_PER_WARP, MEM_LINE_BYTES);

        clear_threads();
        apply_reset(clk, reset, 3);

        test_coalesced_write_read();
        test_two_lines();
        test_partial_warp();
        test_backpressure();
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
            cap[t]      = 32'hDEAD_DEAD;  // sentinel to catch stray writes
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

        stall_thread = (THREADS_PER_WARP > 3) ? 3 : 0;

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
            while (~(&done) && timeout < 50) begin
                @(posedge clk); #1;
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    if (lsu_resp_valid[t] && !done[t]) begin
                        cap[t] = lsu_resp_data[t];
                        done[t] = 1'b1;
                    end
                end
                timeout++;
            end
        end
        lsu_valid      = '0;
        lsu_resp_ready = '0;
        @(posedge clk); #1;

        for (int t = 0; t < THREADS_PER_WARP; t++)
            compare_data($sformatf("Backpressure_T%0d", t), cap[t], 32'hE000_0000 + t);
    endtask

endmodule

// ============================================================================
// Top: run DEBUG then PROD config sequentially, combined summary
// ============================================================================
module tb_coalescer;

    tb_coalescer_harness #(
        .THREADS_PER_WARP(8),  .MEM_LINE_BYTES(32),  .LABEL("DEBUG")
    ) dbg ();

    tb_coalescer_harness #(
        .THREADS_PER_WARP(32), .MEM_LINE_BYTES(128), .LABEL("PROD")
    ) prd ();

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
