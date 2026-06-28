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

import common_pkg::*;

module mem_controller #(
    parameter int DATA_WIDTH,
    parameter int ADDR_WIDTH,
    parameter int NUM_USERS,
    parameter int NUM_CHANNELS,
    // data ctrl moves whole line, so DATA_WIDTH = MEM_LINE_BYTES * 8
    // instr ctrl stays narrow for word instrs
    parameter int MEM_LINE_BYTES
    )(
    input logic clk, reset,
    // user requests interface used by fetch/LSUs
    output logic [NUM_USERS-1:0] req_ready, // tells user controller is ready for requests
    input logic [NUM_USERS-1:0] req_valid,
    input logic [MEM_LINE_BYTES-1:0] req_we [NUM_USERS],
    input logic [ADDR_WIDTH-1:0] req_addr [NUM_USERS],
    input logic [DATA_WIDTH-1:0] req_data [NUM_USERS],
    
    output logic [NUM_USERS-1:0] req_resp_valid, // tells user when mem access is done
    input logic [NUM_USERS-1:0] req_resp_ready, // user tells controller it can accept response
    output logic [DATA_WIDTH-1:0] req_resp_data [NUM_USERS],
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
    
    // comb next output signals
    // req_ready is async (driven by arbiter), so no next_ version needed
    logic [NUM_CHANNELS-1:0] next_mem_valid;
    logic [MEM_LINE_BYTES-1:0] next_mem_we [NUM_CHANNELS];
    logic [CH_ADDR_WIDTH-1:0] next_mem_addr [NUM_CHANNELS];
    logic [DATA_WIDTH-1:0] next_mem_data [NUM_CHANNELS];
    
    // address decoding - pick which channel each user's request goes to
    // byte address layout: [ row | channel | offset within line ]
    //   - low $clog2(MEM_LINE_BYTES) bits are byte offset within line - skipped so whole line stays on one channel
    //   - next $clog2(NUM_CHANNELS) bits select channel - middle-bit interleaving fans adjacent thread accesses (base + tid*line_size) across channels
    //   - upper bits become per-channel address (row inside that channel's memory)
    // ex: MEM_LINE_BYTES=4, NUM_CHANNELS=8 -> bits [4:2] select channel, bits [1:0] byte-in-line, bits [31:5] row
    // assumes both MEM_LINE_BYTES and NUM_CHANNELS are powers of 2
    logic [$clog2(NUM_CHANNELS)-1:0] user_channel [NUM_USERS];
    genvar u, c;
    generate
        for (u = 0; u < NUM_USERS; u++) 
            assign user_channel[u] = req_addr[u][$clog2(MEM_LINE_BYTES) +: $clog2(NUM_CHANNELS)];
    endgenerate
    
    // request routing - per channel, set bits for which users will want to request from that channel
    logic [NUM_USERS-1:0] channel_reqs [NUM_CHANNELS], channel_grants [NUM_CHANNELS];
    generate
        for (c = 0; c < NUM_CHANNELS; c++) 
            for (u = 0; u < NUM_USERS; u++) 
                assign channel_reqs[c][u] = (user_channel[u] == c) && req_valid[u];
    endgenerate
    
    // parallel per channel arbitration
    generate
        for (c = 0; c < NUM_CHANNELS; c++) begin : arbit
            arbiter #(NUM_USERS, NUM_CHANNELS) arbit_inst( 
                .clk(clk), 
                .reset(reset),
                .channel_free(mem_resp_valid[c]), // easier logic vs tracking user for req_resp_valid
                .channel_reqs(channel_reqs[c]),
                .channel_grants(channel_grants[c]),
                .req_ready(arb_req_ready[c])
            );
        end
    endgenerate
    
    // request servicing - access memory using granted channel users
    logic [NUM_CHANNELS-1:0] next_pending, pending; // keep track of channel state
    logic [$clog2(NUM_USERS)-1:0] next_user_granted [NUM_CHANNELS], user_granted [NUM_CHANNELS]; // track user 
    logic [NUM_USERS-1:0] next_req_resp_valid;
    logic [DATA_WIDTH-1:0] next_req_resp_data [NUM_USERS];

    // per-channel req_ready from each arbiter, OR-reduce across channels for
    // top-level req_ready (given user only targets one channel at once)
    logic [NUM_USERS-1:0] arb_req_ready [NUM_CHANNELS];
    always_comb begin
        req_ready = '0;
        for (int c = 0; c < NUM_CHANNELS; c++) begin
            req_ready |= arb_req_ready[c];
        end
    end
    
    // controller always ready to accept memory responses, capture handled by pending logic
    assign mem_resp_ready = '1;
    
    // user must hold req_resp_ready while awaiting own response bc no response buffering
    generate
        for (genvar gu = 0; gu < NUM_USERS; gu++) begin : resp_ready_chk
            assert property (@(posedge clk) disable iff (!reset)
                req_resp_valid[gu] |-> req_resp_ready[gu])
                else $error("mem_controller: user %0d response dropped without resp_ready", gu);
        end
    endgenerate
    
    always_comb begin
        // default resp signals
        next_req_resp_valid = 0;
        for (int u = 0; u < NUM_USERS; u++) begin
            next_req_resp_data[u] = req_resp_data[u];
        end
        
        for (int c = 0; c < NUM_CHANNELS; c++) begin 
            next_mem_addr[c] = mem_addr[c]; next_mem_data[c] = mem_data[c]; next_mem_we[c] = mem_we[c]; 
            next_mem_valid[c] = 0; next_pending[c] = 0; // default values
            next_user_granted[c] = user_granted[c]; // hold by default
        
            if (|channel_grants[c]) begin // upon channel first being granted
                for (int u = 0; u < NUM_USERS; u++) begin
                    if (channel_grants[c][u]) begin 
                        // strip line-offset + channel-select bits -> dense per-channel addr
                        next_mem_addr[c] = req_addr[u][ADDR_WIDTH-1 : CH_ADDR_LSB];
                        next_mem_data[c] = req_data[u];
                        next_mem_we[c] = req_we[u];
                        next_mem_valid[c] = 1;
                        next_user_granted[c] = u; 
                        next_pending[c] = (mem_ready[c]) ? 1 : 0; // pending only begins once mem is ready
                    end
                end
            end else if ((mem_valid[c]) && (!pending[c])) begin // if mem was not ready the first time
                // check mem_ready again
                next_mem_valid[c] = (!mem_ready[c]) ? 1 : 0; 
                next_pending[c] = (mem_ready[c]) ? 1 : 0; 
            end else if ((pending[c]) && (!mem_resp_valid[c])) begin // if currently in progress
                next_pending[c] = 1;
            end else if ((pending[c]) && (mem_resp_valid[c])) begin // if done
                // mem receiving - route data/responses back to correct users
                next_req_resp_valid[user_granted[c]] = 1; 
                next_req_resp_data[user_granted[c]] = mem_resp_data[c];
                next_pending[c] = 0;
            end
        end            
    end
    
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            mem_valid <= 0;
            pending <= 0;
            req_resp_valid <= 0;
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                mem_we[c] <= 0;
                mem_addr[c] <= 0;
                mem_data[c] <= 0;
                user_granted[c] <= 0;
            end
            for (int u = 0; u < NUM_USERS; u++) begin
                req_resp_data[u] <= 0;
            end
        end else begin
            mem_valid <= next_mem_valid;
            pending <= next_pending;
            req_resp_valid <= next_req_resp_valid;
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                mem_we[c] <= next_mem_we[c];
                mem_addr[c] <= next_mem_addr[c]; // already dense per-channel line addr
                mem_data[c] <= next_mem_data[c];
                user_granted[c] <= next_user_granted[c];
            end
            for (int u = 0; u < NUM_USERS; u++) begin
                req_resp_data[u] <= next_req_resp_data[u];
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
