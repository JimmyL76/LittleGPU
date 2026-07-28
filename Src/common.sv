`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/27/2025 10:02:22 PM
// Design Name: 
// Module Name: common
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


`ifndef COMMON_SV
`define COMMON_SV

package common_pkg;
    // architecture fundamentals (fixed once set)
    parameter int DATA_WIDTH          = 32;
    parameter int INSTR_WIDTH         = 32;
    parameter int DATA_MEM_ADDR_WIDTH = 32;
    parameter int INSTR_MEM_ADDR_WIDTH = 32;

    typedef logic [DATA_WIDTH-1:0] data_t;
    typedef logic [INSTR_WIDTH-1:0] instr_t;
    typedef logic [DATA_MEM_ADDR_WIDTH-1:0] data_mem_addr_t;
    typedef logic [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr_t;
    
    // these all represent software-configurable parameters 
    typedef struct packed {
        data_t num_blocks; // max # of blocks = 2^32 - 1
        data_t num_warps_per_block;
        instr_mem_addr_t base_instr_addr;
        data_mem_addr_t base_data_addr;
    } kernel_config_t;
    
    // warp state enum
    typedef enum logic [2:0] {
        WARP_IDLE,
        WARP_FETCH,
        WARP_DECODE,
        WARP_EXECUTE,
        WARP_MEMORY,
        WARP_WRITEBACK,
        WARP_DONE
    } warp_state_t;
    
    // lsu state enum
    typedef enum logic [1:0] {
        LSU_IDLE,
        LSU_REQUESTING,
        LSU_DONE
    } lsu_state_t;
    
    // fetch state enum
    typedef enum logic [0:0] {
        FETCHER_IDLE,
        FETCHER_FETCHING
    } fetcher_state_t;

    // stall reason for parked warp
    // reserved encodings left unused for future divergence and barrier waits
    typedef enum logic [2:0] {
        STALL_NONE      = 3'd0,  // warp is ready or actively progressing
        STALL_WAIT_MEM  = 3'd1,  // parked awaiting tagged memory response
        STALL_WAIT_EXEC = 3'd2,  // parked awaiting execute resource
        STALL_RSVD_3    = 3'd3,  // reserved encoding for future reconverge wait
        STALL_RSVD_4    = 3'd4   // reserved encoding for future barrier wait
    } stall_reason_t;

    // latency-hiding resource parameters threaded into modules in later tasks
    // all values are assumed to be at minimum >= 2 and stated inline at declaration
    parameter int SCOREBOARD_DEPTH = 2;        // concurrent outstanding warp memory ops default 2
    parameter int MSHR_COUNT       = 2;        // bounded mshr pool size default 2
    parameter int COAL_OUTSTANDING = 2;        // concurrent outstanding line requests default 2
    parameter int RESP_BUF_DEPTH   = 2;        // per-user response buffer depth default 2

    // core-internal max concurrent outstanding requests bounds unique tag space
    parameter int MAX_OUTSTANDING_PER_CORE = SCOREBOARD_DEPTH;  // core-internal max concurrent outstanding default 2
    // request tag width is clog2 of max outstanding giving 1 bit at default depth 2
    parameter int REQ_TAG_WIDTH = $clog2(MAX_OUTSTANDING_PER_CORE);

 endpackage
 
 // module since functions can't take parameters
module utility #(
    parameter int NUM_CORES = 32
    )(
    input logic [NUM_CORES-1:0] nth_free_core,
    output logic [$clog2(NUM_CORES)-1:0] onehot_to_binary 
    );
    always_comb begin
        onehot_to_binary = -1; // default all 1s, although should never use output if none are true
        for (int i = 0; i < NUM_CORES; i++) 
            if (nth_free_core[i]) onehot_to_binary = i; // this will only be true once
    end
endmodule
    
`endif
