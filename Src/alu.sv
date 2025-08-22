`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/19/2025 10:37:56 PM
// Design Name: 
// Module Name: alu
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

module alu(
    input logic clk, reset,
    input warp_state_t warp_state,
    input instr_mem_addr_t pc, // pc is always instr not data_mem_addr_t
    // data + control signals
    input data_t rs1, rs2, imm,
    input logic [1:0] IsBR_J,
    input logic Usign,
    input logic RS1Mux,
    input logic [1:0] BR,
    input logic [3:0] ALUK,
    input logic RS2Mux,
    
    output data_t alu_out,
    output pc_jump
    );
    
    wire [31:0] alu_rs1 = (RS1Mux) ? pc : rs1;
    wire [31:0] alu_rs2 = (RS2Mux) ? imm : rs2; 
    logic [31:0] alu_result;
    // 0 add, 1 sub, 2 xor, 3 or, 4 and, 5 lshf R, 6 rshf R, 7 rshf R arith
    // 8 SLT (and U), 9 LUI, 10 AUIPC
    // U-type done with ImmLogic (lshf_12, add + lshf_12) 
    always_comb begin
        case(ALUK)
            0: alu_result = alu_rs1 + alu_rs2;
            1: alu_result = alu_rs1 - alu_rs2;
            2: alu_result = alu_rs1 ^ alu_rs2;
            3: alu_result = alu_rs1 | alu_rs2;
            4: alu_result = alu_rs1 & alu_rs2;
            5: alu_result = alu_rs1 << alu_rs2[4:0];
            6: alu_result = alu_rs1 >> alu_rs2[4:0];
            7: alu_result = $signed(alu_rs1) >>> alu_rs2[4:0];
            8: begin
                if(Usign) alu_result = (alu_rs1 < alu_rs2) ? 1 : 0;
                else alu_result = ($signed(alu_rs1) < $signed(alu_rs2)) ? 1 : 0;
            end
            9: alu_result = alu_rs2;
            default: alu_result = 32'bx;
        endcase
    end    
    
    // br logic
    logic next_pc_jump;
    always_comb begin
        if (IsBR_J == 0) next_pc_jump = 0;
        else if(IsBR_J == 2) next_pc_jump = 1;
        else begin
            case(BR) 
                0: next_pc_jump = ($signed(rs1) == $signed(rs2));
                1: next_pc_jump = ($signed(rs1) != $signed(rs2));
                2: begin
                    if(Usign) next_pc_jump = ((rs1) < (rs2));
                    else next_pc_jump = ($signed(rs1) < $signed(rs2));
                end
                3: begin
                    if(Usign) next_pc_jump = ((rs1) >= (rs2));
                    else next_pc_jump = ($signed(rs1) >= $signed(rs2));
                end
            endcase
        end
    end 
    
    always_ff @(posedge clk) begin
        if (warp_state == WARP_EXECUTE) begin
            alu_out <= alu_result;
            pc_jump <= next_pc_jump;
        end
    end
    
endmodule
