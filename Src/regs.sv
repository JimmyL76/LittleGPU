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
    input logic [THREADS_PER_WARP-1:0] execution_mask, // execution mask for conditionals
    // warp/block identifiers
    input data_t warp_id, block_id, block_size,
    // data + control signals
    input logic [1:0] Scalar,
    input logic LdReg,
    input logic [1:0] IsBR_J,
    input logic DMemEN,
    // data/addr signals
    input logic [4:0] RS1Addr, RS2Addr, RDAddr,
    // output reg values, per thread
    output data_t rs1 [THREADS_PER_WARP], rs2 [THREADS_PER_WARP],
    // input load reg values, per thread
    input data_t alu_out [THREADS_PER_WARP], lsu_out [THREADS_PER_WARP], next_pc [THREADS_PER_WARP]
    );
    
    // designated registers for indexing, global id = block id * block size + thread id
    // software programmer calculates this, so thread id is local not global by itself 
    // (alt ex: thread id = global id = block id * block size + warp_id * THREADS_PER_WARP + t)
    localparam int ZERO_REG = 0;
    localparam int THREAD_ID_REG = 1;
    localparam int BLOCK_ID_REG = 2;
    localparam int BLOCK_SIZE_REG = 3;
    
    // each thread gets its own set of 32 registers (ex: 32 threads per warp = 32*32 per warp)
    data_t registers [THREADS_PER_WARP][REGS_PER_THREAD];
    
    // thread ids within this warp
    data_t thread_ids [THREADS_PER_WARP];
    genvar t;
    generate
        for (t = 0; t < THREADS_PER_WARP; t++)
            assign thread_ids[t] = warp_id * THREADS_PER_WARP + t;
    endgenerate
    
    data_t reg_load [THREADS_PER_WARP];
    generate
        for (t = 0; t < THREADS_PER_WARP; t++)
            assign reg_load[t] = (IsBR_J == 2) ? next_pc[t] : 
                                (DMemEN) ? lsu_out[t] : 
                                alu_out[t];
    endgenerate
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            for (int t = 0; t < THREADS_PER_WARP; t++)
                for (int j = 0; j < REGS_PER_THREAD; j++) 
                    registers[t][j] <= 0; // init all with 0s
        end else if (warp_enable) begin
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                // always keep special registers updated (they're read-only from software perspective)
                registers[t][ZERO_REG] <= 0;
                registers[t][THREAD_ID_REG] <= thread_ids[t];
                registers[t][BLOCK_ID_REG] <= block_id;
                registers[t][BLOCK_SIZE_REG] <= block_size;
                
                if (warp_state == WARP_DECODE) begin
                    // register read stage - if fully scalar, don't need vec regs
                    if (Scalar != 1) begin 
                        rs1[t] <= (RS1Addr == ZERO_REG) ? 32'd0 :
                                  (RS1Addr == THREAD_ID_REG) ? thread_ids[t] :
                                  (RS1Addr == BLOCK_ID_REG) ? block_id :
                                  (RS1Addr == BLOCK_SIZE_REG) ? block_size :
                                  registers[t][RS1Addr];  
                        rs2[t] <= (RS2Addr == ZERO_REG) ? 32'd0 :
                                  (RS2Addr == THREAD_ID_REG) ? thread_ids[t] :
                                  (RS2Addr == BLOCK_ID_REG) ? block_id :
                                  (RS2Addr == BLOCK_SIZE_REG) ? block_size :
                                  registers[t][RS2Addr]; 
                    end
                end else if (warp_state == WARP_WRITEBACK) begin
                    if (execution_mask[t]) begin
                        // no update if read-only regs or scalar/vec-to-scalar
                        if (LdReg && (RDAddr > 3) && (!Scalar)) begin 
                            registers[t][RDAddr] <= reg_load[t];
                        end
                    end
                end
            end
        end
    end
        
endmodule
