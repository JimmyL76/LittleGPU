`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/19/2025 09:34:19 PM
// Design Name: 
// Module Name: regs
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

module regs #(
    parameter int THREADS_PER_WARP,
    parameter int REGS_PER_THREAD
    )(
    input logic clk, reset, 
    input warp_state_t warp_state,
    input logic warp_enable,
    input logic [THREADS_PER_WARP-1:0] thread_enable, // execution mask for conditionals
    // warp/block identifiers
    input data_t warp_id, block_id, block_size,
    // data + control signals
    input logic [1:0] Scalar,
    input logic LdReg,
    input logic [1:0] IsBR_J,
    input logic DMemEN,
    // data/addr signals
    input logic rs1_addr, rs2_addr, rd_addr, 
    // output reg values, per thread
    output data_t [$clog2(THREADS_PER_WARP)-1:0] rs1, rs2,
    // input load reg values, per thread
    input data_t [$clog2(THREADS_PER_WARP)-1:0] alu_out, lsu_out, next_pc
    );
    
    // designated registers for indexing, i = block id * block size + thread id
    localparam int ZERO_REG = 0;
    localparam int THREAD_ID_REG = 1;
    localparam int BLOCK_ID_REG = 2;
    localparam int BLOCK_SIZE_REG = 3;
    
    // each thread gets its own set of 32 registers (on top of potentially 32 threads per warp)
    data_t [$clog2(THREADS_PER_WARP)-1:0][REGS_PER_THREAD-1:0] registers;
    
    // thread ids within this warp
    data_t [$clog2(THREADS_PER_WARP)-1:0] thread_ids;
    genvar t;
    generate
        for (t = 0; t < THREADS_PER_WARP; t++)
            assign thread_ids[t] = warp_id * THREADS_PER_WARP + t;
    endgenerate
    
    
    wire [31:0] DataR_W_mux1 = (DMemEN) ? lsu_out : alu_out;
    wire [31:0] DataR_W = (IsBR_J == 2) ? next_pc : DataR_W_mux1;
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            for (int t = 0; t < THREADS_PER_WARP; t++)
                for (int j = 0; j < REGS_PER_THREAD; j++) 
                    registers[t][j] <= 0; // init all with 0s
        end else if (warp_enable) begin
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                // update upon new warp activation, block/thread id could've updated
                registers[t][ZERO_REG] <= 0;
                registers[t][THREAD_ID_REG] <= thread_ids[t];
                registers[t][BLOCK_ID_REG] <= block_id;
                registers[t][BLOCK_SIZE_REG] <= block_size;
                
                // check execution mask and warp state
                if (thread_enable[t]) begin
                    if (warp_state == WARP_REQUEST) begin
                        // if fully scalar, don't need vec regs
                        if (Scalar != 1) begin 
                            rs1[t] <= registers[t][rs1_addr];  
                            rs2[t] <= registers[t][rs2_addr]; 
                        end
                    end else if (warp_state == WARP_UPDATE) begin
                        // no update if read-only regs or scalar/vec-to-scalar
                        if (LdReg && (rd_addr > 3) && (!Scalar)) begin 
                            registers[t][rd_addr] <= DataR_W;
                        end
                    end
                end
            end
        end
    end
        
endmodule
