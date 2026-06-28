`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Memory Controller Testbench
//
// Parameterized harness (tb_mem_ctrl_harness) runs a directed test suite against
// mem_controller. The harness is width/param-agnostic: data patterns, addresses,
// and write-enables are all derived from the params, so the same tests run at any
// config. Two thin top wrappers instantiate it:
//   - DEBUG config:  4 users, 4 channels, 4-byte line, 32-bit data (hand-checkable)
//   - PROD config:   8 users, 8 channels, 128-byte line, 1024-bit data (production)
//
// The top runs both harnesses sequentially in one simulation, then reports a
// combined pass/fail summary.
//
// Channel decode:  channel = byte_addr[clog2(MEM_LINE_BYTES) +: clog2(NUM_CHANNELS)]
// Per-channel addr = byte_addr >> (clog2(MEM_LINE_BYTES) + clog2(NUM_CHANNELS))
//                  (line-offset and channel-select bits stripped -> dense)
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

// ============================================================================
// Parameterized test harness
// ============================================================================
module tb_mem_ctrl_harness #(
    parameter int    DATA_WIDTH     = 32,
    parameter int    ADDR_WIDTH     = 32,
    parameter int    NUM_USERS      = 4,
    parameter int    NUM_CHANNELS   = 4,
    parameter int    MEM_LINE_BYTES = 4,
    parameter int    MEM_DEPTH      = 256,
    parameter string LABEL          = "DEBUG"
)();

    localparam int WE_WIDTH      = MEM_LINE_BYTES;
    localparam int CH_LSB        = $clog2(MEM_LINE_BYTES);             // channel field LSB
    localparam int CH_BITS       = $clog2(NUM_CHANNELS);
    localparam int CH_ADDR_LSB   = CH_LSB + CH_BITS;                   // bits stripped from addr
    localparam int CH_ADDR_WIDTH = ADDR_WIDTH - CH_ADDR_LSB;
    localparam int LANES         = DATA_WIDTH / 32;                    // 32-bit lanes per word

    logic clk, reset;

    // User-side
    logic [NUM_USERS-1:0]    req_ready;
    logic [NUM_USERS-1:0]    req_valid;
    logic [WE_WIDTH-1:0]     req_we   [NUM_USERS];
    logic [ADDR_WIDTH-1:0]   req_addr [NUM_USERS];
    logic [DATA_WIDTH-1:0]   req_data [NUM_USERS];
    logic [NUM_USERS-1:0]    req_resp_valid;
    logic [DATA_WIDTH-1:0]   req_resp_data [NUM_USERS];

    // Memory-side
    logic [NUM_CHANNELS-1:0]   mem_ready, mem_valid;
    logic [WE_WIDTH-1:0]       mem_we   [NUM_CHANNELS];
    logic [CH_ADDR_WIDTH-1:0]  mem_addr [NUM_CHANNELS];
    logic [DATA_WIDTH-1:0]     mem_data [NUM_CHANNELS];
    logic [NUM_CHANNELS-1:0]   mem_resp_valid;
    logic [DATA_WIDTH-1:0]     mem_resp_data [NUM_CHANNELS];

    logic use_stall_mem;

    mem_controller #(
        .DATA_WIDTH    (DATA_WIDTH),
        .ADDR_WIDTH    (ADDR_WIDTH),
        .NUM_USERS     (NUM_USERS),
        .NUM_CHANNELS  (NUM_CHANNELS),
        .MEM_LINE_BYTES(MEM_LINE_BYTES)
    ) dut (
        .clk(clk), .reset(reset),
        .req_ready(req_ready), .req_valid(req_valid), .req_we(req_we),
        .req_addr(req_addr), .req_data(req_data),
        .req_resp_valid(req_resp_valid), .req_resp_ready('1), .req_resp_data(req_resp_data),
        .mem_ready(mem_ready), .mem_valid(mem_valid), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(), .mem_resp_data(mem_resp_data)
    );

    // Ideal + stalling models per channel, muxed by use_stall_mem
    logic [NUM_CHANNELS-1:0] ideal_ready, ideal_resp_valid, stall_ready, stall_resp_valid;
    logic [DATA_WIDTH-1:0]   ideal_rdata [NUM_CHANNELS], stall_rdata [NUM_CHANNELS];

    always_comb begin
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            mem_ready[ch]      = use_stall_mem ? stall_ready[ch]      : ideal_ready[ch];
            mem_resp_valid[ch] = use_stall_mem ? stall_resp_valid[ch] : ideal_resp_valid[ch];
            mem_resp_data[ch]  = use_stall_mem ? stall_rdata[ch]      : ideal_rdata[ch];
        end
    end

    generate
        for (genvar ch = 0; ch < NUM_CHANNELS; ch++) begin : mem_ch
            memory_model #(
                .ADDR_WIDTH(CH_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_SIZE(MEM_DEPTH)
            ) ideal_mem (
                .clk(clk), .reset(reset),
                .valid(mem_valid[ch] & ~use_stall_mem), .addr(mem_addr[ch]),
                .wdata(mem_data[ch]), .we(mem_we[ch]),
                .ready(ideal_ready[ch]), .resp_valid(ideal_resp_valid[ch]),
                .resp_ready(1'b1), .rdata(ideal_rdata[ch])
            );
            memory_model_stall #(
                .ADDR_WIDTH(CH_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_SIZE(MEM_DEPTH),
                .MAX_LATENCY(5), .SEED(ch + 1)
            ) stall_mem (
                .clk(clk), .reset(reset),
                .valid(mem_valid[ch] & use_stall_mem), .addr(mem_addr[ch]),
                .wdata(mem_data[ch]), .we(mem_we[ch]),
                .ready(stall_ready[ch]), .resp_valid(stall_resp_valid[ch]),
                .resp_ready(1'b1), .rdata(stall_rdata[ch])
            );
        end
    endgenerate

    initial generate_clock(clk, 10);

    // ----- width/param-aware helpers -----------------------------------------

    // Distinct DATA_WIDTH-wide pattern: each 32-bit lane = seed + lane index
    function automatic logic [DATA_WIDTH-1:0] gen_data(input logic [31:0] seed);
        logic [DATA_WIDTH-1:0] v;
        v = '0;
        for (int l = 0; l < LANES; l++) v[l*32 +: 32] = seed + l;
        return v;
    endfunction

    // Byte address mapping to (channel, row) with zero byte offset.
    // Compacts back to exactly 'row' (channel bits drop out under the strip shift).
    function automatic logic [ADDR_WIDTH-1:0] addr_for(input int ch, input int row);
        return (row << CH_ADDR_LSB) | (ch << CH_LSB);
    endfunction

    function automatic logic [WE_WIDTH-1:0] full_we();
        return {WE_WIDTH{1'b1}};
    endfunction

    task automatic compare_wide(input string name,
                                input logic [DATA_WIDTH-1:0] actual,
                                input logic [DATA_WIDTH-1:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("[PASS] %s.%s", LABEL, name);
        end else begin
            fail_count++;
            $display("[FAIL] %s.%s exp=%h act=%h", LABEL, name, expected, actual);
        end
    endtask

    task automatic clear_requests();
        req_valid = '0;
        for (int u = 0; u < NUM_USERS; u++) begin
            req_we[u] = '0; req_addr[u] = '0; req_data[u] = '0;
        end
    endtask

    // Single request, hold valid until response (tolerates stalling memory)
    task automatic do_request(input int user,
                              input logic [ADDR_WIDTH-1:0] addr,
                              input logic [DATA_WIDTH-1:0] wdata,
                              input logic [WE_WIDTH-1:0] we,
                              output logic [DATA_WIDTH-1:0] resp_out);
        int timeout;
        timeout = 0;
        req_valid[user] = 1'b1;
        req_addr [user] = addr;
        req_data [user] = wdata;
        req_we   [user] = we;
        while (!req_resp_valid[user] && timeout < 80) begin
            @(posedge clk); #1; timeout++;
        end
        if (timeout >= 80)
            $display("[WARN] %s do_request: timeout user %0d", LABEL, user);
        resp_out = req_resp_data[user];
        req_valid[user] = 1'b0;
        @(posedge clk); #1;
    endtask

    // ----- test groups --------------------------------------------------------

    // One user per channel, write then read back
    task automatic test_single_user();
        logic [DATA_WIDTH-1:0] resp;
        int n;
        $display("\n--- %s Single User ---", LABEL);
        n = (NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS;
        for (int u = 0; u < n; u++) begin
            do_request(u, addr_for(u, 0), gen_data(32'h1000_0000 + (u<<8)), full_we(), resp);
            compare_wide($sformatf("Single_U%0d_Write", u), resp, gen_data(32'h1000_0000 + (u<<8)));
            do_request(u, addr_for(u, 0), '0, '0, resp);
            compare_wide($sformatf("Single_U%0d_Read", u), resp, gen_data(32'h1000_0000 + (u<<8)));
        end
    endtask

    // Three users contend on channel 0 at distinct rows, issued simultaneously
    task automatic test_same_channel();
        logic [DATA_WIDTH-1:0] exp [NUM_USERS];
        logic [NUM_USERS-1:0]  done;
        int got, timeout, n;
        $display("\n--- %s Multi-User Same Channel ---", LABEL);
        n = (NUM_USERS < 3) ? NUM_USERS : 3;

        for (int u = 0; u < n; u++) begin
            exp[u] = gen_data(32'h2000_0000 + (u<<8));
            do_request(0, addr_for(0, u), exp[u], full_we(), exp[u]); // preload, exp reused as scratch
            exp[u] = gen_data(32'h2000_0000 + (u<<8));
        end

        req_valid = '0;
        for (int u = 0; u < n; u++) begin
            req_valid[u] = 1'b1;
            req_addr[u]  = addr_for(0, u);  // all channel 0
            req_we[u]    = '0;
            req_data[u]  = '0;
        end

        done = '0; got = 0; timeout = 0;
        while (got < n && timeout < 200) begin
            @(posedge clk); #1;
            for (int u = 0; u < n; u++) begin
                if (req_valid[u] && req_resp_valid[u] && !done[u]) begin
                    compare_wide($sformatf("SameCh_U%0d", u), req_resp_data[u], exp[u]);
                    req_valid[u] = 1'b0; done[u] = 1'b1; got++;
                end
            end
            timeout++;
        end
        if (timeout >= 200) $display("[WARN] %s SameCh timeout got %0d/%0d", LABEL, got, n);
        req_valid = '0;
        repeat(3) @(posedge clk);
    endtask

    // One user per channel, all issued simultaneously (parallel service)
    task automatic test_diff_channel();
        logic [DATA_WIDTH-1:0] exp [NUM_USERS];
        logic [NUM_USERS-1:0]  done;
        int got, timeout, n;
        $display("\n--- %s Multi-User Different Channel ---", LABEL);
        n = (NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS;

        for (int u = 0; u < n; u++) begin
            exp[u] = gen_data(32'h3000_0000 + (u<<8));
            do_request(u, addr_for(u, 0), exp[u], full_we(), exp[u]);
            exp[u] = gen_data(32'h3000_0000 + (u<<8));
        end

        req_valid = '0;
        for (int u = 0; u < n; u++) begin
            req_valid[u] = 1'b1;
            req_addr[u]  = addr_for(u, 0);  // user u -> channel u
            req_we[u]    = '0;
            req_data[u]  = '0;
        end

        done = '0; got = 0; timeout = 0;
        while (got < n && timeout < 200) begin
            @(posedge clk); #1;
            for (int u = 0; u < n; u++) begin
                if (req_valid[u] && req_resp_valid[u] && !done[u]) begin
                    compare_wide($sformatf("DiffCh_U%0d", u), req_resp_data[u], exp[u]);
                    req_valid[u] = 1'b0; done[u] = 1'b1; got++;
                end
            end
            timeout++;
        end
        if (timeout >= 200) $display("[WARN] %s DiffCh timeout got %0d/%0d", LABEL, got, n);
        req_valid = '0;
        repeat(3) @(posedge clk);
    endtask

    // mem_addr compaction + byte-level write enables (low bytes, width-agnostic)
    task automatic test_addr_and_we();
        logic [DATA_WIDTH-1:0] resp, exp;
        int t;
        $display("\n--- %s Address Compaction + Byte WE ---", LABEL);

        // Compaction: addr_for(0, 5) on channel 0 -> per-channel addr should be 5
        req_valid[0] = 1'b1;
        req_addr [0] = addr_for(0, 5);
        req_we   [0] = full_we();
        req_data [0] = gen_data(32'h4000_0000);
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_wide("Align_MemAddr_Compacted", {{(DATA_WIDTH-CH_ADDR_WIDTH){1'b0}}, mem_addr[0]},
                                                {{(DATA_WIDTH-32){1'b0}}, 32'd5});
        t = 0;
        while (!req_resp_valid[0] && t < 40) begin @(posedge clk); #1; t++; end
        req_valid[0] = 1'b0;
        @(posedge clk); #1;

        // Byte WE: write full line, overwrite byte 0, then byte 3 of lane 0
        exp = gen_data(32'h4444_0000);
        do_request(0, addr_for(0, 6), exp, full_we(), resp);

        begin
            logic [DATA_WIDTH-1:0] wd;
            logic [WE_WIDTH-1:0]   we;
            wd = '0; wd[7:0] = 8'hAA;
            we = '0; we[0] = 1'b1;
            do_request(0, addr_for(0, 6), wd, we, resp);
            exp[7:0] = 8'hAA;
            do_request(0, addr_for(0, 6), '0, '0, resp);
            compare_wide("ByteWE_Byte0", resp, exp);

            wd = '0; wd[31:24] = 8'hBB;
            we = '0; we[3] = 1'b1;
            do_request(0, addr_for(0, 6), wd, we, resp);
            exp[31:24] = 8'hBB;
            do_request(0, addr_for(0, 6), '0, '0, resp);
            compare_wide("ByteWE_Byte3", resp, exp);
        end
    endtask

    // Back-to-back from one user across distinct rows on channel 0
    task automatic test_back_to_back();
        logic [DATA_WIDTH-1:0] resp;
        $display("\n--- %s Back-to-Back ---", LABEL);
        for (int r = 0; r < 3; r++)
            do_request(0, addr_for(0, 10+r), gen_data(32'h5000_0000 + (r<<8)), full_we(), resp);
        for (int r = 0; r < 3; r++) begin
            do_request(0, addr_for(0, 10+r), '0, '0, resp);
            compare_wide($sformatf("B2B_Word%0d", r), resp, gen_data(32'h5000_0000 + (r<<8)));
        end
    endtask

    // Reset mid-flight, then verify normal operation resumes
    task automatic test_reset();
        logic [DATA_WIDTH-1:0] resp;
        $display("\n--- %s Reset ---", LABEL);

        req_valid[0] = 1'b1;
        req_addr [0] = addr_for(0, 7);
        req_we   [0] = full_we();
        req_data [0] = gen_data(32'h6000_0000);
        @(posedge clk); #1;
        reset = 0;
        @(posedge clk); #1;
        compare_wide("Reset_MemValid_Clear",    {{(DATA_WIDTH-1){1'b0}}, mem_valid[0]},      '0);
        compare_wide("Reset_ReqRespValid_Clear", {{(DATA_WIDTH-1){1'b0}}, req_resp_valid[0]}, '0);

        reset = 1;
        clear_requests();
        @(posedge clk); #1;

        do_request(0, addr_for(0, 8), gen_data(32'h7000_0000), full_we(), resp);
        compare_wide("PostReset_Write", resp, gen_data(32'h7000_0000));
        do_request(0, addr_for(0, 8), '0, '0, resp);
        compare_wide("PostReset_Read", resp, gen_data(32'h7000_0000));
    endtask

    // Re-run write/read under the stalling memory (random latency + backpressure)
    task automatic test_stall();
        logic [DATA_WIDTH-1:0] resp;
        int n;
        $display("\n--- %s Stalling Memory ---", LABEL);
        use_stall_mem = 1'b1;
        repeat(2) @(posedge clk);

        n = (NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS;
        for (int u = 0; u < n; u++) begin
            do_request(u, addr_for(u, 12), gen_data(32'h8000_0000 + (u<<8)), full_we(), resp);
            do_request(u, addr_for(u, 12), '0, '0, resp);
            compare_wide($sformatf("Stall_U%0d", u), resp, gen_data(32'h8000_0000 + (u<<8)));
        end

        use_stall_mem = 1'b0;
        repeat(2) @(posedge clk);
    endtask

    // Entry point: called by the top, runs the full suite for this config
    task automatic run_all();
        $display("\n========================================");
        $display("Memory Controller: %s config", LABEL);
        $display("  DATA_WIDTH=%0d NUM_USERS=%0d NUM_CHANNELS=%0d MEM_LINE_BYTES=%0d",
                 DATA_WIDTH, NUM_USERS, NUM_CHANNELS, MEM_LINE_BYTES);
        $display("========================================");

        use_stall_mem = 1'b0;
        clear_requests();
        apply_reset(clk, reset, 3);

        test_single_user();
        test_same_channel();
        test_diff_channel();
        test_addr_and_we();
        test_back_to_back();
        test_reset();
        test_stall();
    endtask

endmodule

// ============================================================================
// Top: run DEBUG then PROD config sequentially, combined summary
// ============================================================================
module tb_mem_controller;

    tb_mem_ctrl_harness #(
        .DATA_WIDTH(32), .ADDR_WIDTH(32), .NUM_USERS(4), .NUM_CHANNELS(4),
        .MEM_LINE_BYTES(4), .MEM_DEPTH(256), .LABEL("DEBUG")
    ) dbg ();

    tb_mem_ctrl_harness #(
        .DATA_WIDTH(1024), .ADDR_WIDTH(32), .NUM_USERS(8), .NUM_CHANNELS(8),
        .MEM_LINE_BYTES(128), .MEM_DEPTH(256), .LABEL("PROD")
    ) prd ();

    initial begin
        $display("========================================");
        $display("Memory Controller Testbench Starting");
        $display("========================================");

        dbg.run_all();
        prd.run_all();

        report_summary();

        $display("========================================");
        $display("Memory Controller Testbench Complete");
        $display("========================================");
        $finish;
    end

endmodule
