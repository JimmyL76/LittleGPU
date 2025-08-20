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
    `define DATA_WIDTH 32
    `define INSTR_WIDTH 32
    `define DATA_MEM_ADDR_WIDTH 32
    `define INSTR_MEM_ADDR_WIDTH 32
    
    typedef logic [`DATA_WIDTH-1:0] data_t;
    typedef logic [`INSTR_WIDTH-1:0] instr_t;
    typedef logic [`DATA_MEM_ADDR_WIDTH-1:0] data_mem_addr_t;
    typedef logic [`INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr_t;
    
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
        WARP_REQUEST,
        WARP_WAIT,
        WARP_EXECUTE,
        WARP_UPDATE,
        WARP_DONE
    } warp_state_t;
    
    // lsu state enum
    typedef enum logic [1:0] {
        LSU_IDLE,
        LSU_REQUESTING,
        LSU_DONE
    } lsu_state_t;
    
    // fetch state enum
    typedef enum logic [1:0] {
        FETCHER_IDLE,
        FETCHER_FETCHING,
        FETCHER_DONE
    } fetcher_state_t;
    
                
 endpackage
 
 // used module since functions can't take parameters
module utility #(
        parameter int NUM_CORES = 32
        )(
        input logic [NUM_CORES-1:0] nth_free_core,
        output logic [$clog2(NUM_CORES)-1:0] onehot_to_binary 
        );
        always_comb begin
            for (int i = 0; i < NUM_CORES; i++) 
                if (nth_free_core[i]) onehot_to_binary = i; // this will only be true once
        end
endmodule
    
`endif
