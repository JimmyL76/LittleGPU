`timescale 1ns / 1ps

import common_pkg::*;

// multi-round coalescer: tracks up to MAX_CONCURRENT_ROUNDS independent
// per-warp memory rounds concurrently, each identified by a round tag
// supplied by the caller (core.sv passes the memory_scoreboard's alloc_tag,
// so the round-tag namespace and the scoreboard's entry-index namespace are
// the same values by construction - see memory_scoreboard.sv)
//
// only one warp's lsu_valid/lsu_addr/etc can be non-zero on any given cycle
// (core.sv only ever grants the shared per-thread lsus to one warp), so at
// most one NEW round starts per cycle, identified by issue_round_tag. but
// multiple previously-started rounds can still be mid-delivery at once, so
// their groups compete for the single upstream request slot (lowest round
// tag wins ties) and their deliveries share the single downstream response
// bus, tagged with resp_round_tag so the caller knows which round's data
// just arrived
//
// the outstanding-line table (COAL_OUTSTANDING deep) is a single pool shared
// across all rounds - that matches real hardware, where in-flight lines are
// a global resource, not one pool per warp. each entry now also records
// which round it belongs to (entry_round_tag) so a delivered line updates
// the correct round's pending/latched state
module coalescer #(
    parameter int THREADS_PER_WARP = 32,
    parameter int MEM_LINE_BYTES = 128,
    parameter int COAL_OUTSTANDING = 2,
    // concurrent in-flight rounds
    // must equal (or be >=) the memory_scoreboard depth the caller pairs this
    // with, since round tags are that scoreboard's alloc_tag values directly
    parameter int MAX_CONCURRENT_ROUNDS = 2,
    parameter int REQ_TAG_WIDTH = common_pkg::REQ_TAG_WIDTH
    )(
    input logic clk, reset,
    
    // downstream - per-thread lsu mem-side ports, word-wide, unchanged from lsu
    input logic [THREADS_PER_WARP-1:0] lsu_valid,
    input data_mem_addr_t lsu_addr [THREADS_PER_WARP],
    input data_t lsu_data [THREADS_PER_WARP],
    input logic [($bits(data_t)/8)-1:0] lsu_we [THREADS_PER_WARP],
    output logic [THREADS_PER_WARP-1:0] lsu_resp_valid,
    input logic [THREADS_PER_WARP-1:0] lsu_resp_ready,
    output data_t lsu_resp_data [THREADS_PER_WARP],
    // which round is trying to start this cycle, and which round a delivery
    // belongs to - both use the caller's tag namespace (see module header)
    input logic [REQ_TAG_WIDTH-1:0] issue_round_tag,
    output logic [REQ_TAG_WIDTH-1:0] resp_round_tag,
    // one-cycle pulse the edge issue_round_tag's round is captured, so the
    // caller knows when this warp's request has been taken off its hands
    output logic round_start,
    
    // upstream - single mem_controller user port, line-wide
    output logic mem_valid,
    input logic mem_ready,
    output data_mem_addr_t mem_addr,
    output logic [MEM_LINE_BYTES*8-1:0] mem_data,
    output logic [MEM_LINE_BYTES-1:0] mem_we,
    output logic [REQ_TAG_WIDTH-1:0] mem_tag, // identifies outstanding line
    input logic mem_resp_valid,
    output logic mem_resp_ready,
    input logic [MEM_LINE_BYTES*8-1:0] mem_resp_data,
    input logic [REQ_TAG_WIDTH-1:0] mem_resp_tag // echoed tag, selects outstanding entry
    );

    // derived widths
    localparam int LINE_BITS = MEM_LINE_BYTES * 8;
    localparam int WORD_BYTES = DATA_WIDTH / 8; // bytes per lsu word (4)
    localparam int WORDS_PER_LINE = MEM_LINE_BYTES / WORD_BYTES;
    // # of addr bits below line boundary (byte-in-line offset)
    localparam int LINE_BYTE_OFF_BITS = $clog2(MEM_LINE_BYTES);
    // # of addr bits to pick word slot inside line, min 1 to keep valid range
    localparam int WORD_SLOT_BITS = (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;
    // width of outstanding-line-table index (line tags, controller-facing)
    localparam int ENTRY_IDX_BITS = (COAL_OUTSTANDING > 1) ? $clog2(COAL_OUTSTANDING) : 1;
    
/* 
    ex: MEM_LINE_BYTES = 128 (7 bits), NUM_CHANNELS = 8 (3 bits), DATA_WIDTH = 32 (4 bytes = 2 bits)
  <-           line_id = bits [31:7] (128-byte line address)           ->
  +------------------+-------------------+------------------------------+-------+
  |  dense row addr  |   channel select  |    word slot inside line     | byte  |
  |   bits [31:10]   |     bits [9:7]    |          bits [6:2]          | [1:0] |
  +------------------+-------------------+------------------------------+-------+
  <- per-ch row ->   <- 8 channels ->    <- 32 words inside 128B line -> <-4B ->
*/
    
    // elab-time checks
    initial begin
        if (MEM_LINE_BYTES < WORD_BYTES)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be >= WORD_BYTES (%0d)", MEM_LINE_BYTES, WORD_BYTES);
        if (MEM_LINE_BYTES % WORD_BYTES != 0)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be multiple of WORD_BYTES (%0d)", MEM_LINE_BYTES, WORD_BYTES);
        if ((MEM_LINE_BYTES & (MEM_LINE_BYTES - 1)) != 0)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be power of 2", MEM_LINE_BYTES);
        if (COAL_OUTSTANDING < 1)
            $fatal(1, "coalescer: COAL_OUTSTANDING (%0d) must be >= 1", COAL_OUTSTANDING);
        if (MAX_CONCURRENT_ROUNDS < 1)
            $fatal(1, "coalescer: MAX_CONCURRENT_ROUNDS (%0d) must be >= 1", MAX_CONCURRENT_ROUNDS);
        // every outstanding line needs its own tag value, else responses alias
        if (REQ_TAG_WIDTH < ENTRY_IDX_BITS)
            $fatal(1, "coalescer: REQ_TAG_WIDTH (%0d) too narrow for COAL_OUTSTANDING (%0d)", REQ_TAG_WIDTH, COAL_OUTSTANDING);
        // round tags must fit the same wire, and the caller's tag namespace
        // (memory_scoreboard depth) must not exceed the round-slot count here
        if ((1 << REQ_TAG_WIDTH) < MAX_CONCURRENT_ROUNDS)
            $fatal(1, "coalescer: REQ_TAG_WIDTH (%0d) too narrow for MAX_CONCURRENT_ROUNDS (%0d)", REQ_TAG_WIDTH, MAX_CONCURRENT_ROUNDS);
    end
    
    // line id = address with byte-in-line offset stripped
    typedef logic [DATA_MEM_ADDR_WIDTH-LINE_BYTE_OFF_BITS-1:0] line_id_t;
    
    // per-round, per-thread latched state, captured at that round's start,
    // held stable across its groups. replicated per round (not just per
    // thread) so two rounds can each hold their own in-flight snapshot
    line_id_t latched_line_id [MAX_CONCURRENT_ROUNDS][THREADS_PER_WARP];
    data_mem_addr_t latched_addr [MAX_CONCURRENT_ROUNDS][THREADS_PER_WARP];
    data_t latched_data [MAX_CONCURRENT_ROUNDS][THREADS_PER_WARP];
    logic [WORD_BYTES-1:0] latched_we [MAX_CONCURRENT_ROUNDS][THREADS_PER_WARP];
    // word slot inside line (which word position this thread occupies)
    logic [WORD_SLOT_BITS-1:0] latched_word_off [MAX_CONCURRENT_ROUNDS][THREADS_PER_WARP];
    logic [THREADS_PER_WARP-1:0] pending [MAX_CONCURRENT_ROUNDS]; // 1 = thread still needs response
    // a round runs exactly while its threads still need service, so pending
    // alone says whether that round's lsu inputs may be snapshotted again
    logic round_active [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++)
            round_active[r] = |pending[r];
    end
    // new round starts for the slot named by issue_round_tag exactly when
    // that slot is idle and the (single, shared) lsu bus presents a request
    assign round_start = !round_active[issue_round_tag] && (|lsu_valid);
    
    // outstanding-line table - one entry per line request in flight, shared
    // across all rounds (in-flight lines are a core-wide resource, not a
    // per-round one). word slots live in that round's latched_word_off, and
    // every thread belongs to one line, so no per-entry word-slot copy needed
    logic entry_valid [COAL_OUTSTANDING];
    logic [REQ_TAG_WIDTH-1:0] entry_tag [COAL_OUTSTANDING]; // line tag, controller-facing
    logic [REQ_TAG_WIDTH-1:0] entry_round_tag [COAL_OUTSTANDING]; // which round this line belongs to
    logic [THREADS_PER_WARP-1:0] entry_group [COAL_OUTSTANDING]; // threads bundled into that line
    
    // presented line request, registered so it stays stable until mem takes it
    logic req_active;
    data_mem_addr_t req_addr;
    logic [LINE_BITS-1:0] req_data;
    logic [MEM_LINE_BYTES-1:0] req_we;
    logic [REQ_TAG_WIDTH-1:0] req_tag;
    
    // per round: threads already covered by an in-flight line (belonging to
    // that same round) are not up for grouping again
    logic [THREADS_PER_WARP-1:0] inflight [MAX_CONCURRENT_ROUNDS];
    logic [THREADS_PER_WARP-1:0] eligible [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
            inflight[r] = '0;
            for (int e = 0; e < COAL_OUTSTANDING; e++)
                if (entry_valid[e] && (entry_round_tag[e] == r)) inflight[r] |= entry_group[e];
            eligible[r] = pending[r] & ~inflight[r];
        end
    end
    
    // per round: pick lowest eligible thread as leader for next group
    // eligible & (~eligible + 1) isolates lowest set bit as one-hot
    // (same as dispatcher.sv's nth_free_core, just on set bits)
    logic [THREADS_PER_WARP-1:0] leader_onehot [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++)
            leader_onehot[r] = eligible[r] & (~eligible[r] + 1);
    end
    
    // per round: leader's line id and base addr via OR-reduction across
    // one-hot mask, cheaper than priority-encoding to binary index then
    // doing a 32:1 mux
    line_id_t leader_line_id [MAX_CONCURRENT_ROUNDS];
    data_mem_addr_t leader_addr [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
            leader_line_id[r] = '0;
            leader_addr[r] = '0;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (leader_onehot[r][t]) begin
                    leader_line_id[r] = latched_line_id[r][t];
                    leader_addr[r] = latched_addr[r][t];
                end
            end
        end
    end
    
    // per round: group_mask = every eligible thread whose latched line id
    // matches that round's leader
    logic [THREADS_PER_WARP-1:0] next_group_mask [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
            next_group_mask[r] = '0;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (eligible[r][t] && (latched_line_id[r][t] == leader_line_id[r]))
                    next_group_mask[r][t] = 1'b1;
            end
        end
    end
    
    // per round: build line-wide write payload by placing each grouped
    // thread's word at its own word slot in line, with byte-level we
    // conflicts have lowest thread index wins per byte
    logic [LINE_BITS-1:0] merged_wdata [MAX_CONCURRENT_ROUNDS];
    logic [MEM_LINE_BYTES-1:0] merged_we [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
            merged_wdata[r] = '0;
            merged_we[r] = '0;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (next_group_mask[r][t]) begin
                    // thread t's word lives at byte offset latched_word_off[r][t]*WORD_BYTES
                    // for each byte b in its word, claim that byte if not already claimed
                    for (int b = 0; b < WORD_BYTES; b++) begin
                        automatic int byte_pos = int'(latched_word_off[r][t]) * WORD_BYTES + b;
                        if (latched_we[r][t][b] && !merged_we[r][byte_pos]) begin
                            merged_we[r][byte_pos] = 1'b1;
                            merged_wdata[r][byte_pos*8 +: 8] = latched_data[r][t][b*8 +: 8];
                        end
                    end
                end
            end
        end
    end
    
    // lowest free table entry, its index doubles as the line tag value
    logic entry_free;
    logic [ENTRY_IDX_BITS-1:0] alloc_idx;
    always_comb begin
        entry_free = 1'b0;
        alloc_idx = '0;
        for (int e = COAL_OUTSTANDING - 1; e >= 0; e--) begin
            if (!entry_valid[e]) begin
                entry_free = 1'b1;
                alloc_idx = e[ENTRY_IDX_BITS-1:0];
            end
        end
    end
    
    // cross-round arbitration: among rounds with an eligible group ready,
    // lowest round tag wins the single upstream request slot this cycle.
    // bounded fairness follows from every round being finite (a memory op
    // has a fixed thread count), same reasoning as any other fixed-priority
    // arbiter in this design
    logic any_round_ready;
    logic [REQ_TAG_WIDTH-1:0] issue_round;
    logic req_slot_free, alloc_en;

    always_comb begin
        any_round_ready = 1'b0;
        issue_round = '0;
        for (int r = MAX_CONCURRENT_ROUNDS - 1; r >= 0; r--) begin
            if (round_active[r] && (|eligible[r])) begin
                any_round_ready = 1'b1;
                issue_round = r;
            end
        end
    end
    
    // issue when request slot is free, an entry is free, and some round has
    // threads that still need a line; with no free entry, the group stays
    // eligible and issues once an entry frees
    // check if there is already a req or req being serviced this cycle
    assign req_slot_free = !req_active || mem_ready; 
    assign alloc_en = any_round_ready && entry_free && req_slot_free;
    
    // match returned line to its entry by (controller-facing) line tag,
    // independent of return order
    logic resp_hit;
    logic [ENTRY_IDX_BITS-1:0] resp_idx;
    always_comb begin
        resp_hit = 1'b0;
        resp_idx = '0;
        for (int e = 0; e < COAL_OUTSTANDING; e++) begin
            if (entry_valid[e] && (entry_tag[e] == mem_resp_tag)) begin
                resp_hit = 1'b1;
                resp_idx = e[ENTRY_IDX_BITS-1:0];
            end
        end
    end
    
    // line goes only to threads recorded for matched entry, at recorded
    // slots, tagged with the round it belongs to so the caller can route it
    logic [THREADS_PER_WARP-1:0] resp_group;
    logic resp_accept;
    assign resp_group = resp_hit ? entry_group[resp_idx] : '0;
    assign resp_round_tag = resp_hit ? entry_round_tag[resp_idx] : '0;
    assign mem_resp_ready = resp_hit && ((lsu_resp_ready & resp_group) == resp_group);
    assign resp_accept = mem_resp_valid && mem_resp_ready;
    
    always_comb begin
        mem_valid = req_active;
        mem_addr = req_addr;
        mem_data = req_data;
        mem_we = req_we;
        mem_tag = req_tag;
        lsu_resp_valid = resp_accept ? resp_group : '0;
        // per-thread word slice, from the matched entry's own round's
        // latched_word_off, only threads in resp_group see their data
        for (int t = 0; t < THREADS_PER_WARP; t++)
            lsu_resp_data[t] = mem_resp_data[int'(latched_word_off[resp_round_tag][t])*DATA_WIDTH +: DATA_WIDTH];
    end
    
    // per round: threads left needing service after this cycle's delivery
    logic [THREADS_PER_WARP-1:0] pending_after [MAX_CONCURRENT_ROUNDS];
    always_comb begin
        for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
            pending_after[r] = (resp_accept && (r == resp_round_tag)) ? (pending[r] & ~resp_group) : pending[r];
        end
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            req_active <= 1'b0;
            req_addr <= '0;
            req_data <= '0;
            req_we <= '0;
            req_tag <= '0;
            for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
                pending[r] <= '0;
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    latched_line_id[r][t] <= '0;
                    latched_addr[r][t] <= '0;
                    latched_data[r][t] <= '0;
                    latched_we[r][t] <= '0;
                    latched_word_off[r][t] <= '0;
                end
            end
            for (int e = 0; e < COAL_OUTSTANDING; e++) begin
                entry_valid[e] <= 1'b0;
                entry_tag[e] <= '0;
                entry_round_tag[e] <= '0;
                entry_group[e] <= '0;
            end
        end else begin
            // entering a new round for the slot named by issue_round_tag,
            // snapshot every active thread's request. every other round's
            // pending state just retires whatever this cycle's delivery
            // (if any) served for it
            if (round_start) begin
                pending[issue_round_tag] <= lsu_valid;
                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                    latched_addr[issue_round_tag][t] <= lsu_addr[t];
                    latched_data[issue_round_tag][t] <= lsu_data[t];
                    latched_we[issue_round_tag][t] <= lsu_we[t];
                    latched_line_id[issue_round_tag][t] <= lsu_addr[t][DATA_MEM_ADDR_WIDTH-1:LINE_BYTE_OFF_BITS];
                    // word slot: addr bits between word boundary and line boundary
                    // degenerates to 0 when WORDS_PER_LINE == 1 (4-byte line)
                    if (WORDS_PER_LINE > 1)
                        latched_word_off[issue_round_tag][t] <= lsu_addr[t][LINE_BYTE_OFF_BITS-1:$clog2(WORD_BYTES)];
                    else
                        latched_word_off[issue_round_tag][t] <= '0;
                end
            end
            for (int r = 0; r < MAX_CONCURRENT_ROUNDS; r++) begin
                // don't clobber a round just snapshotted above this same edge
                if (!(round_start && (r == issue_round_tag)) && round_active[r]) begin
                    pending[r] <= pending_after[r];
                end
            end
            
            // free entry whose line was just delivered
            if (resp_accept) begin
                entry_valid[resp_idx] <= 1'b0;
                $display("Coalescer: line tag=%0d (round=%0d) delivered, mask=%b, remaining=%b",
                          mem_resp_tag, resp_round_tag, resp_group, pending_after[resp_round_tag]);
            end
            
            // record next line in table (tagged with which round it serves)
            // and present its request
            if (alloc_en) begin
                entry_valid[alloc_idx] <= 1'b1;
                entry_tag[alloc_idx] <= alloc_idx; // entry index doubles as its line tag
                entry_round_tag[alloc_idx] <= issue_round;
                entry_group[alloc_idx] <= next_group_mask[issue_round];
                req_active <= 1'b1;
                req_addr <= leader_addr[issue_round];
                req_data <= merged_wdata[issue_round];
                req_we <= merged_we[issue_round];
                req_tag <= alloc_idx;
            end else if (req_active && mem_ready) begin
                req_active <= 1'b0;
            end
        end
    end

endmodule
