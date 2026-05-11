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
    output logic [4:0] RS1Addr, RS2Addr, RDAddr,
    output data_t IMM
    );
    // assume instr's that are only scalar are used correctly
    typedef enum logic [6:0] {
        // vector instructions (bit 6 = 0)
        R_V = 7'b0110011,      // 0x33 - vector R-type
        I_AR_V = 7'b0010011,   // 0x13 - vector I-type arithmetic
        I_LD = 7'b0000011,     // 0x03 - vector load
        S_V = 7'b0100011,      // 0x23 - vector store
        U_LUI_V = 7'b0110111,  // 0x37 - vector LUI
        U_AUIPC_V = 7'b0010111, // 0x17 - vector AUIPC
        // scalar instructions (bit 6 = 1)
        R_S = 7'b1110011,      // 0x73 - scalar R-type
        I_AR_S = 7'b1010011,   // 0x53 - scalar I-type arithmetic
        I_LD_S = 7'b1000011,   // 0x43 - scalar load
        B = 7'b1100011,        // 0x63 - branch (scalar control flow)
        J_JAL = 7'b1101111,    // 0x6F - jump (scalar control flow)
        I_JALR = 7'b1100111,   // 0x67 - jump register (scalar control flow)
        U_LUI_S = 7'b1110111,  // 0x77 - scalar LUI
        U_AUIPC_S = 7'b1010111, // 0x57 - scalar AUIPC
        // custom opcodes for special operations
        SX_S = 7'b1111110,     // 0x7E - vector-to-scalar set less than
        SX_I = 7'b1111101,     // 0x7D - vector-to-scalar set less than imm
        S_S = 7'b1111011       // 0x7B - scalar store (avoids 0x63 conflict)
    } opcode_t;

    opcode_t opcode; assign opcode = opcode_t'(instr[6:0]);
    logic [2:0] funct3; assign funct3 = instr[14:12];
    logic [6:0] funct7; assign funct7 = instr[31:25];
    
    // register addresses directly from instruction
    assign RS1Addr = instr[19:15];
    assign RS2Addr = instr[24:20];
    assign RDAddr = instr[11:7];
    
    // all outputs are combinational
    // 0 is vector, 1 is scalar (use bit 6 of opcode), 2 is vector to scalar
    assign Scalar = ((opcode == SX_S) || (opcode == SX_I)) ? 2 :
                            instr[6] ? 1 : 
                            0;
    // ld a reg if not store or BR instr
    assign LdReg = (opcode != S_V) && (opcode != S_S) && (opcode != B); 
    // only for ld/st, use funct3, 0=word 1=half 2=byte    
    assign DataSize = 
//                ((opcode != I_LD) && (opcode != S)) ? 2'bx :
                ((funct3 == 1) || (funct3 == 5)) ? 1 : // halfword
                (funct3 == 2) ? 0 : // word
                2; // byte
    assign DMemR_W = (opcode == S_V) || (opcode == S_S); // 1 (write) if store
    assign RS1Mux = (opcode == B) || (opcode == J_JAL)
                || (opcode == U_AUIPC_V) || (opcode == U_AUIPC_S); // 1 if using PC in ALU
    // 0 = no BR nor J, 1 = BR, 2 = J
    assign IsBR_J = (opcode == B) ? 1 :
                    ((opcode == J_JAL) || (opcode == I_JALR)) ? 2 :
                    0;
    // 0 ==, 1 !=, 2 <, 3 >=
    assign BR = (funct3 == 0) ? 0 :
                (funct3 == 1) ? 1 :
                ((funct3 == 4) || (funct3 == 6)) ? 2 :
                3;
    // 0 JAL, 1 JALR //    wire Jump = (opcode == I_JALR);
    // BR is don't care if IsBR_J is 0, Jump matters but will always be 0 if is BR;
    assign DMemEN = (opcode == S_V) || (opcode == S_S) || (opcode == I_LD) || (opcode == I_LD_S);
        
    // 0 add, 1 sub, 2 xor, 3 or, 4 and, 5 lshf R, 6 rshf R, 7 rshf R arith
    // 8 SLT (and U), 9 LUI, 10 AUIPC
    // U-type done with ImmLogic (lshf_12, add + lshf_12) 
    always_comb begin
        ALUK = 0; // default value
        // covers both vector and scalar variants
        if((opcode == R_V) || (opcode == R_S) || (opcode == I_AR_V) || (opcode == I_AR_S)) begin
            case(funct3)
                0: if(((opcode == R_V) || (opcode == R_S)) && (funct7 == 7'h20)) ALUK = 1; // SUB, else ADD
                1: ALUK = 5; // SLL
                2, 3: ALUK = 8; // SLT, SLTU
                4: ALUK = 2; // XOR
                5: begin // imm[5:11] is also funct7
                    if(funct7 == 7'h20) ALUK = 7; // SRA      
                    else ALUK = 6; // SRL    
                end
                6: ALUK = 3; // OR
                7: ALUK = 4; // AND    
                default: ALUK = 0;           
            endcase
        // vector-to-scalar comparisons
        end else if((opcode == SX_S) || (opcode == SX_I)) begin
            ALUK = 8; // always SLT for SX instrs
        // for all other instr, using only add except lui (even AUIPC only adds)
        end else if((opcode == U_LUI_V) || (opcode == U_LUI_S)) begin
            ALUK = 9;
        end
    end
    
    assign RS2Mux = (opcode != R_V) && (opcode != R_S) && (opcode != SX_S); // R-type and SX_S use RS2 reg
    assign Usign = ((opcode == R_V) || (opcode == R_S) || (opcode == I_AR_V) || (opcode == I_AR_S)) ? (funct3 == 3) : // arith
            ((opcode == I_LD) || (opcode == I_LD_S)) ? ((funct3 == 4) || (funct3 == 5)) : // ld's
            ((funct3 == 6) || (funct3 == 7)); // BR
            
    // 0 I-type, 1 S-type, 2 B-type, 3 U-type, 4 J-type
    wire [2:0] ImmLogic = ((opcode == I_AR_V) || (opcode == I_AR_S) || (opcode == I_LD) || (opcode == I_LD_S) || (opcode == I_JALR) || (opcode == SX_I)) ? 0 :
                    ((opcode == S_V) || (opcode == S_S)) ? 1 :
                    (opcode == B) ? 2 :
                    ((opcode == U_LUI_V) || (opcode == U_LUI_S) || (opcode == U_AUIPC_V) || (opcode == U_AUIPC_S)) ? 3 :
                    4;
    // ImmLogic doesn't matter if opcode type is R
    // if instr is all 0s, treat as HALT
    assign Finish = !instr;
   
    // Imm Logic block
    always_comb begin
        case (ImmLogic)
            0: IMM = {{21{instr[31]}}, instr[30:25],
                instr[24:20]};
            1: IMM = {{21{instr[31]}}, instr[30:25],
                instr[11:8], instr[7]};
            2: IMM = {{20{instr[31]}}, instr[7],
                instr[30:25], instr[11:8], 1'b0};
            3: IMM = {instr[31:12], 12'b0};
            4: IMM = {{12{instr[31]}}, instr[19:12],
                instr[20], instr[30:21], 1'b0};
            default: IMM = 32'bx; // def case, don't care
        endcase
    end   
    
endmodule
