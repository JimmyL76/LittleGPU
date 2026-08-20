`timescale 1ns / 1ps

import common_pkg::*;
import tb_common_pkg::*;

module tb_decoder;

    // Clock and reset
    logic clk;
    logic reset;
    
    // Inputs
    instr_t instr;
    
    // Outputs
    logic [1:0] Scalar;
    logic LdReg;
    logic [1:0] IsBR_J;
    logic DMemEN;
    logic [1:0] DataSize;
    logic DMemR_W;
    logic Usign;
    logic RS1Mux;
    logic [1:0] BR;
    logic [3:0] ALUK;
    logic RS2Mux;
    logic Finish;
    logic [4:0] RS1Addr, RS2Addr, RDAddr;
    data_t IMM;
    
    // Instantiate DUT
    decoder dut (
        .instr(instr),
        .Scalar(Scalar),
        .LdReg(LdReg),
        .IsBR_J(IsBR_J),
        .DMemEN(DMemEN),
        .DataSize(DataSize),
        .DMemR_W(DMemR_W),
        .Usign(Usign),
        .RS1Mux(RS1Mux),
        .BR(BR),
        .ALUK(ALUK),
        .RS2Mux(RS2Mux),
        .Finish(Finish),
        .RS1Addr(RS1Addr),
        .RS2Addr(RS2Addr),
        .RDAddr(RDAddr),
        .IMM(IMM)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Test stimulus
    initial begin
        $display("========================================");
        $display("Decoder Testbench Starting");
        $display("========================================");
        
        // Initialize
        reset = 1;
        instr = encode_instr(.instr_type("HALT"));
        
        // Apply reset
        repeat(2) @(posedge clk);
        reset = 0;
        
        //===========================================
        // R-TYPE INSTRUCTIONS
        //===========================================
        $display("\n--- Testing R-Type Instructions ---");
        
        // ADD x1, x2, x3 (0x003100B3)
        instr = encode_instr(.instr_type("ADD_V"), .rd(1), .rs1(2), .rs2(3));
        @(posedge clk); 
        compare_bit("R-ADD Scalar", Scalar, 2'b00, "vector");
        compare_bit("R-ADD LdReg", LdReg, 1'b1, "load reg");
        compare_bit("R-ADD IsBR_J", IsBR_J, 2'b00, "no branch/jump");
        compare_bit("R-ADD DMemEN", DMemEN, 1'b0, "no mem access");
        compare_bit("R-ADD RS1Mux", RS1Mux, 1'b0, "use RS1");
        compare_bit("R-ADD ALUK", ALUK, 4'h0, "ADD");
        compare_bit("R-ADD RS2Mux", RS2Mux, 1'b0, "use RS2");
        compare_data("R-ADD RS1Addr", RS1Addr, 5'd2);
        compare_data("R-ADD RS2Addr", RS2Addr, 5'd3);
        compare_data("R-ADD RDAddr", RDAddr, 5'd1);
        
        // SUB x4, x5, x6 (0x40628233)
        instr = encode_instr(.instr_type("SUB_V"), .rd(4), .rs1(5), .rs2(6));
        @(posedge clk); 
        compare_bit("R-SUB ALUK", ALUK, 4'h1, "SUB");
        compare_data("R-SUB RS1Addr", RS1Addr, 5'd5);
        compare_data("R-SUB RS2Addr", RS2Addr, 5'd6);
        compare_data("R-SUB RDAddr", RDAddr, 5'd4);
        
        // XOR x7, x8, x9 (0x009443B3)
        instr = encode_instr(.instr_type("XOR_V"), .rd(7), .rs1(8), .rs2(9));
        @(posedge clk); 
        compare_bit("R-XOR ALUK", ALUK, 4'h2, "XOR");
        
        // OR x10, x11, x12 (0x00C5E533)
        instr = encode_instr(.instr_type("OR_V"), .rd(10), .rs1(11), .rs2(12));
        @(posedge clk); 
        compare_bit("R-OR ALUK", ALUK, 4'h3, "OR");
        
        // AND x13, x14, x15 (0x00F776B3)
        instr = encode_instr(.instr_type("AND_V"), .rd(13), .rs1(14), .rs2(15));
        @(posedge clk); 
        compare_bit("R-AND ALUK", ALUK, 4'h4, "AND");
        
        // SLL x16, x17, x18 (0x01289833)
        instr = encode_instr(.instr_type("SLL_V"), .rd(16), .rs1(17), .rs2(18));
        @(posedge clk); 
        compare_bit("R-SLL ALUK", ALUK, 4'h5, "SLL");
        
        // SRL x19, x20, x21 (0x015A59B3)
        instr = encode_instr(.instr_type("SRL_V"), .rd(19), .rs1(20), .rs2(21));
        @(posedge clk); 
        compare_bit("R-SRL ALUK", ALUK, 4'h6, "SRL");
        
        // SRA x22, x23, x24 (0x418BDB33)
        instr = encode_instr(.instr_type("SRA_V"), .rd(22), .rs1(23), .rs2(24));
        @(posedge clk); 
        compare_bit("R-SRA ALUK", ALUK, 4'h7, "SRA");
        
        // SLT x25, x26, x27 (0x01BD2CB3)
        instr = encode_instr(.instr_type("SLT_V"), .rd(25), .rs1(26), .rs2(27));
        @(posedge clk); 
        compare_bit("R-SLT ALUK", ALUK, 4'h8, "SLT");
        compare_bit("R-SLT Usign", Usign, 1'b0, "signed");
        
        // SLTU x28, x29, x30 (0x01EEB E33)
        instr = encode_instr(.instr_type("SLTU_V"), .rd(28), .rs1(29), .rs2(30));
        @(posedge clk); 
        compare_bit("R-SLTU ALUK", ALUK, 4'h8, "SLT");
        compare_bit("R-SLTU Usign", Usign, 1'b1, "unsigned");
        
        //===========================================
        // I-TYPE ARITHMETIC INSTRUCTIONS
        //===========================================
        $display("\n--- Testing I-Type Arithmetic Instructions ---");
        
        // ADDI x1, x2, 100 (0x06410093)
        instr = encode_instr(.instr_type("ADDI_V"), .rd(1), .rs1(2), .imm(100));
        @(posedge clk); 
        compare_bit("I-ADDI Scalar", Scalar, 2'b00, "vector");
        compare_bit("I-ADDI LdReg", LdReg, 1'b1, "load reg");
        compare_bit("I-ADDI RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_bit("I-ADDI ALUK", ALUK, 4'h0, "ADD");
        compare_data("I-ADDI IMM", IMM, 32'd100);
        compare_data("I-ADDI RS1Addr", RS1Addr, 5'd2);
        compare_data("I-ADDI RDAddr", RDAddr, 5'd1);
        
        // XORI x3, x4, -1 (0xFFF24193)
        instr = encode_instr(.instr_type("XORI_V"), .rd(3), .rs1(4), .imm(32'hFFFFFFFF));
        @(posedge clk); 
        compare_bit("I-XORI ALUK", ALUK, 4'h2, "XOR");
        compare_data("I-XORI IMM", IMM, 32'hFFFFFFFF);
        
        // ORI x5, x6, 0x7FF (0x7FF36293)
        instr = encode_instr(.instr_type("ORI_V"), .rd(5), .rs1(6), .imm(32'h7FF));
        @(posedge clk); 
        compare_bit("I-ORI ALUK", ALUK, 4'h3, "OR");
        compare_data("I-ORI IMM", IMM, 32'h7FF);
        
        // ANDI x7, x8, 0xFF (0x0FF47393)
        instr = encode_instr(.instr_type("ANDI_V"), .rd(7), .rs1(8), .imm(255));
        @(posedge clk); 
        compare_bit("I-ANDI ALUK", ALUK, 4'h4, "AND");
        compare_data("I-ANDI IMM", IMM, 32'hFF);
        
        // SLLI x9, x10, 5 (0x00551493)
        instr = encode_instr(.instr_type("SLLI_V"), .rd(9), .rs1(10), .imm(5));
        @(posedge clk); 
        compare_bit("I-SLLI ALUK", ALUK, 4'h5, "SLL");
        compare_data("I-SLLI IMM", IMM, 32'd5);
        
        // SRLI x11, x12, 3 (0x00365593)
        instr = encode_instr(.instr_type("SRLI_V"), .rd(11), .rs1(12), .imm(3));
        @(posedge clk); 
        compare_bit("I-SRLI ALUK", ALUK, 4'h6, "SRL");
        compare_data("I-SRLI IMM", IMM, 32'd3);
        
        // SRAI x13, x14, 7 (0x40775693)
        instr = encode_instr(.instr_type("SRAI_V"), .rd(13), .rs1(14), .imm(7));
        @(posedge clk); 
        compare_bit("I-SRAI ALUK", ALUK, 4'h7, "SRA");
        compare_data("I-SRAI IMM", IMM, 32'h407); // Full I-type imm includes funct7
        
        // SLTI x15, x16, -10 (0xFF682793)
        instr = encode_instr(.instr_type("SLTI_V"), .rd(15), .rs1(16), .imm(32'hFFFFFFF6));
        @(posedge clk); 
        compare_bit("I-SLTI ALUK", ALUK, 4'h8, "SLT");
        compare_bit("I-SLTI Usign", Usign, 1'b0, "signed");
        compare_data("I-SLTI IMM", IMM, 32'hFFFFFFF6); // -10 sign-extended
        
        // SLTIU x17, x18, 20 (0x01493893)
        instr = encode_instr(.instr_type("SLTIU_V"), .rd(17), .rs1(18), .imm(20));
        @(posedge clk); 
        compare_bit("I-SLTIU ALUK", ALUK, 4'h8, "SLT");
        compare_bit("I-SLTIU Usign", Usign, 1'b1, "unsigned");
        compare_data("I-SLTIU IMM", IMM, 32'd20);
        
        //===========================================
        // I-TYPE LOAD INSTRUCTIONS
        //===========================================
        $display("\n--- Testing I-Type Load Instructions ---");
        
        // LW x1, 0(x2) (0x00012083)
        instr = encode_instr(.instr_type("LW_V"), .rd(1), .rs1(2), .imm(0));
        @(posedge clk); 
        compare_bit("I-LW Scalar", Scalar, 2'b00, "vector");
        compare_bit("I-LW LdReg", LdReg, 1'b1, "load reg");
        compare_bit("I-LW DMemEN", DMemEN, 1'b1, "mem enabled");
        compare_bit("I-LW DMemR_W", DMemR_W, 1'b0, "read");
        compare_bit("I-LW DataSize", DataSize, 2'b00, "word");
        compare_bit("I-LW RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("I-LW IMM", IMM, 32'd0);
        
        // LH x3, 4(x4) (0x00421183)
        instr = encode_instr(.instr_type("LH_V"), .rd(3), .rs1(4), .imm(4));
        @(posedge clk); 
        compare_bit("I-LH DataSize", DataSize, 2'b01, "halfword");
        compare_bit("I-LH Usign", Usign, 1'b0, "signed");
        compare_data("I-LH IMM", IMM, 32'd4);
        
        // LHU x5, 8(x6) (0x00835283)
        instr = encode_instr(.instr_type("LHU_V"), .rd(5), .rs1(6), .imm(8));
        @(posedge clk); 
        compare_bit("I-LHU DataSize", DataSize, 2'b01, "halfword");
        compare_bit("I-LHU Usign", Usign, 1'b1, "unsigned");
        
        // LB x7, 12(x8) (0x00C40383)
        instr = encode_instr(.instr_type("LB_V"), .rd(7), .rs1(8), .imm(12));
        @(posedge clk); 
        compare_bit("I-LB DataSize", DataSize, 2'b10, "byte");
        compare_bit("I-LB Usign", Usign, 1'b0, "signed");
        
        // LBU x9, 16(x10) (0x01054483)
        instr = encode_instr(.instr_type("LBU_V"), .rd(9), .rs1(10), .imm(16));
        @(posedge clk); 
        compare_bit("I-LBU DataSize", DataSize, 2'b10, "byte");
        compare_bit("I-LBU Usign", Usign, 1'b1, "unsigned");
        
        //===========================================
        // S-TYPE STORE INSTRUCTIONS
        //===========================================
        $display("\n--- Testing S-Type Store Instructions ---");
        
        // SW x1, 0(x2) (0x00112023)
        instr = encode_instr(.instr_type("SW_V"), .rs1(2), .rs2(1), .imm(0));
        @(posedge clk); 
        compare_bit("S-SW Scalar", Scalar, 2'b00, "vector");
        compare_bit("S-SW LdReg", LdReg, 1'b0, "no load");
        compare_bit("S-SW DMemEN", DMemEN, 1'b1, "mem enabled");
        compare_bit("S-SW DMemR_W", DMemR_W, 1'b1, "write");
        compare_bit("S-SW DataSize", DataSize, 2'b00, "word");
        compare_bit("S-SW RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("S-SW IMM", IMM, 32'd0);
        compare_data("S-SW RS1Addr", RS1Addr, 5'd2);
        compare_data("S-SW RS2Addr", RS2Addr, 5'd1);
        
        // SH x3, 4(x4) (0x00321223)
        instr = encode_instr(.instr_type("SH_V"), .rs1(4), .rs2(3), .imm(4));
        @(posedge clk); 
        compare_bit("S-SH DataSize", DataSize, 2'b01, "halfword");
        compare_data("S-SH IMM", IMM, 32'd4);
        
        // SB x5, 8(x6) (0x00530423)
        instr = encode_instr(.instr_type("SB_V"), .rs1(6), .rs2(5), .imm(8));
        @(posedge clk); 
        compare_bit("S-SB DataSize", DataSize, 2'b10, "byte");
        compare_data("S-SB IMM", IMM, 32'd8);
        
        //===========================================
        // B-TYPE BRANCH INSTRUCTIONS
        //===========================================
        $display("\n--- Testing B-Type Branch Instructions ---");
        
        // BEQ x1, x2, 8 (0x00208463)
        instr = encode_instr(.instr_type("BEQ"), .rs1(1), .rs2(2), .imm(8));
        @(posedge clk); 
        compare_bit("B-BEQ Scalar", Scalar, 2'b01, "scalar"); // Bit 6 = 1 in opcode
        compare_bit("B-BEQ LdReg", LdReg, 1'b0, "no load");
        compare_bit("B-BEQ IsBR_J", IsBR_J, 2'b01, "branch");
        compare_bit("B-BEQ RS1Mux", RS1Mux, 1'b1, "use PC");
        compare_bit("B-BEQ BR", BR, 2'b00, "==");
        compare_bit("B-BEQ RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("B-BEQ IMM", IMM, 32'd8);
        compare_data("B-BEQ RS1Addr", RS1Addr, 5'd1);
        compare_data("B-BEQ RS2Addr", RS2Addr, 5'd2);
        
        // BNE x3, x4, 12 (0x00419663)
        instr = encode_instr(.instr_type("BNE"), .rs1(3), .rs2(4), .imm(12));
        @(posedge clk); 
        compare_bit("B-BNE BR", BR, 2'b01, "!=");
        compare_data("B-BNE IMM", IMM, 32'd12);
        
        // BLT x5, x6, 16 (0x0062C863)
        instr = encode_instr(.instr_type("BLT"), .rs1(5), .rs2(6), .imm(16));
        @(posedge clk); 
        compare_bit("B-BLT BR", BR, 2'b10, "<");
        compare_bit("B-BLT Usign", Usign, 1'b0, "signed");
        compare_data("B-BLT IMM", IMM, 32'd16);
        
        // BGE x7, x8, 20 (0x0083DA63)
        instr = encode_instr(.instr_type("BGE"), .rs1(7), .rs2(8), .imm(20));
        @(posedge clk); 
        compare_bit("B-BGE BR", BR, 2'b11, ">=");
        compare_bit("B-BGE Usign", Usign, 1'b0, "signed");
        compare_data("B-BGE IMM", IMM, 32'd20);
        
        // BLTU x9, x10, 24 (0x00A4EC63)
        instr = encode_instr(.instr_type("BLTU"), .rs1(9), .rs2(10), .imm(24));
        @(posedge clk); 
        compare_bit("B-BLTU BR", BR, 2'b10, "<");
        compare_bit("B-BLTU Usign", Usign, 1'b1, "unsigned");
        compare_data("B-BLTU IMM", IMM, 32'd24);
        
        // BGEU x11, x12, 28 (0x00C5FE63)
        instr = encode_instr(.instr_type("BGEU"), .rs1(11), .rs2(12), .imm(28));
        @(posedge clk); 
        compare_bit("B-BGEU BR", BR, 2'b11, ">=");
        compare_bit("B-BGEU Usign", Usign, 1'b1, "unsigned");
        compare_data("B-BGEU IMM", IMM, 32'd28);
        
        //===========================================
        // J-TYPE JUMP INSTRUCTIONS
        //===========================================
        $display("\n--- Testing J-Type Jump Instructions ---");
        
        // JAL x1, 100 (0x064000EF)
        instr = encode_instr(.instr_type("JAL"), .rd(1), .imm(100));
        @(posedge clk); 
        compare_bit("J-JAL Scalar", Scalar, 2'b01, "scalar"); // Bit 6 = 1 in opcode
        compare_bit("J-JAL LdReg", LdReg, 1'b1, "load reg");
        compare_bit("J-JAL IsBR_J", IsBR_J, 2'b10, "jump");
        compare_bit("J-JAL RS1Mux", RS1Mux, 1'b1, "use PC");
        compare_bit("J-JAL RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("J-JAL IMM", IMM, 32'd100);
        compare_data("J-JAL RDAddr", RDAddr, 5'd1);
        
        // JALR x3, x4, 8 (0x008201E7)
        instr = encode_instr(.instr_type("JALR"), .rd(3), .rs1(4), .imm(8));
        @(posedge clk); 
        compare_bit("I-JALR Scalar", Scalar, 2'b01, "scalar"); // Bit 6 = 1 in opcode
        compare_bit("I-JALR LdReg", LdReg, 1'b1, "load reg");
        compare_bit("I-JALR IsBR_J", IsBR_J, 2'b10, "jump");
        compare_bit("I-JALR RS1Mux", RS1Mux, 1'b0, "use RS1");
        compare_bit("I-JALR RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("I-JALR IMM", IMM, 32'd8);
        compare_data("I-JALR RS1Addr", RS1Addr, 5'd4);
        compare_data("I-JALR RDAddr", RDAddr, 5'd3);
        
        //===========================================
        // U-TYPE INSTRUCTIONS
        //===========================================
        $display("\n--- Testing U-Type Instructions ---");
        
        // LUI x1, 0x12345 (0x123450B7)
        instr = encode_instr(.instr_type("LUI_V"), .rd(1), .imm(32'h12345000));
        @(posedge clk); 
        compare_bit("U-LUI Scalar", Scalar, 2'b00, "vector");
        compare_bit("U-LUI LdReg", LdReg, 1'b1, "load reg");
        compare_bit("U-LUI ALUK", ALUK, 4'h9, "LUI");
        compare_bit("U-LUI RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("U-LUI IMM", IMM, 32'h12345000);
        compare_data("U-LUI RDAddr", RDAddr, 5'd1);
        
        // AUIPC x2, 0xABCDE (0xABCDE117)
        instr = encode_instr(.instr_type("AUIPC_V"), .rd(2), .imm(32'hABCDE000));
        @(posedge clk); 
        compare_bit("U-AUIPC Scalar", Scalar, 2'b00, "vector");
        compare_bit("U-AUIPC LdReg", LdReg, 1'b1, "load reg");
        compare_bit("U-AUIPC RS1Mux", RS1Mux, 1'b1, "use PC");
        compare_bit("U-AUIPC ALUK", ALUK, 4'h0, "ADD");
        compare_bit("U-AUIPC RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("U-AUIPC IMM", IMM, 32'hABCDE000);
        compare_data("U-AUIPC RDAddr", RDAddr, 5'd2);
        
        //===========================================
        // SCALAR INSTRUCTIONS (Custom Extensions)
        //===========================================
        $display("\n--- Testing Scalar Instructions ---");
        
        // Scalar R-type (opcode bit 6 = 1)
        // ADD (scalar) x1, x2, x3 (0x003100F3)
        instr = encode_instr(.instr_type("ADD_S"), .rd(1), .rs1(2), .rs2(3));
        @(posedge clk); 
        compare_bit("Scalar R-ADD Scalar", Scalar, 2'b01, "scalar");
        compare_bit("Scalar R-ADD LdReg", LdReg, 1'b1, "load reg");
        compare_bit("Scalar R-ADD ALUK", ALUK, 4'h0, "ADD");
        
        // Scalar I-type arithmetic (opcode bit 6 = 1)
        // ADDI (scalar) x4, x5, 50 (0x03228253)
        instr = encode_instr(.instr_type("ADDI_S"), .rd(4), .rs1(5), .imm(50));
        @(posedge clk); 
        compare_bit("Scalar I-ADDI Scalar", Scalar, 2'b01, "scalar");
        compare_bit("Scalar I-ADDI RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_data("Scalar I-ADDI IMM", IMM, 32'd50);
        
        // SX_S (sx.slt - vector to scalar set less than) - opcode 0x7E
        // Compares vector register with scalar, writes mask to scalar register
        instr = encode_instr(.instr_type("SX_S"), .rd(0), .rs1(1), .rs2(1));
        @(posedge clk); 
        compare_bit("SX_S Scalar", Scalar, 2'b10, "vec to scalar");
        compare_bit("SX_S LdReg", LdReg, 1'b1, "load scalar reg");
        compare_bit("SX_S DMemEN", DMemEN, 1'b0, "no mem");
        compare_bit("SX_S DMemR_W", DMemR_W, 1'b0, "no write");
        compare_bit("SX_S RS2Mux", RS2Mux, 1'b0, "use RS2");
        compare_bit("SX_S ALUK", ALUK, 4'h8, "SLT");
        
        // SX_I (sx.slti - vector to scalar set less than immediate) - opcode 0x7D
        // Compares vector register with immediate, writes mask to scalar register
        instr = encode_instr(.instr_type("SX_I"), .rd(0), .rs1(1), .imm(0));
        @(posedge clk); 
        compare_bit("SX_I Scalar", Scalar, 2'b10, "vec to scalar");
        compare_bit("SX_I LdReg", LdReg, 1'b1, "load scalar reg");
        compare_bit("SX_I DMemEN", DMemEN, 1'b0, "no mem");
        compare_bit("SX_I DMemR_W", DMemR_W, 1'b0, "no write");
        compare_bit("SX_I RS2Mux", RS2Mux, 1'b1, "use IMM");
        compare_bit("SX_I ALUK", ALUK, 4'h8, "SLT");
        
        //==========================================
        // SPECIAL CASES
        //===========================================
        $display("\n--- Testing Special Cases ---");
        
        // HALT (all zeros)
        instr = encode_instr(.instr_type("HALT"));
        @(posedge clk); 
        compare_bit("HALT Finish", Finish, 1'b1, "finish");
        
        // Negative immediate sign extension
        instr = encode_instr(.instr_type("ADDI_V"), .rd(1), .rs1(0), .imm(32'hFFFFFFFF)); // ADDI x1, x0, -1
        @(posedge clk); 
        compare_data("Negative IMM sign-ext", IMM, 32'hFFFFFFFF);
        
        // Large positive immediate
        instr = encode_instr(.instr_type("ADDI_V"), .rd(1), .rs1(0), .imm(32'h7FF)); // ADDI x1, x0, 2047
        @(posedge clk); 
        compare_data("Positive IMM", IMM, 32'h7FF);
        
        // Test all register addresses
        instr = 32'hFFFFFFFF; // All 1s
        @(posedge clk); 
        compare_data("Max RS1Addr", RS1Addr, 5'd31);
        compare_data("Max RS2Addr", RS2Addr, 5'd31);
        compare_data("Max RDAddr", RDAddr, 5'd31);
        
        //===========================================
        // SUMMARY
        //===========================================
        @(posedge clk);
        report_summary();
        
        $display("========================================");
        $display("Decoder Testbench Complete");
        $display("========================================");
        $finish;
    end

endmodule




