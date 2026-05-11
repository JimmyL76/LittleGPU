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
    // for now CACHE_LINE_BYTE_SIZE = 4 for simple implementation, TBD: larger byte cache lines
    parameter int CACHE_LINE_BYTE_SIZE = 4 
    )(
    input logic clk, reset,
    // user requests interface used by fetch/LSUs
    output logic [NUM_USERS-1:0] req_ready, // tells user controller is ready for requests
    input logic [NUM_USERS-1:0] req_valid,
    input logic [CACHE_LINE_BYTE_SIZE-1:0] req_we [NUM_USERS],
    input logic [ADDR_WIDTH-1:0] req_addr [NUM_USERS],
    input logic [ADDR_WIDTH-1:0] req_data [NUM_USERS],
    
    output logic [NUM_USERS-1:0] req_resp_valid, // tells user when mem access is done
    output logic [ADDR_WIDTH-1:0] req_resp_data [NUM_USERS],
    // mem interface
    // note this is restricted by # of mem channels, which may be smaller than # of users
    input logic [NUM_CHANNELS-1:0] mem_ready, // mem tells controller channel is ready for usage
    output logic [NUM_CHANNELS-1:0] mem_valid,
    output logic [CACHE_LINE_BYTE_SIZE-1:0] mem_we [NUM_CHANNELS],
    output logic [ADDR_WIDTH-1:0] mem_addr [NUM_CHANNELS],
    output logic [ADDR_WIDTH-1:0] mem_data [NUM_CHANNELS],
    
    input logic [NUM_CHANNELS-1:0] mem_resp_valid, // mem tells controller when done
    input logic [ADDR_WIDTH-1:0] mem_resp_data [NUM_CHANNELS]
    );
    
//    typedef enum logic [2:0] {
//        IDLE, R_WAIT, W_WAIT, R_IN_PROG, W_IN_PROG
//    } state_t;
//    state_t [NUM_CHANNELS-1:0] s;

    // comb next output signals
    // req_ready is an asynchronous output, but is updated on clock edge (no timing issues)
    // logic [NUM_USERS-1:0] next_req_resp_valid; 
    // logic [ADDR_WIDTH-1:0] next_req_resp_data [NUM_USERS];
    logic [NUM_CHANNELS-1:0] next_mem_valid;
    logic [CACHE_LINE_BYTE_SIZE-1:0] next_mem_we [NUM_CHANNELS];
    logic [ADDR_WIDTH-1:0] next_mem_addr [NUM_CHANNELS];
    logic [ADDR_WIDTH-1:0] next_mem_data [NUM_CHANNELS];
    
    // address decoding - process begins with which channel each user wants
    logic [$clog2(NUM_CHANNELS)-1:0] user_channel [NUM_USERS];
    // lowest bit used is right above the last bit that changes within a (power of 2) cache line, ex: bit 7 for 64 bytes
    // # of bits based on NUM_CHANNELS, ex: 3 bits for 8 channels
    genvar u, c;
    generate
        for (u = 0; u < NUM_USERS; u++) 
            assign user_channel[u] = req_addr[u][$clog2((CACHE_LINE_BYTE_SIZE)+1)+:($clog2(NUM_CHANNELS)-1)];
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
                .c(c) // just for display statement
            );
        end
    endgenerate
    
    // request servicing - access memory using granted channel users
    logic [NUM_CHANNELS-1:0] next_pending, pending; // keep track of channel state
    logic [$clog2(NUM_USERS)-1:0] next_user_granted [NUM_CHANNELS], user_granted [NUM_CHANNELS]; // track user 
    logic [NUM_USERS-1:0] next_req_resp_valid;
    logic [ADDR_WIDTH-1:0] next_req_resp_data [NUM_USERS];
    
    always_comb begin
        // default resp signals
        next_req_resp_valid = 0;
        for (int u = 0; u < NUM_USERS; u++) begin
            next_req_resp_data[u] = req_resp_data[u];
        end
        
        for (int c = 0; c < NUM_CHANNELS; c++) begin 
            next_mem_addr[c] = mem_addr[c]; next_mem_data[c] = mem_data[c]; next_mem_we[c] = mem_we[c]; 
            next_mem_valid[c] = 0; next_pending[c] = 0; // default values
        
            if (|channel_grants[c]) begin // upon channel first being granted
                for (int u = 0; u < NUM_USERS; u++) begin
                    if (channel_grants[c][u]) begin 
                        next_mem_addr[c] = req_addr[u];
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
                mem_addr[c] <= next_mem_addr[c][ADDR_WIDTH-1:2]; // word (4 bytes) based mem, addr/4
                mem_data[c] <= next_mem_data[c];
            end
            for (int u = 0; u < NUM_USERS; u++) begin
                req_resp_data[u] <= next_req_resp_data[u];
            end
        end
    end
    
endmodule

/* 
    use a simple arbiter with basic rotating priority
    we assume for simplicity there is no real priority within each block/warp/thread
*/
module arbiter #(
        parameter int NUM_USERS, 
        parameter int NUM_CHANNELS
    )(
        input logic clk, reset,
        input logic channel_free,
        input logic [NUM_USERS-1:0] channel_reqs,
        output logic [NUM_USERS-1:0] channel_grants,
        output logic [NUM_USERS-1:0] req_ready,
        input logic [$clog2(NUM_CHANNELS)-1:0] c
    );
    
    // priority will essentially be one-hot, only one user per channel gets a value of 1 at a time
    logic [NUM_USERS-1:0] prio_mask;
    
    typedef enum {
        READY, BUSY
    } state_t; // 
    state_t s, next_s;
    
    always_comb begin
        channel_grants = 0; req_ready = 0; // default
        case (s)
            READY: begin // in READY check for possible grants
                next_s = READY;
                for (int u = 0; u < NUM_USERS; u++) begin
                    if (channel_reqs[u] && prio_mask[u]) begin
                        // these signals will only be 1 cycle long due to channel_reqs (req_valid)
                        channel_grants[u] = 1'b1;
                        req_ready = 1; // handshake to user that req has been granted
                        next_s = BUSY;
                        $display("Mem_Ctr: Granting user %d to channel %d", u, c);
                    end
                end
            end
            BUSY: begin // in BUSY wait until req_ready 
                if (channel_free) next_s = READY;
                else next_s = BUSY;
            end
        endcase
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin // on reset start with user 0
            prio_mask <= 1; 
            s <= READY;
        end else if (channel_free) begin // rotate left only once channel frees up again
            prio_mask <= {prio_mask[NUM_USERS-2:0], prio_mask[NUM_USERS-1]};
            s <= next_s;
        end
    end

endmodule
