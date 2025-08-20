`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/03/2025 09:31:10 AM
// Design Name: 
// Module Name: core
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

module core #(
    parameter int WARPS_PER_CORE, // if assigning 1 block per core, this is same as num_warps_per_block
    parameter int THREADS_PER_WARP
    )(
    input logic clk, reset,
    // core info
    input logic start, 
    output logic done, // NOTE: to skip 1 cycle delay, done comes 1 cycle before core finishes
    input kernel_config_t kernel_config,
    input data_t core_block_id, 
    // instr mem
    output logic [WARPS_PER_CORE-1:0] instr_mem_valid,
    output instr_mem_addr_t [$clog2(WARPS_PER_CORE)-1:0] instr_mem_addr,
    input logic [WARPS_PER_CORE-1:0] instr_mem_resp_ready,
    input instr_t [$clog2(WARPS_PER_CORE)-1:0] instr_mem_resp_data,
    // data mem - extra lsu for warp scalar regs
    output logic [THREADS_PER_WARP:0] data_mem_valid,
    output data_mem_addr_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_addr,
    output data_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_data,
    output logic [THREADS_PER_WARP:0] data_mem_we,
    input logic [THREADS_PER_WARP:0] data_mem_resp_ready,
    input data_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_resp_data
    );
    
    // warp signals    
    warp_state_t [$clog2(WARPS_PER_CORE)-1:0] warp_state;
    fetcher_state_t [$clog2(WARPS_PER_CORE)-1:0] fetcher_state;
    
    logic [$clog2(WARPS_PER_CORE)-1:0] current_warp;
    warp_state_t current_warp_state; assign current_warp_state = warp_state[current_warp];
    // per warp module signals
    instr_mem_addr_t [$clog2(WARPS_PER_CORE)-1:0] pc, next_pc;
    
    instr_t [$clog2(WARPS_PER_CORE)-1:0] fetched_instr;
    
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] Scalar;
    logic [$clog2(WARPS_PER_CORE)-1:0] LdReg;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] IsBR_J;
    logic [$clog2(WARPS_PER_CORE)-1:0] DMemEN;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] DataSize;
    logic [$clog2(WARPS_PER_CORE)-1:0] DMemR_W;
    logic [$clog2(WARPS_PER_CORE)-1:0] Usign;
    logic [$clog2(WARPS_PER_CORE)-1:0] RS1Mux;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] BR;
    logic [$clog2(WARPS_PER_CORE)-1:0][3:0] ALUK;
    logic [$clog2(WARPS_PER_CORE)-1:0] RS2Mux;
    logic [$clog2(WARPS_PER_CORE)-1:0] Finish;
    logic [$clog2(WARPS_PER_CORE)-1:0][4:0] rs1_addr, rs2_addr, rd_addr; 
    data_t [$clog2(WARPS_PER_CORE)-1:0] IMM;
    
    // scalar registers
    // if THREADS_PER_WARP < data_t, upper bits are cut off of scalar registers[EXEC_MASK_REG]
    logic [$clog2(WARPS_PER_CORE)-1:0][THREADS_PER_WARP-1:0] warp_execution_mask;
    logic [THREADS_PER_WARP-1:0] current_warp_execution_mask; 
    assign current_warp_execution_mask = warp_execution_mask[current_warp];
    data_t s_rs1, s_rs2, s_lsu_out, s_alu_out;
    lsu_state_t s_lsu_state;
        
    // per thread module signals
    data_t [$clog2(THREADS_PER_WARP)-1:0] rs1, rs2;
    data_t [$clog2(THREADS_PER_WARP)-1:0] alu_out; 
    
    logic [$clog2(THREADS_PER_WARP)-1:0] core_we;
    lsu_state_t [$clog2(THREADS_PER_WARP)-1:0] lsu_state;
    data_t [$clog2(THREADS_PER_WARP)-1:0] lsu_out;
    
    
        
endmodule
