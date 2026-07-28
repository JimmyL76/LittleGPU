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
//   - data path uses line-wide transactions (MEM_LINE_BYTES bytes per request)
//   - per-core vector coalescer collapses THREADS_PER_WARP word requests into one
//     line transaction, scalar lsu uses 1-thread coalescer as bus width adapter
//   - instr path stays word-wide (no coalescing - one fetcher per warp already)
// 
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;

module gpu #(
    parameter int NUM_DATA_CHANNELS = 8,
    parameter int NUM_INSTR_CHANNELS = 8,
    parameter int NUM_CORES = 4,
    parameter int WARPS_PER_CORE = 2, 
    parameter int THREADS_PER_WARP = 32,
    // bytes per memory transaction or "line", not cache line, just unit of one mem request
    // 128 = THREADS_PER_WARP * 4, so fully-coalesced warp load/store is one transaction
    // must be power of 2 and >= 4 (one word)
    parameter int MEM_LINE_BYTES = 128
    )(
    input logic clk, reset,
    input kernel_config_t kernel_config,
    input logic kernel_start, // one cycle
    output logic kernel_done,
    // instr mem - word-wide
    // addr is dense per-channel line address, byte width minus line-offset and channel bits
    output logic [NUM_INSTR_CHANNELS-1:0] instr_mem_valid,
    output logic [INSTR_MEM_ADDR_WIDTH-$clog2(INSTR_WIDTH/8)-$clog2(NUM_INSTR_CHANNELS)-1:0] instr_mem_addr [NUM_INSTR_CHANNELS],
    input logic [NUM_INSTR_CHANNELS-1:0] instr_mem_ready,
    input instr_t instr_mem_resp_data [NUM_INSTR_CHANNELS],
    input logic [NUM_INSTR_CHANNELS-1:0] instr_mem_resp_valid,
    output logic [NUM_INSTR_CHANNELS-1:0] instr_mem_resp_ready,
    // data mem - line-wide (data, we, resp_data scaled by MEM_LINE_BYTES)
    output logic [NUM_DATA_CHANNELS-1:0] data_mem_valid,
    output logic [DATA_MEM_ADDR_WIDTH-$clog2(MEM_LINE_BYTES)-$clog2(NUM_DATA_CHANNELS)-1:0] data_mem_addr [NUM_DATA_CHANNELS],
    output logic [MEM_LINE_BYTES*8-1:0] data_mem_data [NUM_DATA_CHANNELS],
    output logic [MEM_LINE_BYTES-1:0] data_mem_we [NUM_DATA_CHANNELS],
    input logic [NUM_DATA_CHANNELS-1:0] data_mem_ready,
    input logic [NUM_DATA_CHANNELS-1:0] data_mem_resp_valid,
    output logic [NUM_DATA_CHANNELS-1:0] data_mem_resp_ready,
    input logic [MEM_LINE_BYTES*8-1:0] data_mem_resp_data [NUM_DATA_CHANNELS]
    );
    
    localparam int LINE_BITS = MEM_LINE_BYTES * 8;
    
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
    data_t core_block_id [NUM_CORES];
             
    // fetcher signals
    // instr mem - one per warp
    localparam int NUM_FETCHERS = NUM_CORES * WARPS_PER_CORE; // one per core (pc same within warp)
    logic [NUM_FETCHERS-1:0] fetcher_mem_ready;
    logic [NUM_FETCHERS-1:0] fetcher_mem_valid;
    instr_mem_addr_t fetcher_mem_addr [NUM_FETCHERS];
    logic [NUM_FETCHERS-1:0] fetcher_mem_resp_valid;
    logic [NUM_FETCHERS-1:0] fetcher_mem_resp_ready;
    instr_t fetcher_mem_resp_data [NUM_FETCHERS];
    // instr fetch is read-only, drive zero we/data to controller, leave its outputs in unused nets
    logic [(INSTR_WIDTH/8)-1:0] fetcher_mem_we [NUM_FETCHERS];
    instr_t fetcher_mem_data [NUM_FETCHERS];
    logic [(INSTR_WIDTH/8)-1:0] instr_mem_we_unused [NUM_INSTR_CHANNELS];
    instr_t instr_mem_data_unused [NUM_INSTR_CHANNELS];
    always_comb begin
        for (int i = 0; i < NUM_FETCHERS; i++) begin
            fetcher_mem_we[i]   = '0;
            fetcher_mem_data[i] = '0;
        end
    end
    
    // lsu signals - per-thread word-wide, one per thread + extra lsu for warp scalar regs
    localparam int NUM_LSUS = NUM_CORES * (THREADS_PER_WARP + 1);
    logic [NUM_LSUS-1:0] lsu_mem_valid;
    data_mem_addr_t lsu_mem_addr [NUM_LSUS];
    data_t lsu_mem_data [NUM_LSUS];
    logic [(DATA_WIDTH/8)-1:0] lsu_mem_we [NUM_LSUS];
    logic [NUM_LSUS-1:0] lsu_mem_resp_valid;
    logic [NUM_LSUS-1:0] lsu_mem_resp_ready;
    data_t lsu_mem_resp_data [NUM_LSUS];
    
    // coalesced signals - 2 user ports per core (1 vector + 1 scalar), line-wide
    localparam int NUM_DATA_USERS = NUM_CORES * 2;
    logic [NUM_DATA_USERS-1:0] coal_mem_valid;
    data_mem_addr_t coal_mem_addr [NUM_DATA_USERS]; // always just one base addr
    logic [LINE_BITS-1:0] coal_mem_data [NUM_DATA_USERS];
    logic [MEM_LINE_BYTES-1:0] coal_mem_we [NUM_DATA_USERS];
    logic [NUM_DATA_USERS-1:0] coal_mem_resp_valid;
    logic [NUM_DATA_USERS-1:0] coal_mem_resp_ready;
    logic [LINE_BITS-1:0] coal_mem_resp_data [NUM_DATA_USERS];
    
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
        .DATA_WIDTH(INSTR_WIDTH),
        .ADDR_WIDTH(INSTR_MEM_ADDR_WIDTH),
        .NUM_USERS(NUM_FETCHERS),
        .NUM_CHANNELS(NUM_INSTR_CHANNELS),
        .MEM_LINE_BYTES(INSTR_WIDTH/8) // instr stays word-sized
    ) instr_mem_controller(
        .clk(clk), .reset(reset),
        // user requests interface used by fetch/LSUs
        .req_ready(fetcher_mem_ready), // tells user controller is ready for requests
        .req_valid(fetcher_mem_valid),
        .req_we(fetcher_mem_we),
        .req_addr(fetcher_mem_addr),
        .req_data(fetcher_mem_data),
        
        .req_resp_valid(fetcher_mem_resp_valid), // tells user when mem access is done
        .req_resp_ready(fetcher_mem_resp_ready),
        .req_resp_data(fetcher_mem_resp_data),
        // mem interface
        .mem_ready(instr_mem_ready), // mem tells controller channel is ready for usage
        .mem_valid(instr_mem_valid),
        .mem_we(instr_mem_we_unused),
        .mem_addr(instr_mem_addr),
        .mem_data(instr_mem_data_unused),
        
        .mem_resp_valid(instr_mem_resp_valid), // mem tells controller when done
        .mem_resp_ready(instr_mem_resp_ready),
        .mem_resp_data(instr_mem_resp_data)
    );
    
    // data mem controller - line-wide, one user port per (core, vec/scalar)
    mem_controller #(
        .DATA_WIDTH(LINE_BITS),
        .ADDR_WIDTH(DATA_MEM_ADDR_WIDTH),
        .NUM_USERS(NUM_DATA_USERS),
        .NUM_CHANNELS(NUM_DATA_CHANNELS),
        .MEM_LINE_BYTES(MEM_LINE_BYTES)
    ) data_mem_controller(
        .clk(clk), .reset(reset),
        // user requests interface, used by coalescers (vec/scalar per core)
        .req_ready(), // unconnected - coalescer doesn't backpressure on it
        .req_valid(coal_mem_valid),
        .req_we(coal_mem_we),
        .req_addr(coal_mem_addr),
        .req_data(coal_mem_data),
        
        .req_resp_valid(coal_mem_resp_valid), // tells user when mem access is done
        .req_resp_ready(coal_mem_resp_ready),
        .req_resp_data(coal_mem_resp_data),
        // mem interface
        .mem_ready(data_mem_ready), // mem tells controller channel is ready for usage
        .mem_valid(data_mem_valid),
        .mem_we(data_mem_we),
        .mem_addr(data_mem_addr),
        .mem_data(data_mem_data),
        
        .mem_resp_valid(data_mem_resp_valid), // mem tells controller when done
        .mem_resp_ready(data_mem_resp_ready),
        .mem_resp_data(data_mem_resp_data)
    );
    
    // per-core coalescers + cores
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c++) begin : core_inst
            localparam int fetcher_index = c * WARPS_PER_CORE; // each fetcher gets assigned to its respective warp
            localparam int lsu_index = c * (THREADS_PER_WARP + 1); // each lsu gets assigned to its respective thread
            localparam int vec_user = c * 2;
            localparam int scl_user = c * 2 + 1;
            
            // vector coalescer - THREADS_PER_WARP per-thread lsus -> 1 line-wide user port
            coalescer #(
                .THREADS_PER_WARP(THREADS_PER_WARP),
                .MEM_LINE_BYTES(MEM_LINE_BYTES)
            ) vec_coal (
                .clk(clk), .reset(reset),
                .lsu_valid(lsu_mem_valid[lsu_index +: THREADS_PER_WARP]),
                .lsu_addr(lsu_mem_addr[lsu_index +: THREADS_PER_WARP]),
                .lsu_data(lsu_mem_data[lsu_index +: THREADS_PER_WARP]),
                .lsu_we(lsu_mem_we[lsu_index +: THREADS_PER_WARP]),
                .lsu_resp_valid(lsu_mem_resp_valid[lsu_index +: THREADS_PER_WARP]),
                .lsu_resp_ready(lsu_mem_resp_ready[lsu_index +: THREADS_PER_WARP]),
                .lsu_resp_data(lsu_mem_resp_data[lsu_index +: THREADS_PER_WARP]),
                
                .mem_valid(coal_mem_valid[vec_user]),
                .mem_addr(coal_mem_addr[vec_user]),
                .mem_data(coal_mem_data[vec_user]),
                .mem_we(coal_mem_we[vec_user]),
                .mem_resp_valid(coal_mem_resp_valid[vec_user]),
                .mem_resp_ready(coal_mem_resp_ready[vec_user]),
                .mem_resp_data(coal_mem_resp_data[vec_user])
            );
            
            // scalar coalescer - +1 lsu per core, just one word to one line
            // 1-element arrays since coalescer ports are unpacked array
            logic [0:0] scl_lsu_valid_arr;
            data_mem_addr_t scl_lsu_addr_arr [1];
            data_t scl_lsu_data_arr [1];
            logic [(DATA_WIDTH/8)-1:0] scl_lsu_we_arr [1];
            logic [0:0] scl_lsu_resp_valid_arr;
            logic [0:0] scl_lsu_resp_ready_arr;
            data_t scl_lsu_resp_data_arr [1];
            
            assign scl_lsu_valid_arr[0] = lsu_mem_valid[lsu_index + THREADS_PER_WARP];
            assign scl_lsu_addr_arr[0] = lsu_mem_addr[lsu_index + THREADS_PER_WARP];
            assign scl_lsu_data_arr[0] = lsu_mem_data[lsu_index + THREADS_PER_WARP];
            assign scl_lsu_we_arr[0] = lsu_mem_we[lsu_index + THREADS_PER_WARP];
            assign scl_lsu_resp_ready_arr[0] = lsu_mem_resp_ready[lsu_index + THREADS_PER_WARP];
            assign lsu_mem_resp_valid[lsu_index + THREADS_PER_WARP] = scl_lsu_resp_valid_arr[0];
            assign lsu_mem_resp_data[lsu_index + THREADS_PER_WARP] = scl_lsu_resp_data_arr[0];
            
            coalescer #(
                .THREADS_PER_WARP(1),
                .MEM_LINE_BYTES(MEM_LINE_BYTES)
            ) scl_coal (
                .clk(clk), .reset(reset),
                .lsu_valid(scl_lsu_valid_arr),
                .lsu_addr(scl_lsu_addr_arr),
                .lsu_data(scl_lsu_data_arr),
                .lsu_we(scl_lsu_we_arr),
                .lsu_resp_valid(scl_lsu_resp_valid_arr),
                .lsu_resp_ready(scl_lsu_resp_ready_arr),
                .lsu_resp_data(scl_lsu_resp_data_arr),
                
                .mem_valid(coal_mem_valid[scl_user]),
                .mem_addr(coal_mem_addr[scl_user]),
                .mem_data(coal_mem_data[scl_user]),
                .mem_we(coal_mem_we[scl_user]),
                .mem_resp_valid(coal_mem_resp_valid[scl_user]),
                .mem_resp_ready(coal_mem_resp_ready[scl_user]),
                .mem_resp_data(coal_mem_resp_data[scl_user])
            );
            
            core #(
                .WARPS_PER_CORE(WARPS_PER_CORE), // if assigning 1 block per core, this is same as num_warps_per_block
                .THREADS_PER_WARP(THREADS_PER_WARP)
            ) core_inst(
                .clk(clk), .reset(reset),
                // core info
                .core_start(core_start[c]), // one cycle only
                .core_done(core_done[c]),
                .kernel_config(kernel_config_reg),
                .core_id(c), .core_block_id(core_block_id[c]), 
                // instr mem - one per warp
                .instr_mem_valid(fetcher_mem_valid[fetcher_index +: WARPS_PER_CORE]),
                .instr_mem_addr(fetcher_mem_addr[fetcher_index +: WARPS_PER_CORE]),
                .instr_mem_resp_valid(fetcher_mem_resp_valid[fetcher_index +: WARPS_PER_CORE]),
                .instr_mem_resp_ready(fetcher_mem_resp_ready[fetcher_index +: WARPS_PER_CORE]),
                .instr_mem_resp_data(fetcher_mem_resp_data[fetcher_index +: WARPS_PER_CORE]),
                // data mem - one per thread + extra lsu for warp scalar regs
                // word-wide, coalescers adapt to line-wide for controller
                .data_mem_valid(lsu_mem_valid[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_addr(lsu_mem_addr[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_data(lsu_mem_data[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_we(lsu_mem_we[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_resp_valid(lsu_mem_resp_valid[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_resp_ready(lsu_mem_resp_ready[lsu_index +: (THREADS_PER_WARP+1)]),
                .data_mem_resp_data(lsu_mem_resp_data[lsu_index +: (THREADS_PER_WARP+1)])
            );
        end
    endgenerate
    
endmodule
