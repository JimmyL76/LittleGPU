`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/20/2025 02:37:40 PM
// Design Name: 
// Module Name: scalar_regs
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

module scalar_regs #(
    parameter int SCALAR_REGS_PER_WARP
    )(
    input logic clk, reset, 
    input warp_state_t warp_state,
    input logic warp_enable,
    // note that thread_enable, which is [THREADS_PER_WARP-1:0], can only be as wide as
    // execution mask for conditionals, limited by width of a scalar register (data_t)
    output data_t execution_mask, 
    // data + control signals
    input logic [1:0] Scalar,
    input logic LdReg,
    input logic [1:0] IsBR_J,
    input logic DMemEN,
    // data/addr signals
    input logic [4:0] RS1Addr, RS2Addr, RDAddr,
    // output reg values, per thread
    output data_t rs1, rs2,
    // input load reg values, per thread
    input data_t alu_out, lsu_out, next_pc, v_to_s_value
    );
    
    // designated registers for indexing, i = block id * block size + thread id
    localparam int ZERO_REG = 0;
    localparam int EXEC_MASK_REG = 1;
    
    // each thread gets its own set of 32 registers (on top of potentially 32 threads per warp)
    data_t [SCALAR_REGS_PER_WARP-1:0] registers;
    
    assign execution_mask = registers[EXEC_MASK_REG];
    
    wire [31:0] DataR_W_mux1 = (DMemEN) ? lsu_out : alu_out;
    wire [31:0] DataR_W = (IsBR_J == 2) ? next_pc : DataR_W_mux1;
    
    data_t reg_load;
    assign reg_load = (IsBR_J == 2) ? next_pc : 
                        (DMemEN) ? lsu_out : 
                        (Scalar == 2) ? v_to_s_value : 
                        alu_out;
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            for (int r = 0; r < SCALAR_REGS_PER_WARP; r++)
                registers[r] <= 0; // init all with 0s
            registers[EXEC_MASK_REG] <= 1; // except execution mask which should be all 1s
        end else if (warp_enable) begin
            // check warp state
            if (warp_state == WARP_REQUEST) begin
                // if vec/vec-to-scalar, don't need scalar regs
                if (Scalar == 1) begin 
                    rs1 <= registers[RS1Addr];  
                    rs2 <= registers[RS2Addr]; 
                end
            end else if (warp_state == WARP_UPDATE) begin
                // no update if read-only regs or vec only
                if (LdReg && (RDAddr > 0) && Scalar) begin
                    registers[RDAddr] <= reg_load;
                end
            end 
        end
    end
        
endmodule
