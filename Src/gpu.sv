`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/24/2025 02:15:22 PM
// Design Name: 
// Module Name: gpu
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

module gpu #(
    parameter int NUM_DATA_CHANNELS = 8,
    parameter int NUM_INSTR_CHANNELS = 8,
    parameter int NUM_CORES = 4,
    parameter int WARPS_PER_CORE = 2, 
    parameter int THREADS_PER_WARP = 32,
    parameter int CACHE_LINE_BYTE_SIZE = 4
    )(
    input logic clk, reset,
    input kernel_config_t kernel_config,
    input logic kernel_start, // one cycle
    output logic kernel_done,
    // instr mem
    output logic [NUM_INSTR_CHANNELS-1:0] instr_mem_valid,
    output instr_mem_addr_t [$clog2(NUM_INSTR_CHANNELS)-1:0] instr_mem_addr,
    input logic [NUM_INSTR_CHANNELS-1:0] instr_mem_ready,
    input instr_t [$clog2(NUM_INSTR_CHANNELS)-1:0] instr_mem_resp_data,
    input logic [NUM_INSTR_CHANNELS-1:0] instr_mem_resp_valid,
    // data mem
    output logic [NUM_DATA_CHANNELS-1:0] data_mem_valid,
    output data_mem_addr_t [$clog2(NUM_DATA_CHANNELS)-1:0] data_mem_addr,
    output data_t [$clog2(NUM_DATA_CHANNELS)-1:0] data_mem_data,
    output logic [$clog2(NUM_DATA_CHANNELS)-1:0][CACHE_LINE_BYTE_SIZE-1:0] data_mem_we,
    input logic [NUM_DATA_CHANNELS-1:0] data_mem_ready,
    input logic [NUM_DATA_CHANNELS-1:0] data_mem_resp_ready,
    input data_t [$clog2(NUM_DATA_CHANNELS)-1:0] data_mem_resp_data
    );
    
    // store kernel_config info
    kernel_config_t kernel_config_reg; 
    always @(posedge clk or negedge reset) begin
        // top level module doesn't need any reset logic
        if (!reset) begin end
        else if (kernel_start) begin
            kernel_config_reg <= kernel_config;
            $display("////////////////////////////////////////////");
            $display("Kernel is configurated with:");
            $display("%d blocks with %d warps per block", kernel_config.num_blocks, kernel_config.num_warps_per_block);
            $display("Base instr addr: %h", kernel_config.base_instr_addr);
            $display("Base data addr: %h", kernel_config.base_data_addr);
            $display("////////////////////////////////////////////");
        end
    end
    
    // core dispatcher signals
    logic [NUM_CORES-1:0] core_done;
    logic [NUM_CORES-1:0] cores_in_use, past_cores_in_use, core_start; 
    always_ff @(posedge clk or negedge reset) begin 
        if (!reset) begin end
        else past_cores_in_use <= cores_in_use;
    end
    assign core_start = ((~past_cores_in_use) & cores_in_use); // for one cycle start to core
    data_t [$clog2(NUM_CORES)-1:0] core_id, core_block_id;   
             
    // fetcher signals
    // instr mem - one per warp
    localparam int NUM_FETCHERS = NUM_CORES * WARPS_PER_CORE; // one per core (pc same within warp)
    logic [NUM_FETCHERS-1:0] fetcher_mem_ready;
    logic [NUM_FETCHERS-1:0] fetcher_mem_valid;
    instr_mem_addr_t [$clog2(NUM_FETCHERS)-1:0] fetcher_mem_addr;
//    instr_t [$clog2(NUM_FETCHERS)-1:0] fetcher_mem_data; // unused
//    logic [NUM_FETCHERS-1:0][CACHE_LINE_BYTE_SIZE-1:0] fetcher_mem_we; // unused
    logic [NUM_FETCHERS-1:0] fetcher_mem_resp_ready;
    instr_t [$clog2(NUM_FETCHERS)-1:0] fetcher_mem_resp_data;
    // lsu signals
    localparam int NUM_LSUS = NUM_CORES * (THREADS_PER_WARP + 1); // one per thread + extra lsu for warp scalar regs
    logic [NUM_LSUS-1:0] lsu_mem_ready;
    logic [NUM_LSUS-1:0] lsu_mem_valid;
    data_mem_addr_t [$clog2(NUM_LSUS)-1:0] lsu_mem_addr;
    data_t [$clog2(NUM_LSUS)-1:0] lsu_mem_data;
    logic [NUM_LSUS-1:0][CACHE_LINE_BYTE_SIZE-1:0] lsu_mem_we;
    logic [NUM_LSUS-1:0] lsu_mem_resp_ready;
    data_t [$clog2(NUM_LSUS)-1:0] lsu_mem_resp_data;
    
    dispatcher #(
        .NUM_CORES(NUM_CORES)
    ) dispatcher_inst(
        .clk(clk), .reset(reset), .start(kernel_start),
        .kernel_config(kernel_config_reg),
        // core states
        .core_done(core_done), 
        .cores_in_use(cores_in_use), 
        .core_block_id(core_block_id), // each core gets its own block id
        // kernel execution
        .finished(kernel_done)
    );
    
    // instr mem controller
    mem_controller #(
        .DATA_WIDTH(`INSTR_WIDTH),
        .ADDR_WIDTH(`INSTR_MEM_ADDR_WIDTH),
        .NUM_USERS(NUM_FETCHERS),
        .NUM_CHANNELS(NUM_INSTR_CHANNELS)
    ) instr_mem_controller(
        .clk(clk), .reset(reset),
        // user requests interface used by fetch/LSUs
        .req_ready(fetcher_mem_ready), // tells user controller is ready for requests
        .req_valid(fetcher_mem_valid),
        .req_we(0),
        .req_addr(fetcher_mem_addr),
        .req_data(0),
        
        .req_resp_valid(fetcher_mem_resp_ready), // tells user when mem access is done
        .req_resp_data(fetcher_mem_resp_data),
        // mem interface
        // note this is restricted by # of mem channels, which may be smaller than # of users
        .mem_ready(instr_mem_ready), // mem tells controller channel is ready for usage
        .mem_valid(instr_mem_valid),
        .mem_we(0),
        .mem_addr(instr_mem_addr),
        .mem_data(0),
        
        .mem_resp_valid(instr_mem_resp_valid), // mem tells controller when done
        .mem_resp_data(instr_mem_resp_data)
    );
    
    // data mem controller
    mem_controller #(
        .DATA_WIDTH(`DATA_WIDTH),
        .ADDR_WIDTH(`DATA_MEM_ADDR_WIDTH),
        .NUM_USERS(NUM_LSUS),
        .NUM_CHANNELS(NUM_DATA_CHANNELS)
    ) data_mem_controller(
        .clk(clk), .reset(reset),
        // user requests interface used by fetch/LSUs
        .req_ready(lsu_mem_ready), // tells user controller is ready for requests
        .req_valid(lsu_mem_valid),
        .req_we(lsu_mem_we),
        .req_addr(lsu_mem_addr),
        .req_data(lsu_mem_data),
        
        .req_resp_valid(lsu_mem_resp_ready), // tells user when mem access is done
        .req_resp_data(lsu_mem_resp_data),
        // mem interface
        // note this is restricted by # of mem channels, which may be smaller than # of users
        .mem_ready(data_mem_ready), // mem tells controller channel is ready for usage
        .mem_valid(data_mem_valid),
        .mem_we(data_mem_we),
        .mem_addr(data_mem_addr),
        .mem_data(data_mem_data),
        
        .mem_resp_valid(data_mem_resp_valid), // mem tells controller when done
        .mem_resp_data(data_mem_resp_data)
    );
    
    // cores    
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c++) begin : cores
        
            localparam int fetcher_index = c * WARPS_PER_CORE; // each fetcher gets assigned to its respective warp
            localparam int lsu_index = c * (THREADS_PER_WARP + 1); // each lsu gets assigned to its respective thread
            
            core #(
                .WARPS_PER_CORE(WARPS_PER_CORE), // if assigning 1 block per core, this is same as num_warps_per_block
                .THREADS_PER_WARP(THREADS_PER_WARP)
            ) core_inst(
                .clk(clk), .reset(reset),
                // core info
                .core_start(core_start[1 << c]), // one cycle only
                .core_done(core_done[1 << c]),
                .kernel_config(kernel_config_reg),
                .core_id(c), .core_block_id(core_block_id[c]), 
                // instr mem - one per warp
                .instr_mem_valid(fetcher_mem_valid[(1 << fetcher_index)+:WARPS_PER_CORE]),
                .instr_mem_addr(fetcher_mem_addr[(fetcher_index)+:WARPS_PER_CORE]),
                .instr_mem_resp_ready(fetcher_mem_resp_ready[(1 << fetcher_index)+:WARPS_PER_CORE]),
                .instr_mem_resp_data(fetcher_mem_resp_data[(fetcher_index)+:WARPS_PER_CORE]),
                // data mem - one per thread - extra lsu for warp scalar regs
                .data_mem_valid(lsu_mem_valid[(1 << lsu_index)+:(THREADS_PER_WARP+1)]),
                .data_mem_addr(lsu_mem_addr[(lsu_index)+:(THREADS_PER_WARP+1)]),
                .data_mem_data(lsu_mem_data[(lsu_index)+:(THREADS_PER_WARP+1)]),
                .data_mem_we(lsu_mem_we[(1 << lsu_index)+:(THREADS_PER_WARP+1)]),
                .data_mem_resp_ready(lsu_mem_resp_ready[(1 << lsu_index)+:(THREADS_PER_WARP+1)]),
                .data_mem_resp_data(lsu_mem_resp_data[(lsu_index)+:(THREADS_PER_WARP+1)])
            );
        end
    endgenerate
    
endmodule
