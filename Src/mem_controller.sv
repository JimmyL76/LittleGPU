`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/03/2025 09:47:15 AM
// Design Name: 
// Module Name: mem_controller
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

// no wildcard import needed  only explicit common_pkg::REQ_TAG_WIDTH is referenced
module mem_controller #(
    parameter int DATA_WIDTH,
    parameter int ADDR_WIDTH,
    parameter int NUM_USERS,
    parameter int NUM_CHANNELS,
    // data ctrl moves whole line, so DATA_WIDTH = MEM_LINE_BYTES * 8
    // instr ctrl stays narrow for word instrs
    parameter int MEM_LINE_BYTES,
    // per-user response buffer depth default 2 integer >= 2
    parameter int RESP_BUF_DEPTH = 2,
    // request tag width carried end to end default from common_pkg
    parameter int REQ_TAG_WIDTH = common_pkg::REQ_TAG_WIDTH
    )(
    input logic clk, reset,
    // user requests interface used by fetch/LSUs
    output logic [NUM_USERS-1:0] req_ready, // tells user controller is ready for requests
    input logic [NUM_USERS-1:0] req_valid,
    input logic [MEM_LINE_BYTES-1:0] req_we [NUM_USERS],
    input logic [ADDR_WIDTH-1:0] req_addr [NUM_USERS],
    input logic [DATA_WIDTH-1:0] req_data [NUM_USERS],
    // tag presented with each request, identifies user outstanding request
    input logic [REQ_TAG_WIDTH-1:0] req_tag [NUM_USERS],
    
    output logic [NUM_USERS-1:0] req_resp_valid, // tells user when mem access is done
    input logic [NUM_USERS-1:0] req_resp_ready, // user tells controller it can accept response
    output logic [DATA_WIDTH-1:0] req_resp_data [NUM_USERS],
    // tag echoed on response bit-for-bit identical to accepted request tag
    output logic [REQ_TAG_WIDTH-1:0] req_resp_tag [NUM_USERS],
    // mem interface
    // note this is restricted by # of mem channels, which is likely smaller than # of users
    // mem_addr is dense per-channel line address - byte offset and channel-select
    // bits stripped, so narrower than byte ADDR_WIDTH (see CH_ADDR_WIDTH)
    input logic [NUM_CHANNELS-1:0] mem_ready, // mem tells controller channel is ready for usage
    output logic [NUM_CHANNELS-1:0] mem_valid,
    output logic [MEM_LINE_BYTES-1:0] mem_we [NUM_CHANNELS],
    output logic [ADDR_WIDTH-$clog2(MEM_LINE_BYTES)-$clog2(NUM_CHANNELS)-1:0] mem_addr [NUM_CHANNELS],
    output logic [DATA_WIDTH-1:0] mem_data [NUM_CHANNELS],
    
    input logic [NUM_CHANNELS-1:0] mem_resp_valid, // mem tells controller when done
    output logic [NUM_CHANNELS-1:0] mem_resp_ready, // controller tells mem it can accept response (always 1 now)
    input logic [DATA_WIDTH-1:0] mem_resp_data [NUM_CHANNELS]
    );
    
    // per-channel address: byte address with line-offset and channel-select bits
    // stripped (both constant for one channel's line accesses)
    localparam int CH_ADDR_LSB = $clog2(MEM_LINE_BYTES) + $clog2(NUM_CHANNELS);
    localparam int CH_ADDR_WIDTH = ADDR_WIDTH - CH_ADDR_LSB;
    // count width holds 0 to RESP_BUF_DEPTH so needs clog2 of depth plus 1
    localparam int RESP_CNT_W = $clog2(RESP_BUF_DEPTH + 1);

    // ---- module state ----
    // per-user response buffer state
    // resp_count counts buffered unaccepted responses occupancy counts in-flight plus buffered
    logic [DATA_WIDTH-1:0] resp_buf      [NUM_USERS][RESP_BUF_DEPTH];
    logic [DATA_WIDTH-1:0] next_resp_buf [NUM_USERS][RESP_BUF_DEPTH];
    // parallel tag buffer holds each buffered response tag alongside its data
    logic [REQ_TAG_WIDTH-1:0] resp_tag_buf      [NUM_USERS][RESP_BUF_DEPTH];
    logic [REQ_TAG_WIDTH-1:0] next_resp_tag_buf [NUM_USERS][RESP_BUF_DEPTH];
    logic [RESP_CNT_W-1:0] resp_count [NUM_USERS], next_resp_count [NUM_USERS];
    logic [RESP_CNT_W-1:0] occupancy  [NUM_USERS], next_occupancy  [NUM_USERS];
    // per-channel servicing state
    logic [NUM_CHANNELS-1:0] pending, next_pending; // keep track of channel state
    logic [$clog2(NUM_USERS)-1:0] user_granted [NUM_CHANNELS], next_user_granted [NUM_CHANNELS]; // track user
    // per-channel tag captured at acceptance, held unchanged until response returns
    logic [REQ_TAG_WIDTH-1:0] tag_granted [NUM_CHANNELS], next_tag_granted [NUM_CHANNELS];

    // ---- address decode - pick which channel each user's request goes to ----
    // byte address layout: [ row | channel | offset within line ]
    //   - low $clog2(MEM_LINE_BYTES) bits are byte offset within line - skipped so whole line stays on one channel
    //   - next $clog2(NUM_CHANNELS) bits select channel - middle-bit interleaving fans adjacent thread accesses (base + tid*line_size) across channels
    //   - upper bits become per-channel address (row inside that channel's memory)
    // ex: MEM_LINE_BYTES=4, NUM_CHANNELS=8 -> bits [4:2] select channel, bits [1:0] byte-in-line, bits [31:5] row
    // assumes both MEM_LINE_BYTES and NUM_CHANNELS are powers of 2
    logic [$clog2(NUM_CHANNELS)-1:0] user_channel [NUM_USERS];
    genvar gu, gc;
    generate
        for (gu = 0; gu < NUM_USERS; gu++) begin : gen_user_channel
            assign user_channel[gu] = req_addr[gu][$clog2(MEM_LINE_BYTES) +: $clog2(NUM_CHANNELS)];
        end
    endgenerate

    // ---- backpressure gate ----
    // mask off requests from users whose outstanding plus buffered total hit depth
    // arbiter sees no request, so req_ready will always be low for full users
    logic [NUM_USERS-1:0] req_valid_gated;
    always_comb begin
        for (int u = 0; u < NUM_USERS; u++)
            req_valid_gated[u] = req_valid[u] && (occupancy[u] < RESP_BUF_DEPTH);
    end

    // ---- request routing - per channel, set bits for which users want that channel ----
    logic [NUM_USERS-1:0] channel_reqs [NUM_CHANNELS], channel_grants [NUM_CHANNELS];
    generate
        for (gc = 0; gc < NUM_CHANNELS; gc++) begin : gen_ch_route
            for (gu = 0; gu < NUM_USERS; gu++) begin : gen_user_route
                assign channel_reqs[gc][gu] = (user_channel[gu] == gc) && req_valid_gated[gu];
            end
        end
    endgenerate

    // ---- arbitration - one arbiter per channel ----
    logic [NUM_USERS-1:0] arb_req_ready [NUM_CHANNELS];
    generate
        for (gc = 0; gc < NUM_CHANNELS; gc++) begin : arbit
            arbiter #(NUM_USERS, NUM_CHANNELS) arbit_inst( 
                .clk(clk), 
                .reset(reset),
                .channel_free(mem_resp_valid[gc]), // easier logic vs tracking user for req_resp_valid
                .channel_reqs(channel_reqs[gc]),
                .channel_grants(channel_grants[gc]),
                .req_ready(arb_req_ready[gc])
            );
        end
    endgenerate

    // OR-reduce per-channel arb_req_ready across channels for top-level
    // req_ready (given user only targets one channel at once)
    always_comb begin
        req_ready = '0;
        for (int c = 0; c < NUM_CHANNELS; c++) begin
            req_ready |= arb_req_ready[c];
        end
    end

    // ---- request servicing (user -> memory) ----
    // comb next values for registered mem-side outputs
    logic [NUM_CHANNELS-1:0] next_mem_valid;
    logic [MEM_LINE_BYTES-1:0] next_mem_we [NUM_CHANNELS];
    logic [CH_ADDR_WIDTH-1:0] next_mem_addr [NUM_CHANNELS];
    logic [DATA_WIDTH-1:0] next_mem_data [NUM_CHANNELS];

    // controller always ready to accept memory responses, capture handled by pending logic
    assign mem_resp_ready = '1;

    always_comb begin
        for (int c = 0; c < NUM_CHANNELS; c++) begin 
            next_mem_addr[c] = mem_addr[c]; next_mem_data[c] = mem_data[c]; next_mem_we[c] = mem_we[c]; 
            next_mem_valid[c] = 0; next_pending[c] = 0; // default values
            next_user_granted[c] = user_granted[c]; // hold by default
            next_tag_granted[c] = tag_granted[c]; // hold accepted tag by default
        
            if (|channel_grants[c]) begin // upon channel first being granted
                for (int u = 0; u < NUM_USERS; u++) begin
                    if (channel_grants[c][u]) begin 
                        // strip line-offset + channel-select bits -> dense per-channel addr
                        next_mem_addr[c] = req_addr[u][ADDR_WIDTH-1 : CH_ADDR_LSB];
                        next_mem_data[c] = req_data[u];
                        next_mem_we[c] = req_we[u];
                        next_mem_valid[c] = 1;
                        next_user_granted[c] = u; 
                        next_tag_granted[c] = req_tag[u]; // record tag at acceptance cycle
                        // pending stays 0 here - mem_ready this cycle says nothing about
                        // whether mem accepts, since mem_valid only rises at coming edge
                        // acceptance is detected by branch below while mem_valid is high
                        next_pending[c] = 0;
                    end
                end
            end else if ((mem_valid[c]) && (!pending[c])) begin // request presented, not yet taken
                // mem_ready sampled while mem_valid is high, so this is real handshake
                // hold request until mem takes it, then mark pending
                next_mem_valid[c] = (!mem_ready[c]) ? 1 : 0; 
                next_pending[c] = (mem_ready[c]) ? 1 : 0; 
            end else if ((pending[c]) && (!mem_resp_valid[c])) begin // if currently in progress
                next_pending[c] = 1;
            end else if ((pending[c]) && (mem_resp_valid[c])) begin // if done
                // completion captured into granted user buffer by response buffer logic
                next_pending[c] = 0;
            end
        end            
    end

    // ---- response (memory -> user) ----
    // present buffered head response to each user, valid while buffer non-empty
    // data stays stable until accepted since head only changes on pop
    always_comb begin
        for (int u = 0; u < NUM_USERS; u++) begin
            req_resp_valid[u] = (resp_count[u] != 0);
            req_resp_data[u]  = resp_buf[u][0];
            req_resp_tag[u]   = resp_tag_buf[u][0];
        end
    end

    // response buffer next-state - pop accepted head and free occupancy, push
    // completed channel responses to buf, count new accepted requests outstanding
    always_comb begin
        for (int u = 0; u < NUM_USERS; u++) begin
            for (int i = 0; i < RESP_BUF_DEPTH; i++) next_resp_buf[u][i] = resp_buf[u][i];
            for (int i = 0; i < RESP_BUF_DEPTH; i++) next_resp_tag_buf[u][i] = resp_tag_buf[u][i];
            next_resp_count[u] = resp_count[u];
            next_occupancy[u]  = occupancy[u];
        end
        // free head slot when user accepts its response
        for (int u = 0; u < NUM_USERS; u++) begin
            if (req_resp_valid[u] && req_resp_ready[u]) begin
                for (int i = 0; i < RESP_BUF_DEPTH-1; i++) begin
                    next_resp_buf[u][i] = next_resp_buf[u][i+1];
                    next_resp_tag_buf[u][i] = next_resp_tag_buf[u][i+1];
                end
                next_resp_count[u] = next_resp_count[u] - 1;
                next_occupancy[u]  = next_occupancy[u] - 1;
            end
        end
        // write each completed channel response into its granted user buffer tail
        for (int c = 0; c < NUM_CHANNELS; c++) begin
            if (pending[c] && mem_resp_valid[c]) begin
                if (next_resp_count[user_granted[c]] < RESP_BUF_DEPTH) begin
                    next_resp_buf[user_granted[c]][next_resp_count[user_granted[c]]] = mem_resp_data[c];
                    next_resp_tag_buf[user_granted[c]][next_resp_count[user_granted[c]]] = tag_granted[c];
                    next_resp_count[user_granted[c]] = next_resp_count[user_granted[c]] + 1;
                end
            end
        end
        // count each newly accepted request toward user outstanding occupancy
        for (int u = 0; u < NUM_USERS; u++) begin
            if (req_valid[u] && req_ready[u])
                next_occupancy[u] = next_occupancy[u] + 1;
        end
    end
    
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            mem_valid <= 0;
            pending <= 0;
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                mem_we[c] <= 0;
                mem_addr[c] <= 0;
                mem_data[c] <= 0;
                user_granted[c] <= 0;
                tag_granted[c] <= 0;
            end
            for (int u = 0; u < NUM_USERS; u++) begin
                resp_count[u] <= 0;
                occupancy[u] <= 0;
                for (int i = 0; i < RESP_BUF_DEPTH; i++) begin
                    resp_buf[u][i] <= 0;
                    resp_tag_buf[u][i] <= 0;
                end
            end
        end else begin
            mem_valid <= next_mem_valid;
            pending <= next_pending;
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                mem_we[c] <= next_mem_we[c];
                mem_addr[c] <= next_mem_addr[c]; // already dense per-channel line addr
                mem_data[c] <= next_mem_data[c];
                user_granted[c] <= next_user_granted[c];
                tag_granted[c] <= next_tag_granted[c];
            end
            for (int u = 0; u < NUM_USERS; u++) begin
                resp_count[u] <= next_resp_count[u];
                occupancy[u] <= next_occupancy[u];
                for (int i = 0; i < RESP_BUF_DEPTH; i++) begin
                    resp_buf[u][i] <= next_resp_buf[u][i];
                    resp_tag_buf[u][i] <= next_resp_tag_buf[u][i];
                end
            end
        end
    end
    
endmodule

// per-channel round-robin arbiter, masked priority encoders,
// after granting user U, priority rotates so U is lowest next round
// single requester always wins immediately, but bounded wait NUM_USERS-1
module arbiter #(
        parameter int NUM_USERS, 
        parameter int NUM_CHANNELS
    )(
        input logic clk, reset,
        input logic channel_free,
        input logic [NUM_USERS-1:0] channel_reqs,
        output logic [NUM_USERS-1:0] channel_grants,
        output logic [NUM_USERS-1:0] req_ready
    );
    
    // one-hot, marks highest-priority user for this round
    logic [NUM_USERS-1:0] prio, next_prio;
    
    typedef enum logic {
        READY, BUSY
    } state_t;
    state_t s, next_s;
    
    // prefer reqs at or above prio, else wrap, lowest set bit is x & (~x + 1)
    logic [NUM_USERS-1:0] mask, grant_masked, grant_wrap, grant;
    assign mask = channel_reqs & ~(prio - 1);
    assign grant_masked = mask & (~mask + 1);
    assign grant_wrap = channel_reqs & (~channel_reqs + 1);
    assign grant = (|mask) ? grant_masked : grant_wrap;
    
    always_comb begin
        channel_grants = '0;
        req_ready = '0;
        next_s = s;
        case (s)
            READY: if (|channel_reqs) begin
                channel_grants = grant;
                req_ready = grant;
                next_s = BUSY;
            end
            BUSY: if (channel_free) next_s = READY;
        endcase
    end
    
    // advance pointer past granted user, rotate one-hot grant left
    always_comb begin
        next_prio = prio;
        if (|channel_grants)
            next_prio = {channel_grants[NUM_USERS-2:0], channel_grants[NUM_USERS-1]};
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            prio <= 'b1; // user 0 highest priority first
            s <= READY;
        end else begin
            s <= next_s;
            prio <= next_prio;
        end
    end

endmodule
