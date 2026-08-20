`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Memory Controller Testbench
//
// One harness module holds the interface, the shared driver tasks, and every
// test. Each test is a task built out of those drivers, so adding a behavior
// means writing one task, not another module with its own signals and helpers.
// The top instantiates the harness twice (a small DEBUG config and a wide PROD
// config) and reports one combined pass/fail summary.
//
// Covered: read/write round trips, channel decode, per-channel address
// compaction, byte write enables, concurrent users on one and many channels,
// stalling memory, response buffering and ordering, full-buffer backpressure,
// tag echo, in-flight tag uniqueness, and reset quiescence.
//
// Channel decode:  channel = byte_addr[clog2(MEM_LINE_BYTES) +: clog2(NUM_CHANNELS)]
// Per-channel addr = byte_addr >> (clog2(MEM_LINE_BYTES) + clog2(NUM_CHANNELS))
//                  (line-offset and channel-select bits stripped -> dense)
//
// Note on write responses: memory_model reads the addressed line in the same
// non-blocking block that applies the write, so a write response carries the
// pre-write contents. Writes are therefore always verified by reading back.
//////////////////////////////////////////////////////////////////////////////////

import tb_common_pkg::*;

module mc_harness #(
    parameter int    DATA_WIDTH     = 32,
    parameter int    ADDR_WIDTH     = 32,
    parameter int    NUM_USERS      = 4,
    parameter int    NUM_CHANNELS   = 4,
    parameter int    MEM_LINE_BYTES = 4,
    parameter int    MEM_DEPTH      = 256,
    parameter int    RESP_BUF_DEPTH = 2,
    parameter int    REQ_TAG_WIDTH  = 8,
    // randomized iterations for the loop-driven tests
    parameter int    ITERS          = 40,
    parameter string LABEL          = "DEBUG"
)();

    localparam int WE_WIDTH    = MEM_LINE_BYTES;
    localparam int CH_LSB      = $clog2(MEM_LINE_BYTES);          // channel field LSB
    localparam int CH_ADDR_LSB = CH_LSB + $clog2(NUM_CHANNELS);   // bits stripped from addr
    localparam int LANES       = DATA_WIDTH / 32;                 // 32-bit lanes per line
    localparam int USER_BITS   = $clog2(NUM_USERS);
    localparam int ID_BITS     = REQ_TAG_WIDTH - USER_BITS;       // per-user id field

    localparam int ACC_TO  = 200;   // cycles to wait for a request to be accepted
    localparam int RESP_TO = 200;   // cycles to wait for a response to appear

    logic clk, reset;

    // user-side interface, the only side the tests drive
    logic [NUM_USERS-1:0]     req_ready;
    logic [NUM_USERS-1:0]     req_valid;
    logic [WE_WIDTH-1:0]      req_we   [NUM_USERS];
    logic [ADDR_WIDTH-1:0]    req_addr [NUM_USERS];
    logic [DATA_WIDTH-1:0]    req_data [NUM_USERS];
    logic [REQ_TAG_WIDTH-1:0] req_tag  [NUM_USERS];
    logic [NUM_USERS-1:0]     req_resp_valid;
    logic [NUM_USERS-1:0]     req_resp_ready;
    logic [DATA_WIDTH-1:0]    req_resp_data [NUM_USERS];
    logic [REQ_TAG_WIDTH-1:0] req_resp_tag  [NUM_USERS];

    // memory behind the channels, this tb drives itself while in MEM_DRIVEN
    // initialized so an instance that has not started its run yet still holds a
    // defined mode and drives no spurious completions
    mem_mode_t               mem_mode = MEM_IDEAL;
    logic [NUM_CHANNELS-1:0] drv_mem_ready = '1;
    logic [NUM_CHANNELS-1:0] drv_mem_resp_valid = '0;
    logic [DATA_WIDTH-1:0]   drv_mem_resp_data [NUM_CHANNELS] = '{default: '0};

    mc_test_env #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .NUM_USERS(NUM_USERS),
        .NUM_CHANNELS(NUM_CHANNELS), .MEM_LINE_BYTES(MEM_LINE_BYTES),
        .MEM_DEPTH(MEM_DEPTH), .RESP_BUF_DEPTH(RESP_BUF_DEPTH),
        .REQ_TAG_WIDTH(REQ_TAG_WIDTH)
    ) env (
        .clk(clk), .reset(reset),
        .req_ready(req_ready), .req_valid(req_valid), .req_we(req_we),
        .req_addr(req_addr), .req_data(req_data), .req_tag(req_tag),
        .req_resp_valid(req_resp_valid), .req_resp_ready(req_resp_ready),
        .req_resp_data(req_resp_data), .req_resp_tag(req_resp_tag),
        .mem_mode(mem_mode), .drv_mem_ready(drv_mem_ready),
        .drv_mem_resp_valid(drv_mem_resp_valid), .drv_mem_resp_data(drv_mem_resp_data)
    );

    initial generate_clock(clk, 10);

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    task automatic check(input string name, input bit cond);
        check_true(LABEL, name, cond);
    endtask

    // distinct line-wide pattern, each 32-bit lane holds seed plus lane index
    function automatic logic [DATA_WIDTH-1:0] gen_data(input logic [31:0] seed);
        logic [DATA_WIDTH-1:0] v;
        v = '0;
        for (int l = 0; l < LANES; l++) v[l*32 +: 32] = seed + l;
        return v;
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] addr_for(input int ch, input int row);
        return mc_addr_for(ch, row, CH_LSB, CH_ADDR_LSB);
    endfunction

    function automatic logic [WE_WIDTH-1:0] full_we();
        return mc_full_we();
    endfunction

    function automatic int rnd_range(input int n);
        return ($random & 32'h7fff_ffff) % n;
    endfunction

    // globally distinct tag from user index and that user's request id
    function automatic logic [REQ_TAG_WIDTH-1:0] make_tag(input int u, input int id);
        return (u << ID_BITS) | (id & ((1 << ID_BITS) - 1));
    endfunction

    task automatic clear_all();
        req_valid      = '0;
        req_resp_ready = '0;
        for (int u = 0; u < NUM_USERS; u++) begin
            req_we[u] = '0; req_addr[u] = '0; req_data[u] = '0; req_tag[u] = '0;
        end
    endtask

    // put the environment in a known state: chosen memory behavior, idle
    // interface, controller reset
    task automatic start_test(input string name, input mem_mode_t mode);
        $display("\n--- %s %s ---", LABEL, name);
        mem_mode           = mode;
        drv_mem_resp_valid = '0;
        for (int c = 0; c < NUM_CHANNELS; c++) drv_mem_resp_data[c] = '0;
        clear_all();
        apply_reset(clk, reset, 3);
    endtask

    // ------------------------------------------------------------------------
    // driver layer - every test is built from these
    // ------------------------------------------------------------------------

    // present a request, without waiting for it to be accepted
    task automatic present(input int u, input int ch, input int row,
                           input logic [REQ_TAG_WIDTH-1:0] tag,
                           input logic [WE_WIDTH-1:0] we,
                           input logic [DATA_WIDTH-1:0] wdata);
        req_valid[u] = 1'b1;
        req_addr [u] = addr_for(ch, row);
        req_tag  [u] = tag;
        req_we   [u] = we;
        req_data [u] = wdata;
    endtask

    // wait for the presented request to be granted, then cross the acceptance
    // edge and drop valid, so exactly one request is issued. req_ready is
    // combinational and the arbiter drops it at the edge, so it is sampled
    // after the #1 settle and before the next edge.
    task automatic wait_accept(input int u, output bit ok);
        int t;
        ok = 1'b1;
        t  = 0;
        #1;
        while (!req_ready[u] && t < ACC_TO) begin
            @(posedge clk); #1; t++;
        end
        if (t >= ACC_TO) begin
            ok = 1'b0;
            $display("[WARN] %s acceptance timeout user %0d", LABEL, u);
        end
        @(posedge clk); #1;
        req_valid[u] = 1'b0;
    endtask

    task automatic wait_resp(input int u, output bit ok);
        int t;
        ok = 1'b1;
        t  = 0;
        while (!req_resp_valid[u] && t < RESP_TO) begin
            @(posedge clk); #1; t++;
        end
        if (t >= RESP_TO) begin
            ok = 1'b0;
            $display("[WARN] %s response timeout user %0d", LABEL, u);
        end
    endtask

    // take the head response for user u and free its slot
    task automatic accept_resp(input int u,
                               output logic [DATA_WIDTH-1:0] data,
                               output logic [REQ_TAG_WIDTH-1:0] tag);
        data = req_resp_data[u];
        tag  = req_resp_tag[u];
        req_resp_ready[u] = 1'b1;
        @(posedge clk); #1;
        req_resp_ready[u] = 1'b0;
    endtask

    // one full single-shot round trip: issue, accept, collect, free the slot
    task automatic request(input  int u, input int ch, input int row,
                           input  logic [REQ_TAG_WIDTH-1:0] tag,
                           input  logic [WE_WIDTH-1:0] we,
                           input  logic [DATA_WIDTH-1:0] wdata,
                           output logic [DATA_WIDTH-1:0] rdata,
                           output logic [REQ_TAG_WIDTH-1:0] rtag,
                           output bit ok);
        bit acc_ok, resp_ok;
        present(u, ch, row, tag, we, wdata);
        wait_accept(u, acc_ok);
        wait_resp(u, resp_ok);
        accept_resp(u, rdata, rtag);
        ok = acc_ok && resp_ok;
    endtask

    // convenience wrappers for the common read and write cases
    task automatic write_line(input int u, input int ch, input int row,
                              input logic [DATA_WIDTH-1:0] wdata);
        logic [DATA_WIDTH-1:0]    d;
        logic [REQ_TAG_WIDTH-1:0] t;
        bit                       ok;
        request(u, ch, row, '0, full_we(), wdata, d, t, ok);
    endtask

    task automatic read_line(input int u, input int ch, input int row,
                             output logic [DATA_WIDTH-1:0] rdata);
        logic [REQ_TAG_WIDTH-1:0] t;
        bit                       ok;
        request(u, ch, row, '0, '0, '0, rdata, t, ok);
    endtask

    // complete one channel with chosen data, only meaningful in MEM_DRIVEN
    //
    // waits until the channel has actually taken the request before responding.
    // a granted request is presented on mem_valid for at least one cycle before
    // the memory accepts it, and responding earlier is illegal on a valid/ready
    // interface, so the controller rightly ignores it
    task automatic complete_ch(input int ch, input logic [DATA_WIDTH-1:0] data);
        int t;
        t = 0;
        while (env.dut.pending[ch] !== 1'b1 && t < 40) begin
            @(posedge clk); #1; t++;
        end
        if (t >= 40)
            $display("[WARN] %s channel %0d never took its request", LABEL, ch);
        drv_mem_resp_valid[ch] = 1'b1;
        drv_mem_resp_data[ch]  = data;
        @(posedge clk); #1;
        drv_mem_resp_valid[ch] = 1'b0;
    endtask

    // ------------------------------------------------------------------------
    // background monitor: a user holding its maximum unaccepted responses must
    // never show req_ready, whatever the memory behind the channel is doing
    // ------------------------------------------------------------------------
    int mon_full_samples;
    int mon_violations;

    always @(posedge clk) begin
        #1;
        if (reset === 1'b1) begin
            for (int u = 0; u < NUM_USERS; u++) begin
                if (env.dut.occupancy[u] == RESP_BUF_DEPTH) begin
                    mon_full_samples++;
                    if (req_ready[u] !== 1'b0) mon_violations++;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // row map - each test owns a row range so tests never disturb each other
    // ------------------------------------------------------------------------
    localparam int ROW_RW    = 0;
    localparam int ROW_B2B   = 4;
    localparam int ROW_DEC   = 9;
    localparam int ROW_WE    = 10;
    localparam int ROW_CONC  = 16;
    localparam int ROW_STALL = 24;
    localparam int ROW_BUF   = 28;
    localparam int ROW_BP    = 32;
    localparam int ROW_RST   = 40;
    localparam int ROW_TAG   = 48;
    localparam int ROW_UNIQ  = 56;

    // ------------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------------

    // one user per channel writes then reads its line back, plus back-to-back
    // requests from a single user across distinct rows of one channel
    task automatic test_read_write();
        logic [DATA_WIDTH-1:0] d, exp;
        int n;
        start_test("Read / Write Round Trip", MEM_IDEAL);

        n = (NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS;
        for (int u = 0; u < n; u++) begin
            exp = gen_data(32'h1000_0000 + (u << 8));
            write_line(u, u, ROW_RW, exp);
            read_line (u, u, ROW_RW, d);
            check($sformatf("ReadWrite_U%0d", u), d === exp);
        end

        for (int r = 0; r < 3; r++)
            write_line(0, 0, ROW_B2B + r, gen_data(32'h5000_0000 + (r << 8)));
        for (int r = 0; r < 3; r++) begin
            read_line(0, 0, ROW_B2B + r, d);
            check($sformatf("BackToBack_Row%0d", r), d === gen_data(32'h5000_0000 + (r << 8)));
        end
    endtask

    // a request must land on the channel its address selects, with the channel
    // and byte-offset bits stripped out of the per-channel address
    task automatic test_channel_decode();
        logic [DATA_WIDTH-1:0]    d;
        logic [REQ_TAG_WIDTH-1:0] tg;
        bit                       ok, others_idle;
        start_test("Channel Decode + Address Compaction", MEM_IDEAL);

        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            present(0, ch, ROW_DEC, '0, '0, '0);
            wait_accept(0, ok);

            check($sformatf("Decode_Ch%0d_Selected",  ch), env.mem_valid[ch] === 1'b1);
            check($sformatf("Decode_Ch%0d_Compacted", ch), env.mem_addr[ch]  === ROW_DEC);

            others_idle = 1'b1;
            for (int c = 0; c < NUM_CHANNELS; c++)
                if (c != ch && env.mem_valid[c] !== 1'b0) others_idle = 1'b0;
            check($sformatf("Decode_Ch%0d_OthersIdle", ch), others_idle);

            wait_resp(0, ok);
            accept_resp(0, d, tg);
        end
    endtask

    // a partial write enable must modify only the enabled bytes of the line
    task automatic test_byte_we();
        logic [DATA_WIDTH-1:0]    d, exp, wd;
        logic [WE_WIDTH-1:0]      we;
        logic [REQ_TAG_WIDTH-1:0] tg;
        bit                       ok;
        start_test("Byte Write Enables", MEM_IDEAL);

        exp = gen_data(32'h4444_0000);
        write_line(0, 0, ROW_WE, exp);

        wd = '0; wd[7:0] = 8'hAA;
        we = '0; we[0]   = 1'b1;
        request(0, 0, ROW_WE, '0, we, wd, d, tg, ok);
        exp[7:0] = 8'hAA;
        read_line(0, 0, ROW_WE, d);
        check("ByteWE_Byte0", d === exp);

        wd = '0; wd[31:24] = 8'hBB;
        we = '0; we[3]     = 1'b1;
        request(0, 0, ROW_WE, '0, we, wd, d, tg, ok);
        exp[31:24] = 8'hBB;
        read_line(0, 0, ROW_WE, d);
        check("ByteWE_Byte3", d === exp);
    endtask

    // every user issues at once, either all onto one channel (arbiter
    // serializes them) or one per channel (served in parallel). Each user must
    // get back its own line and its own tag.
    task automatic test_concurrent(input bit same_channel);
        logic [DATA_WIDTH-1:0]    exp [NUM_USERS], got [NUM_USERS];
        logic [REQ_TAG_WIDTH-1:0] got_tag [NUM_USERS];
        bit                       done [NUM_USERS], acc [NUM_USERS];
        int                       ch_of [NUM_USERS];
        int                       n, ndone, t;
        string                    kind;

        kind = same_channel ? "SameChannel" : "DiffChannel";
        n    = same_channel ? NUM_USERS
                            : ((NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS);
        start_test($sformatf("Concurrent Users %s", kind), MEM_IDEAL);

        for (int u = 0; u < n; u++) begin
            ch_of[u] = same_channel ? 0 : u;
            exp[u]   = gen_data(32'h2000_0000 + (u << 8) + (same_channel ? 0 : 1));
            write_line(u, ch_of[u], ROW_CONC + u, exp[u]);
        end

        for (int u = 0; u < n; u++) begin
            present(u, ch_of[u], ROW_CONC + u, make_tag(u, u), '0, '0);
            acc[u] = 1'b0; done[u] = 1'b0;
        end
        req_resp_ready = '1;

        ndone = 0; t = 0;
        while (ndone < n && t < 400) begin
            #1; // settle, then record what commits at the coming edge
            for (int u = 0; u < n; u++) begin
                if (!acc[u] && req_valid[u] && req_ready[u]) acc[u] = 1'b1;
                if (!done[u] && req_resp_valid[u]) begin
                    got    [u] = req_resp_data[u];
                    got_tag[u] = req_resp_tag[u];
                    done   [u] = 1'b1;
                    ndone++;
                end
            end
            @(posedge clk);
            for (int u = 0; u < n; u++) if (acc[u]) req_valid[u] = 1'b0;
            t++;
        end
        req_resp_ready = '0;

        for (int u = 0; u < n; u++) begin
            check($sformatf("%s_U%0d_Data", kind, u), done[u] && (got[u] === exp[u]));
            check($sformatf("%s_U%0d_Tag",  kind, u), done[u] && (got_tag[u] === make_tag(u, u)));
        end

        clear_all();
    endtask

    // same round trips against a memory with random latency and random request
    // backpressure, so the controller cannot rely on fixed timing
    task automatic test_stall_memory();
        logic [DATA_WIDTH-1:0] d, exp;
        int n;
        start_test("Stalling Memory", MEM_STALL);

        n = (NUM_USERS < NUM_CHANNELS) ? NUM_USERS : NUM_CHANNELS;
        for (int u = 0; u < n; u++) begin
            exp = gen_data(32'h8000_0000 + (u << 8));
            write_line(u, u, ROW_STALL, exp);
            read_line (u, u, ROW_STALL, d);
            check($sformatf("Stall_U%0d", u), d === exp);
        end
    endtask

    // does this delivered data/tag pair match one of the two issued requests
    function automatic bit pair_ok(input logic [DATA_WIDTH-1:0] d,
                                   input logic [REQ_TAG_WIDTH-1:0] t,
                                   input logic [REQ_TAG_WIDTH-1:0] tA,
                                   input logic [DATA_WIDTH-1:0] dA,
                                   input logic [REQ_TAG_WIDTH-1:0] tB,
                                   input logic [DATA_WIDTH-1:0] dB);
        return ((t === tA) && (d === dA)) || ((t === tB) && (d === dB));
    endfunction

    // two requests from one user outstanding on two channels, completed in a
    // random order. The head must appear within a cycle, stay put while the
    // second completion arrives, and both must come back with their own data.
    task automatic test_response_buffering();
        int                       u, cA, cB;
        logic [REQ_TAG_WIDTH-1:0] tA, tB, t0, t1, h0t;
        logic [DATA_WIDTH-1:0]    dA, dB, d0, d1, h0d;
        bit                       ok, b_first;

        start_test("Response Buffering", MEM_DRIVEN);

        for (int it = 0; it < ITERS; it++) begin
            u  = rnd_range(NUM_USERS);
            cA = rnd_range(NUM_CHANNELS);
            cB = (cA + 1 + rnd_range(NUM_CHANNELS - 1)) % NUM_CHANNELS;
            tA = make_tag(u, rnd_range(1 << ID_BITS));
            tB = tA ^ 1;   // distinct tag, still owned by the same user
            dA = gen_data(32'h5A00_0000 + it);
            dB = gen_data(32'hA500_0000 + it);
            b_first = rnd_range(2);

            clear_all();
            apply_reset(clk, reset, 2);

            present(u, cA, ROW_BUF,     tA, '0, '0);
            wait_accept(u, ok);
            present(u, cB, ROW_BUF + 1, tB, '0, '0);
            wait_accept(u, ok);
            check($sformatf("Buf_Iter%0d_TwoOutstanding", it), env.dut.occupancy[u] == 2);

            if (b_first) complete_ch(cB, dB);
            else         complete_ch(cA, dA);
            check($sformatf("Buf_Iter%0d_HeadPresented", it),
                  (req_resp_valid[u] === 1'b1) && (env.dut.resp_count[u] == 1));

            h0d = req_resp_data[u];
            h0t = req_resp_tag[u];
            if (b_first) complete_ch(cA, dA);
            else         complete_ch(cB, dB);
            check($sformatf("Buf_Iter%0d_HeadUndisturbed", it),
                  (req_resp_data[u] === h0d) && (req_resp_tag[u] === h0t));
            check($sformatf("Buf_Iter%0d_BothBuffered", it), env.dut.resp_count[u] == 2);

            accept_resp(u, d0, t0);
            accept_resp(u, d1, t1);
            check($sformatf("Buf_Iter%0d_Drained", it), env.dut.resp_count[u] == 0);
            check($sformatf("Buf_Iter%0d_DataMatchesTag", it),
                  pair_ok(d0, t0, tA, dA, tB, dB) && pair_ok(d1, t1, tA, dA, tB, dB));
            check($sformatf("Buf_Iter%0d_NoDuplicate", it), t0 !== t1);
        end
    endtask

    // a user holding its maximum unaccepted responses must not be granted, and
    // must become grantable again once a slot frees
    task automatic test_backpressure();
        logic [DATA_WIDTH-1:0]    d;
        logic [REQ_TAG_WIDTH-1:0] tg;
        bit                       ok, ready_low, reasserted;
        int                       u, ch;

        start_test("Full Buffer Backpressure", MEM_IDEAL);

        for (int it = 0; it < ITERS; it++) begin
            u  = rnd_range(NUM_USERS);
            ch = rnd_range(NUM_CHANNELS);

            clear_all();
            apply_reset(clk, reset, 2);

            // fill the buffer, never accepting a response
            for (int k = 0; k < RESP_BUF_DEPTH; k++) begin
                present(u, ch, ROW_BP + k, make_tag(u, k), '0, '0);
                wait_accept(u, ok);
            end
            #1;
            check($sformatf("BP_Iter%0d_Full", it), env.dut.occupancy[u] == RESP_BUF_DEPTH);

            // hold one more request against the full buffer, it must not be granted
            present(u, ch, ROW_BP + RESP_BUF_DEPTH, make_tag(u, RESP_BUF_DEPTH), '0, '0);
            ready_low = 1'b1;
            for (int k = 0; k < 4; k++) begin
                #1;
                if (req_ready[u] !== 1'b0) ready_low = 1'b0;
                @(posedge clk);
            end
            check($sformatf("BP_Iter%0d_ReadyStaysLow", it), ready_low);

            // free one slot, the held request must then get through
            accept_resp(u, d, tg);
            reasserted = 1'b0;
            for (int k = 0; k < 64 && !reasserted; k++) begin
                #1;
                if (req_ready[u] === 1'b1) reasserted = 1'b1;
                @(posedge clk);
            end
            check($sformatf("BP_Iter%0d_ReadyReasserts", it), reasserted);

            // drain so the next iteration starts from an empty buffer
            req_valid[u]      = 1'b0;
            req_resp_ready[u] = 1'b1;
            repeat (8) @(posedge clk);
            req_resp_ready[u] = 1'b0;
        end
    endtask

    // an arbitrary tag must come back bit for bit, on reads and on writes
    task automatic test_tag_echo();
        logic [31:0]              r;
        logic [REQ_TAG_WIDTH-1:0] sent, got;
        logic [DATA_WIDTH-1:0]    d, wd;
        logic [WE_WIDTH-1:0]      we;
        bit                       ok;
        int                       u, ch, row;

        start_test("Tag Echo", MEM_IDEAL);

        for (int it = 0; it < ITERS; it++) begin
            u    = rnd_range(NUM_USERS);
            ch   = rnd_range(NUM_CHANNELS);
            row  = ROW_TAG + rnd_range(8);
            r    = $random;
            sent = r[REQ_TAG_WIDTH-1:0];

            if (rnd_range(2)) begin
                we = full_we(); wd = gen_data($random);
            end else begin
                we = '0;        wd = '0;
            end

            request(u, ch, row, sent, we, wd, d, got, ok);
            check($sformatf("TagEcho_Iter%0d_sent0x%0h", it, sent), ok && (got === sent));
        end
    endtask

    // ------------------------------------------------------------------------
    // tag uniqueness scoreboard state, kept at module scope so the checking
    // task can share it with the stimulus loop
    // ------------------------------------------------------------------------
    int                       inflight    [int];       // in-flight uses per tag value
    logic [REQ_TAG_WIDTH-1:0] outstanding [NUM_USERS][$];
    bit                       uniq_ok, route_ok, member_ok;
    int                       accepted_cnt, delivered_cnt;

    // account for one delivered response: it must carry its own user's field and
    // must match a request that user still has outstanding
    task automatic retire(input int u, input logic [REQ_TAG_WIDTH-1:0] t);
        int  ufield;
        bit  hit;
        ufield = t >> ID_BITS;
        if (ufield != u) begin
            route_ok = 1'b0;
            $display("[FAIL] %s.tag_routing tag=0x%0h delivered to user %0d but encodes %0d",
                     LABEL, t, u, ufield);
        end
        hit = 1'b0;
        for (int i = 0; i < outstanding[u].size(); i++) begin
            if (outstanding[u][i] === t) begin
                outstanding[u].delete(i);
                hit = 1'b1;
                break;
            end
        end
        if (!hit) begin
            member_ok = 1'b0;
            $display("[FAIL] %s.tag_membership tag=0x%0h delivered to user %0d, not outstanding",
                     LABEL, t, u);
        end
        if (inflight.exists(t)) begin
            inflight[t]--;
            if (inflight[t] <= 0) inflight.delete(t);
        end
        delivered_cnt++;
    endtask

    // all users issue continuously with tags built as {user, per-user id} and
    // accept responses at random, while a scoreboard checks no two in-flight
    // tags ever collide and nothing is lost or duplicated
    task automatic test_tag_uniqueness();
        bit                       busy    [NUM_USERS];
        int                       next_id [NUM_USERS];
        bit                       acc_s   [NUM_USERS], dlv_s [NUM_USERS];
        logic [REQ_TAG_WIDTH-1:0] dlv_tag [NUM_USERS];
        int                       key, cur, peak, cycles, drain;

        start_test("In-Flight Tag Uniqueness", MEM_IDEAL);

        for (int u = 0; u < NUM_USERS; u++) begin
            busy[u] = 1'b0; next_id[u] = 0;
            outstanding[u].delete();
        end
        inflight.delete();
        uniq_ok = 1'b1; route_ok = 1'b1; member_ok = 1'b1;
        accepted_cnt = 0; delivered_cnt = 0; peak = 0;
        cycles = ITERS * 8;

        for (int i = 0; i < cycles; i++) begin
            for (int u = 0; u < NUM_USERS; u++) begin
                if (!busy[u]) begin
                    present(u, rnd_range(NUM_CHANNELS), ROW_UNIQ + rnd_range(8),
                            make_tag(u, next_id[u]), '0, '0);
                    busy[u] = 1'b1;
                end
                req_resp_ready[u] = (rnd_range(4) != 0);
            end

            // latch transfers before the edge, the arbiter drops req_ready on it
            #1;
            for (int u = 0; u < NUM_USERS; u++) begin
                acc_s  [u] = busy[u] && req_valid[u] && req_ready[u];
                dlv_s  [u] = req_resp_valid[u] && req_resp_ready[u];
                dlv_tag[u] = req_resp_tag[u];
            end

            @(posedge clk); // commit exactly those transfers

            for (int u = 0; u < NUM_USERS; u++) begin
                if (acc_s[u]) begin
                    key = req_tag[u];
                    if (inflight.exists(key)) inflight[key]++;
                    else                      inflight[key] = 1;
                    outstanding[u].push_back(req_tag[u]);
                    next_id[u]++;
                    accepted_cnt++;
                    busy[u]      = 1'b0;
                    req_valid[u] = 1'b0;
                end
            end
            for (int u = 0; u < NUM_USERS; u++) if (dlv_s[u]) retire(u, dlv_tag[u]);

            cur = 0;
            foreach (inflight[k]) begin
                cur += inflight[k];
                if (inflight[k] > 1) begin
                    uniq_ok = 1'b0;
                    $display("[FAIL] %s.tag_uniqueness tag=0x%0h in flight %0d times",
                             LABEL, k, inflight[k]);
                end
            end
            if (cur > peak) peak = cur;
        end

        // drain what is still in flight so nothing is counted as lost
        req_valid      = '0;
        req_resp_ready = '1;
        drain = 0;
        while ((accepted_cnt != delivered_cnt) && drain < 400) begin
            #1;
            for (int u = 0; u < NUM_USERS; u++) begin
                dlv_s  [u] = req_resp_valid[u] && req_resp_ready[u];
                dlv_tag[u] = req_resp_tag[u];
            end
            @(posedge clk);
            for (int u = 0; u < NUM_USERS; u++) if (dlv_s[u]) retire(u, dlv_tag[u]);
            drain++;
        end
        req_resp_ready = '0;

        $display("[INFO] %s tags: accepted=%0d delivered=%0d peak in flight=%0d",
                 LABEL, accepted_cnt, delivered_cnt, peak);
        check("TagUniqueness_NoCollision",   uniq_ok);
        check("TagUniqueness_CorrectUser",   route_ok);
        check("TagUniqueness_WasOutstanding", member_ok);
        check("TagUniqueness_NoneLost",      accepted_cnt == delivered_cnt);
        check("TagUniqueness_EnoughTraffic", accepted_cnt >= 100);
    endtask

    // nothing may drive a valid or a ready while reset is held or straight after
    // release, traffic must still start afterwards, and reset mid-flight must
    // pull the outputs back down
    task automatic test_reset();
        logic [DATA_WIDTH-1:0]    d;
        logic [REQ_TAG_WIDTH-1:0] tg;
        bit                       ok;
        int                       hold;

        start_test("Reset Quiescence", MEM_IDEAL);

        reset = 0;
        clear_all();
        req_resp_ready = '1; // accept anything, so a stuck valid cannot hide
        hold = 3 + rnd_range(5);
        for (int k = 0; k < hold; k++) begin
            @(posedge clk); #1;
            check($sformatf("Reset_Quiet_c%0d", k),
                  (req_resp_valid === '0) && (env.mem_valid === '0) && (req_ready === '0));
        end

        reset = 1;
        for (int k = 0; k < 5; k++) begin
            @(posedge clk); #1;
            check($sformatf("Reset_IdleAfterRelease_c%0d", k),
                  (req_resp_valid === '0) && (env.mem_valid === '0) && (req_ready === '0));
        end

        // a real request proves those zeros were idleness, not a wedged controller
        req_resp_ready = '0;
        present(0, 0, ROW_RST, '0, '0, '0);
        wait_accept(0, ok);
        check("Reset_RequestWakesChannel", env.mem_valid[0] === 1'b1);
        wait_resp(0, ok);
        accept_resp(0, d, tg);

        present(0, 0, ROW_RST + 1, '0, full_we(), gen_data(32'h6000_0000));
        @(posedge clk); #1;
        reset = 0;
        clear_all();
        @(posedge clk); #1;
        check("Reset_MidflightQuiet",
              (env.mem_valid === '0) && (req_resp_valid === '0));
        @(posedge clk); #1;
        check("Reset_MidflightStaysQuiet",
              (env.mem_valid === '0) && (req_resp_valid === '0));
        reset = 1;
        @(posedge clk); #1;

        write_line(0, 0, ROW_RST + 2, gen_data(32'h7000_0000));
        read_line (0, 0, ROW_RST + 2, d);
        check("Reset_OperationResumes", d === gen_data(32'h7000_0000));
    endtask

    // ------------------------------------------------------------------------
    // entry point, called by the top for this config
    // ------------------------------------------------------------------------
    task automatic run_all();
        $display("\n========================================");
        $display("Memory Controller: %s config", LABEL);
        $display("  DATA_WIDTH=%0d NUM_USERS=%0d NUM_CHANNELS=%0d MEM_LINE_BYTES=%0d",
                 DATA_WIDTH, NUM_USERS, NUM_CHANNELS, MEM_LINE_BYTES);
        $display("  RESP_BUF_DEPTH=%0d REQ_TAG_WIDTH=%0d ITERS=%0d",
                 RESP_BUF_DEPTH, REQ_TAG_WIDTH, ITERS);
        $display("========================================");

        mon_full_samples = 0;
        mon_violations   = 0;

        test_read_write();
        test_channel_decode();
        test_byte_we();
        test_concurrent(1'b1);
        test_concurrent(1'b0);
        test_stall_memory();
        test_response_buffering();
        test_backpressure();
        test_tag_echo();
        test_tag_uniqueness();
        test_reset();

        // the monitor watched every test above, not just the backpressure one
        $display("[INFO] %s buffer-full samples=%0d ready violations=%0d",
                 LABEL, mon_full_samples, mon_violations);
        check("Monitor_NoReadyWhileFull", mon_violations == 0);
    endtask

endmodule

// ============================================================================
// Top: run the suite on a small config and a wide config, then one summary
// ============================================================================
module tb_mem_controller;

    mc_harness #(
        .DATA_WIDTH(32), .ADDR_WIDTH(32), .NUM_USERS(4), .NUM_CHANNELS(4),
        .MEM_LINE_BYTES(4), .MEM_DEPTH(256), .RESP_BUF_DEPTH(2),
        .REQ_TAG_WIDTH(8), .ITERS(40), .LABEL("DEBUG")
    ) dbg ();

    mc_harness #(
        .DATA_WIDTH(1024), .ADDR_WIDTH(32), .NUM_USERS(8), .NUM_CHANNELS(8),
        .MEM_LINE_BYTES(128), .MEM_DEPTH(256), .RESP_BUF_DEPTH(2),
        .REQ_TAG_WIDTH(8), .ITERS(40), .LABEL("PROD")
    ) prd ();

    initial begin
        log_pass = 1'b0; // fails-only log, the randomized loops are noisy otherwise
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
