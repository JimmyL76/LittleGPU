`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/19/2025 04:29:56 PM
// Design Name: 
// Module Name: decoder
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

module decoder(
    input logic clk, reset,
    input warp_state_t warp_state,
    input instr_t instr,
    // control signals
    output logic [1:0] Scalar,
    output logic LdReg,
    output logic [1:0] IsBR_J,
    output logic DMemEN,
    output logic [1:0] DataSize,
    output logic DMemR_W,
    output logic Usign,
    output logic RS1Mux,
    output logic [1:0] BR,
    output logic [3:0] ALUK,
    output logic RS2Mux,
    output logic Finish,
    // data/addr signals
    output logic [4:0] rs1_addr, rs2_addr, rd_addr, 
    output data_t IMM
    );
    // assume instr's that are only scalar are used correctly
    // each opcode even without bit 6 is still unique
    typedef enum logic [5:0] {
        R = 6'b110011,
        I_AR = 6'b010011,
        I_LD = 6'b000011,
        S = 6'b100011,
        B = 6'b100011,
        J_JAL = 6'b101111,
        I_JALR = 6'b100111,
        U_LUI = 6'b110111,
        U_AUIPC = 6'b010111,
        SX_S = 6'b111110,
        SX_I = 6'b111101
    } opcode_t;

    logic [4:0] rs1, rs2; assign rs1 = instr[19:15], rs2 = instr[24:20];
    logic [4:0] rd; assign rd = instr[11:7];
    opcode_t opcode; assign opcode = opcode_t'(instr[5:0]);
    logic [2:0] funct3; assign funct3 = instr[14:12];
    logic [6:0] funct7; assign funct7 = instr[31:25];
    
    // 0 is vector, 1 is scalar (use bit 6 of opcode), 2 is vector to scaler
    wire [1:0] next_Scalar = instr[6] ? 1 : 
                            ((opcode == SX_S) || (opcode == SX_I)) ? 2 : 
                            0;
    // ld a reg if not store or BR instr
    wire next_LdReg = (opcode != S) && (opcode != B); 
    // only for ld/st, use funct3, 0=word 1=half 2=byte    
    wire [1:0] next_DataSize = 
//                ((opcode != I_LD) && (opcode != S)) ? 2'bx :
                ((funct3 == 1) || (funct3 == 5)) ? 1 : // halfword
                (funct3 == 2) ? 0 : // word
                2; // byte
    wire next_DMemR_W = (opcode == S); // only 1 (write) if store
    wire next_RS1Mux = (opcode == B) || (opcode == J_JAL)
                || (opcode == U_AUIPC); // 1 if using PC in ALU
    // 0 = no BR nor J, 1 = BR, 2 = J
    wire [1:0] next_IsBR_J = (opcode == B) ? 1 :
                    ((opcode == J_JAL) || (opcode == I_JALR)) ? 2 :
                    0;
    // 0 ==, 1 !=, 2 <, 3 >=
    wire [1:0] next_BR = (funct3 == 0) ? 0 :
                (funct3 == 1) ? 1 :
                ((funct3 == 4) || (funct3 == 6)) ? 2 :
                3;
    // 0 JAL, 1 JALR //    wire Jump = (opcode == I_JALR);
    // BR is don't care if IsBR_J is 0, Jump matters but will always be 0 if is BR;
    wire next_DMemEN = (opcode == S) || (opcode == I_LD);
        
    // 0 add, 1 sub, 2 xor, 3 or, 4 and, 5 lshf R, 6 rshf R, 7 rshf R arith
    // 8 SLT (and U), 9 LUI, 10 AUIPC
    // U-type done with ImmLogic (lshf_12, add + lshf_12) 
    logic [3:0] next_ALUK;
    always_comb begin
        next_ALUK = 0; // default value
        if((opcode == R) || (opcode == I_AR)) begin
            case(funct3)
                0: if((opcode == R) && (funct7 == 7'h20)) next_ALUK = 1; // else=default
                1: next_ALUK = 5; // lshf
                2, 3: next_ALUK = 8; // SLT
                4: next_ALUK = 2; // xor
                5: begin // imm[5:11] is also funct7
                    if(funct7 == 7'h20) next_ALUK = 7;     
                    else next_ALUK = 6;    
                end
                6: next_ALUK = 3;
                7: next_ALUK = 4;    
                default: next_ALUK = 0;           
            endcase
        // for all other instr, using only add except lui (even AUIPC only adds)
        end else if(opcode == U_LUI) next_ALUK = 9;
    end
    
    wire next_RS2Mux = !(opcode == R); // all other instr use imm (1)
    wire next_Usign = ((opcode == R) || (opcode == I_AR)) ? (funct3 == 3) : // arith
            (opcode == I_LD) ? ((funct3 == 4) || (funct3 == 5)) : // ld's
            ((funct3 == 6) || (funct3 == 7)); // BR
            
    // 0 I-type, 1 S-type, 2 B-type, 3 U-type, 4 J-type
    wire [2:0] ImmLogic = ((opcode == I_AR) || (opcode == I_LD) || (opcode == I_JALR)) ? 0 :
                    (opcode == S) ? 1 :
                    (opcode == B) ? 2 :
                    ((opcode == U_LUI) || (opcode == U_AUIPC)) ? 3 :
                    4;
    // ImmLogic doesn't matter if opcode type is R
    // if instr is all 0s, treat as HALT
    wire next_Finish = !instr;
   
    // Imm Logic block
    logic [31:0] next_IMM;
    always_comb begin
        case (ImmLogic)
            0: next_IMM = {{21{instr[31]}}, instr[30:25],
                instr[24:20]};
            1: next_IMM = {{21{instr[31]}}, instr[30:25],
                instr[11:8], instr[7]};
            2: next_IMM = {{20{instr[31]}}, instr[7],
                instr[30:25], instr[11:8], 1'b0};
            3: next_IMM = {instr[31:12], 12'b0};
            4: next_IMM = {{12{instr[31]}}, instr[19:12],
                instr[20], instr[30:21], 1'b0};
            default: next_IMM = 32'bx; // def case, don't care
        endcase
    end   
    
    always_ff @(posedge clk) begin
    // values are constantly being updated, no need for reset
    // but save power if not in WARP_DECODE state
        if (warp_state == WARP_DECODE) begin
            Scalar <= next_Scalar;
            LdReg <= next_LdReg;
            IsBR_J <= next_IsBR_J;
            DMemEN <= next_DMemEN;
            DataSize <= next_DataSize;
            DMemR_W <= next_DMemR_W;
            Usign <= next_Usign;
            RS1Mux <= next_RS1Mux;
            BR <= next_BR;
            ALUK <= next_ALUK;
            RS2Mux <= next_RS2Mux;
            Finish <= next_Finish;
            
            IMM <= next_IMM;
            rs1_addr <= rs1;
            rs2_addr <= rs2;
            rd_addr <= rd;
        end
    end
    
endmodule
