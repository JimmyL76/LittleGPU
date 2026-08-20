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
    parameter int DATA_WIDTH          = 32;
    parameter int INSTR_WIDTH         = 32;
    parameter int DATA_MEM_ADDR_WIDTH = 32;
    parameter int INSTR_MEM_ADDR_WIDTH = 32;

    typedef logic [DATA_WIDTH-1:0] data_t;
    typedef logic [INSTR_WIDTH-1:0] instr_t;
    typedef logic [DATA_MEM_ADDR_WIDTH-1:0] data_mem_addr_t;
    typedef logic [INSTR_MEM_ADDR_WIDTH-1:0] instr_mem_addr_t;
    
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
        WARP_EXECUTE,
        WARP_MEMORY,
        WARP_WRITEBACK,
        WARP_DONE
    } warp_state_t;
    
    // lsu state enum
    typedef enum logic [1:0] {
        LSU_IDLE,
        LSU_REQUESTING,
        LSU_DONE
    } lsu_state_t;
    
    // fetch state enum
    typedef enum logic [0:0] {
        FETCHER_IDLE,
        FETCHER_FETCHING
    } fetcher_state_t;

    // stall reason for parked warp
    // reserved encodings left unused for future divergence and barrier waits
    typedef enum logic [2:0] {
        STALL_NONE      = 3'd0,  // warp is ready or actively progressing
        STALL_WAIT_MEM  = 3'd1,  // parked awaiting tagged memory response
        STALL_WAIT_EXEC = 3'd2,  // parked awaiting execute resource
        STALL_RSVD_3    = 3'd3,  // reserved encoding for future reconverge wait
        STALL_RSVD_4    = 3'd4   // reserved encoding for future barrier wait
    } stall_reason_t;

    // latency-hiding resource parameters
    // all values are assumed to be at minimum >= 2 and stated inline at declaration
    parameter int SCOREBOARD_DEPTH = 2;        // concurrent outstanding warp memory ops default 2
    parameter int MSHR_COUNT       = 2;        // bounded mshr pool size default 2
    parameter int COAL_OUTSTANDING = 2;        // concurrent outstanding line requests default 2
    parameter int RESP_BUF_DEPTH   = 2;        // per-user response buffer depth default 2

    // core-internal max concurrent outstanding requests bounds unique tag space
    parameter int MAX_OUTSTANDING_PER_CORE = SCOREBOARD_DEPTH;  // core-internal max concurrent outstanding default 2
    // request tag width is clog2 of max outstanding giving 1 bit at default depth 2
    parameter int REQ_TAG_WIDTH = $clog2(MAX_OUTSTANDING_PER_CORE);

    // function for making display statements easier to read
    `ifndef SYNTHESIS
    function automatic string decode_instr(instr_t instr);
        logic [6:0] opcode = instr[6:0];
        logic [4:0] rd = instr[11:7];
        logic [2:0] funct3 = instr[14:12];
        logic [4:0] rs1 = instr[19:15];
        logic [4:0] rs2 = instr[24:20];
        logic [6:0] funct7 = instr[31:25];
        
        if (instr == 32'h00000000) return "HALT";
        if (instr == 32'h00000013) return "NOP";
        
        case (opcode)
            7'h33: begin // R-type Vector
                case (funct3)
                    3'b000: if (funct7 == 0) return $sformatf("ADD_V x%0d, x%0d, x%0d", rd, rs1, rs2); else return $sformatf("SUB_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b001: return $sformatf("SLL_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b010: return $sformatf("SLT_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b011: return $sformatf("SLTU_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b100: return $sformatf("XOR_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b101: if (funct7 == 0) return $sformatf("SRL_V x%0d, x%0d, x%0d", rd, rs1, rs2); else return $sformatf("SRA_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b110: return $sformatf("OR_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b111: return $sformatf("AND_V x%0d, x%0d, x%0d", rd, rs1, rs2);
                endcase
            end
            7'h73: begin // R-type Scalar
                case (funct3)
                    3'b000: if (funct7 == 0) return $sformatf("ADD_S x%0d, x%0d, x%0d", rd, rs1, rs2); else return $sformatf("SUB_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b001: return $sformatf("SLL_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b010: return $sformatf("SLT_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b011: return $sformatf("SLTU_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b100: return $sformatf("XOR_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b101: if (funct7 == 0) return $sformatf("SRL_S x%0d, x%0d, x%0d", rd, rs1, rs2); else return $sformatf("SRA_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b110: return $sformatf("OR_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                    3'b111: return $sformatf("AND_S x%0d, x%0d, x%0d", rd, rs1, rs2);
                endcase
            end
            7'h13: begin // I-type Vector
                case (funct3)
                    3'b000: return $sformatf("ADDI_V x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b010: return $sformatf("SLTI_V x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b011: return $sformatf("SLTIU_V x%0d, x%0d, %0d", rd, rs1, instr[31:20]);
                    3'b100: return $sformatf("XORI_V x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b110: return $sformatf("ORI_V x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b111: return $sformatf("ANDI_V x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b001: return $sformatf("SLLI_V x%0d, x%0d, %0d", rd, rs1, rs2);
                    3'b101: if (funct7 == 0) return $sformatf("SRLI_V x%0d, x%0d, %0d", rd, rs1, rs2); else return $sformatf("SRAI_V x%0d, x%0d, %0d", rd, rs1, rs2);
                endcase
            end
            7'h53: begin // I-type Scalar
                case (funct3)
                    3'b000: return $sformatf("ADDI_S x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b010: return $sformatf("SLTI_S x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b011: return $sformatf("SLTIU_S x%0d, x%0d, %0d", rd, rs1, instr[31:20]);
                    3'b100: return $sformatf("XORI_S x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b110: return $sformatf("ORI_S x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b111: return $sformatf("ANDI_S x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
                    3'b001: return $sformatf("SLLI_S x%0d, x%0d, %0d", rd, rs1, rs2);
                    3'b101: if (funct7 == 0) return $sformatf("SRLI_S x%0d, x%0d, %0d", rd, rs1, rs2); else return $sformatf("SRAI_S x%0d, x%0d, %0d", rd, rs1, rs2);
                endcase
            end
            7'h03: begin // Load Vector
                case (funct3)
                    3'b000: return $sformatf("LB_V x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b001: return $sformatf("LH_V x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b010: return $sformatf("LW_V x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b100: return $sformatf("LBU_V x%0d, %0d(x%0d)", rd, instr[31:20], rs1);
                    3'b101: return $sformatf("LHU_V x%0d, %0d(x%0d)", rd, instr[31:20], rs1);
                endcase
            end
            7'h43: begin // Load Scalar
                case (funct3)
                    3'b000: return $sformatf("LB_S x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b001: return $sformatf("LH_S x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b010: return $sformatf("LW_S x%0d, %0d(x%0d)", rd, $signed(instr[31:20]), rs1);
                    3'b100: return $sformatf("LBU_S x%0d, %0d(x%0d)", rd, instr[31:20], rs1);
                    3'b101: return $sformatf("LHU_S x%0d, %0d(x%0d)", rd, instr[31:20], rs1);
                endcase
            end
            7'h23: begin // Store Vector
                case (funct3)
                    3'b000: return $sformatf("SB_V x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                    3'b001: return $sformatf("SH_V x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                    3'b010: return $sformatf("SW_V x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                endcase
            end
            7'h7B: begin // Store Scalar
                case (funct3)
                    3'b000: return $sformatf("SB_S x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                    3'b001: return $sformatf("SH_S x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                    3'b010: return $sformatf("SW_S x%0d, %0d(x%0d)", rs2, $signed({funct7, rd}), rs1);
                endcase
            end
            7'h63: begin // Branch
                case (funct3)
                    3'b000: return $sformatf("BEQ x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                    3'b001: return $sformatf("BNE x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                    3'b100: return $sformatf("BLT x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                    3'b101: return $sformatf("BGE x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                    3'b110: return $sformatf("BLTU x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                    3'b111: return $sformatf("BGEU x%0d, x%0d, %0d", rs1, rs2, $signed({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}));
                endcase
            end
            7'h6F: return $sformatf("JAL x%0d, %0d", rd, $signed({instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}));
            7'h67: return $sformatf("JALR x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
            7'h37: return $sformatf("LUI_V x%0d, 0x%0x", rd, {instr[31:12], 12'b0});
            7'h77: return $sformatf("LUI_S x%0d, 0x%0x", rd, {instr[31:12], 12'b0});
            7'h17: return $sformatf("AUIPC_V x%0d, 0x%0x", rd, {instr[31:12], 12'b0});
            7'h57: return $sformatf("AUIPC_S x%0d, 0x%0x", rd, {instr[31:12], 12'b0});
            7'h7E: return $sformatf("SX_S x%0d, x%0d, x%0d", rd, rs1, rs2);
            7'h7D: return $sformatf("SX_I x%0d, x%0d, %0d", rd, rs1, $signed(instr[31:20]));
        endcase
        return $sformatf("UNKNOWN_INSTR (0x%0x)", instr);
    endfunction
    `endif

 endpackage
 
 // module since functions can't take parameters
module utility #(
    parameter int NUM_CORES = 32
    )(
    input logic [NUM_CORES-1:0] nth_free_core,
    output logic [$clog2(NUM_CORES)-1:0] onehot_to_binary 
    );
    always_comb begin
        onehot_to_binary = -1; // default all 1s, although should never use output if none are true
        for (int i = 0; i < NUM_CORES; i++) 
            if (nth_free_core[i]) onehot_to_binary = i; // this will only be true once
    end
endmodule
    
`endif
