`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/03/2025 09:31:10 AM
// Design Name: 
// Module Name: core
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

module core #(
    parameter int WARPS_PER_CORE, // if assigning 1 block per core, this is same as num_warps_per_block
    parameter int THREADS_PER_WARP
    )(
    input logic clk, reset,
    // core info
    input logic start, // one cycle only
    output logic done,
    input kernel_config_t kernel_config,
    input data_t core_id, core_block_id, 
    // instr mem - one per warp
    output logic [WARPS_PER_CORE-1:0] instr_mem_valid,
    output instr_mem_addr_t [$clog2(WARPS_PER_CORE)-1:0] instr_mem_addr,
    input logic [WARPS_PER_CORE-1:0] instr_mem_resp_ready,
    input instr_t [$clog2(WARPS_PER_CORE)-1:0] instr_mem_resp_data,
    // data mem - one per thread - extra lsu for warp scalar regs
    output logic [THREADS_PER_WARP:0] data_mem_valid,
    output data_mem_addr_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_addr,
    output data_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_data,
    output logic [THREADS_PER_WARP:0] data_mem_we,
    input logic [THREADS_PER_WARP:0] data_mem_resp_ready,
    input data_t [$clog2(THREADS_PER_WARP+1)-1:0] data_mem_resp_data
    );
    
    data_t num_warps; assign num_warps = kernel_config.num_warps_per_block;
    
    // warp signals    
    warp_state_t [$clog2(WARPS_PER_CORE)-1:0] warp_state;
    
    logic [$clog2(WARPS_PER_CORE)-1:0] current_warp;
    warp_state_t current_warp_state; assign current_warp_state = warp_state[current_warp];
    // per warp module signals
    instr_mem_addr_t [$clog2(WARPS_PER_CORE)-1:0] pc, next_pc;
    
    fetcher_state_t [$clog2(WARPS_PER_CORE)-1:0] fetcher_state;
    instr_t [$clog2(WARPS_PER_CORE)-1:0] fetched_instr;
    
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] Scalar;
    logic [$clog2(WARPS_PER_CORE)-1:0] LdReg;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] IsBR_J;
    logic [$clog2(WARPS_PER_CORE)-1:0] DMemEN;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] DataSize;
    logic [$clog2(WARPS_PER_CORE)-1:0] DMemR_W;
    logic [$clog2(WARPS_PER_CORE)-1:0] Usign;
    logic [$clog2(WARPS_PER_CORE)-1:0] RS1Mux;
    logic [$clog2(WARPS_PER_CORE)-1:0][1:0] BR;
    logic [$clog2(WARPS_PER_CORE)-1:0][3:0] ALUK;
    logic [$clog2(WARPS_PER_CORE)-1:0] RS2Mux;
    logic [$clog2(WARPS_PER_CORE)-1:0] Finish;
    logic [$clog2(WARPS_PER_CORE)-1:0][4:0] RS1Addr, RS2Addr, RDAddr; 
    data_t [$clog2(WARPS_PER_CORE)-1:0] IMM;
    
    // scalar registers
    // if THREADS_PER_WARP < data_t, upper bits are cut off of scalar registers[EXEC_MASK_REG]
    logic [$clog2(WARPS_PER_CORE)-1:0][THREADS_PER_WARP-1:0] warp_execution_mask;
    logic [THREADS_PER_WARP-1:0] current_warp_execution_mask; 
    assign current_warp_execution_mask = warp_execution_mask[current_warp];
    data_t s_rs1, s_rs2, s_lsu_out, s_alu_out, s_pc_jump, v_to_s_value;
    lsu_state_t s_lsu_state;
        
    // per thread module signals
    data_t [$clog2(THREADS_PER_WARP)-1:0] rs1, rs2;
    data_t [$clog2(THREADS_PER_WARP)-1:0] alu_out;
    // all jump/br instr are actually scalar for now, TBD: conditional jump divergence logic
    data_t [$clog2(THREADS_PER_WARP)-1:0] pc_jump; 
    
    // logic [$clog2(THREADS_PER_WARP)-1:0] core_we;
    lsu_state_t [$clog2(THREADS_PER_WARP)-1:0] lsu_state;
    data_t [$clog2(THREADS_PER_WARP)-1:0] lsu_out;
    
    // one per core modules, since we only run one warp at a time,
    // only one scalar alu and lsu is needed (only one scalar reg per warp)
    alu s_alu_inst(
        .clk(clk), .reset(reset),
        .warp_state(warp_state),
        .pc(pc[current_warp]),
        // data + control signals
        .rs1(s_rs1), .rs2(s_rs2), .imm(IMM[current_warp]),
        .IsBR_J(IsBR_J[current_warp]),
        .Usign(Usign[current_warp]),
        .RS1Mux(RS1Mux[current_warp]),
        .BR(BR[current_warp]),
        .ALUK(ALUK[current_warp]),
        .RS2Mux(RS2Mux[current_warp]),
        
        .alu_out(s_alu_out),
        .pc_jump(s_pc_jump)
    );

    lsu s_lsu_inst(
        .clk(clk), .reset(reset),
        .warp_state(warp_state),
        // data + control signals
        .rs1(s_rs1), .rs2(s_rs2), .imm(IMM[current_warp]),
        .DataSize(DataSize[current_warp]),
        .DMemR_W(DMemR_W[current_warp]),
        .Usign(Usign[current_warp]),
        // data mem - use the last data mem array values
        .mem_valid(data_mem_valid[THREADS_PER_WARP]),
        .mem_addr(data_mem_addr[THREADS_PER_WARP]),
        .mem_data(data_mem_data[THREADS_PER_WARP]),
        .mem_we(data_mem_we[THREADS_PER_WARP]),
        .mem_resp_ready(data_mem_resp_ready[THREADS_PER_WARP]),
        .mem_resp_data(data_mem_resp_data[THREADS_PER_WARP]),
        // output back to core
        .lsu_state_out(s_lsu_state),
        .lsu_out(s_lsu_out)
    );
    
    // per warp module instantiations
    genvar w;
    generate
        for (w = 0; w < WARPS_PER_CORE; w++) begin : fetch
            fetcher fetcher_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .pc(pc[w]),
                // instr mem
                .mem_valid(instr_mem_valid[w]),
                .mem_addr(instr_mem_addr[w]),
                .mem_resp_ready(instr_mem_resp_ready[w]),
                .mem_resp_data(instr_mem_resp_data[w]),
                // output back to core
                .out_fetcher_state(fetcher_state[w]),
                .out_instr(fetched_instr[w])            
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : decode
            decoder decoder_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .instr(fetched_instr[w]),
                // control signals
                .Scalar(Scalar[w]),
                .LdReg(LdReg[w]),
                .IsBR_J(IsBR_J[w]),
                .DMemEN(DMemEN[w]),
                .DataSize(DataSize[w]),
                .DMemR_W(DMemR_W[w]),
                .Usign(Usign[w]),
                .RS1Mux(RS1Mux[w]),
                .BR(BR[w]),
                .ALUK(ALUK[w]),
                .RS2Mux(RS2Mux[w]),
                .Finish(Finish[w]),
                // data/addr signals
                .RS1Addr(RS1Addr[w]), .RS2Addr(RS2Addr[w]), .RDAddr(RDAddr[w]),
                .IMM(IMM[w])            
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : s_reg_file
            scalar_regs #(
                .SCALAR_REGS_PER_WARP(32)
            ) scalar_regs_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .warp_enable((current_warp == w)), // enable when current_warp matches
                .execution_mask(warp_execution_mask[w]), 
                // data + control signals
                .Scalar(Scalar[w]),
                .LdReg(LdReg[w]),
                .IsBR_J(IsBR_J[w]),
                .DMemEN(DMemEN[w]),               
                // data/addr signals
                .RS1Addr(RS1Addr[w]), .RS2Addr(RS2Addr[w]), .RDAddr(RDAddr[w]),
                // output reg values, per thread
                .rs1(scalar_rs1), .rs2(scalar_rs2),
                // input load reg values, per thread
                .alu_out(s_alu_out), .lsu_out(s_lsu_out), .next_pc(pc[w] + 4), .v_to_s_value(v_to_s_value)
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : reg_file
            regs #(
                .THREADS_PER_WARP(THREADS_PER_WARP),
                .REGS_PER_THREAD(32)
            ) regs_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .warp_enable((current_warp == w)), // enable when current_warp matches
                .execution_mask(warp_execution_mask[w]), 
                // warp/block identifiers
                .warp_id(w), .block_id(core_block_id), .block_size(num_warps * THREADS_PER_WARP),
                // data + control signals
                .Scalar(Scalar[w]),
                .LdReg(LdReg[w]),
                .IsBR_J(IsBR_J[w]),
                .DMemEN(DMemEN[w]), 
                // data/addr signals
                .RS1Addr(RS1Addr[w]), .RS2Addr(RS2Addr[w]), .RDAddr(RDAddr[w]),
                // output reg values, per thread
                .rs1(rs1), .rs2(rs2),
                // input load reg values, per thread - alu and lsu outputs for all threads
                .alu_out(alu_out), .lsu_out(lsu_out), .next_pc(pc[w] + 4)
            );            
        end
    endgenerate
    
    // per thread module instantiations - these are core resources shared upon each new warp executing
    // simplified since we can only run one warp's amount of alu/lsu computations at a time
    genvar t;
    generate
        for (t = 0; t < THREADS_PER_WARP; t++) begin : thread_alu
            alu alu_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state),
                .pc(pc[current_warp]),
                // data + control signals
                .rs1(rs1[t]), .rs2(rs2[t]), .imm(IMM[current_warp]), // constant immediates within warp
                .IsBR_J(IsBR_J[current_warp]),
                .Usign(Usign[current_warp]),
                .RS1Mux(RS1Mux[current_warp]),
                .BR(BR[current_warp]),
                .ALUK(ALUK[current_warp]),
                .RS2Mux(RS2Mux[current_warp]),
                
                .alu_out(alu_out[t]),
                .pc_jump(pc_jump[t])
            );
        end for (t = 0; t < THREADS_PER_WARP; t++) begin : thread_lsu
            lsu lsu_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state),
                // data + control signals
                .rs1(s_rs1), .rs2(s_rs2), .imm(IMM[current_warp]), 
                .DataSize(DataSize[current_warp]),
                .DMemR_W(DMemR_W[current_warp]),
                .Usign(Usign[current_warp]),
                // data mem - use each thread's respective data mem array values
                .mem_valid(data_mem_valid[t]),
                .mem_addr(data_mem_addr[t]),
                .mem_data(data_mem_data[t]),
                .mem_we(data_mem_we[t]),
                .mem_resp_ready(data_mem_resp_ready[t]),
                .mem_resp_data(data_mem_resp_data[t]),
                // output back to core
                .lsu_state_out(lsu_state[t]),
                .lsu_out(lsu_out[t])
            );                
        end
    endgenerate
    
    // for done signal
    logic [WARPS_PER_CORE-1:0] done_array;
    always_comb begin
        // the num of warps per block could be equal to or smaller than num of warps per core,
        // assuming each block can get totally assigned to just one core
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            if (w < num_warps) done_array[1 << w] = (warp_state[w] == WARP_DONE); 
            else done_array[1 << w] = 1;
        end
    end
    assign done = &done_array;
    
    // for lsu done signal
    logic [THREADS_PER_WARP-1:0] lsu_array;
    logic lsu_done;
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_array[1 << t] = (lsu_state[t] == LSU_DONE); 
        end
    end
    assign lsu_done = &lsu_array;
    
    // for choosing new warps
    logic [WARPS_PER_CORE-1:0] first_free_warp, free_warps;
    logic [$clog2(WARPS_PER_CORE)-1:0] first_free_warp_id;
    generate
        for (w = 0; w < WARPS_PER_CORE; w++) begin
            assign free_warps[1 << w] = (warp_state[w] != WARP_IDLE) && 
                                (warp_state[w] != WARP_FETCH) && 
                                (warp_state[w] != WARP_DONE) && (w < num_warps);
            assign first_free_warp = free_warps & (~free_warps + 1);
        end
    endgenerate
    utility #(WARPS_PER_CORE) util_inst(first_free_warp, first_free_warp_id); // could be -1
    
    // for vector to scalar
    always_comb begin
        v_to_s_value = 0;
        if (Scalar[current_warp] == 2) 
            // the number of threads per warp should equal data width so execution mask matches
            for (int t = 0; t < THREADS_PER_WARP; t++) 
                v_to_s_value[1 << t] = alu_out[t];
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            $display("Resetting core %d", core_id);
            done <= 0;
            current_warp <= 0;
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                warp_state[w] <= WARP_IDLE;
                fetcher_state[w] <= FETCHER_IDLE;
                pc[w] <= 0;
            end
        end else if (start) begin // upon reset or starting again
            $display("Executing block %d on core %d", core_block_id, core_id);
            current_warp <= 0;
            for (int w = 0; w < WARPS_PER_CORE; w++) begin // enter fetch state
                if (w < num_warps) begin // extra warps in core don't matter
                    warp_state[w] <= WARP_FETCH;
                    fetcher_state[w] <= FETCHER_IDLE;
                    pc[w] <= kernel_config.base_instr_addr;
                end
            end
        end else begin // during execution
        
            /* fetches and decodes happen in parallel across warps */
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                if (w < num_warps) begin
                    if (warp_state[w] == WARP_FETCH && fetcher_state[w] == FETCHER_DONE) begin
                        $display("Warp %d at block %d fetched instr x%h at addr x%h", w, core_block_id, fetched_instr[w], pc[w]);
                        warp_state[w] <= WARP_DECODE;
                    end
                end
            end
            /* requests, executes, updates, and done happen when warp is chosen */
            // choose new warp if ready, in WARP_UPDATE ideally, WARP_DONE if skipped update or no other warps were ready yet
            if (current_warp_state == WARP_UPDATE || current_warp_state == WARP_DONE) begin
                for (int w = 0; w < WARPS_PER_CORE; w++) begin
                    if (w < num_warps) begin
                        if (first_free_warp_id != -1) current_warp <= first_free_warp_id;
                    end
                end
            end
            case (current_warp_state) 
                WARP_IDLE: $display("Warp %d at block %d is idle", current_warp, core_block_id);
                WARP_FETCH: $display("Warp %d at block %d is fetching", current_warp, core_block_id);
                WARP_DECODE: begin // assuming decode only takes one cycle, skip if no load
                    warp_state[current_warp] <= (DMemEN && (!DMemR_W)) ? WARP_REQUEST : WARP_EXECUTE; 
                end
                WARP_REQUEST: warp_state[current_warp] <= WARP_WAIT;
                WARP_WAIT: begin // wait for lsu
                    if (lsu_done) warp_state[current_warp] <= WARP_UPDATE; // don't need execute on loads
                end
                WARP_EXECUTE: begin
                    $display("Warp %d at block %d executing instr x%h at addr x%h", current_warp, core_block_id, fetched_instr[current_warp], pc[current_warp]);
                    $display("Execution mask: %32b", current_warp_execution_mask);
                    if (Scalar[current_warp] && IsBR_J[current_warp]) begin // branch/jump
                        next_pc[current_warp] <= (s_pc_jump) ? s_alu_out : pc[current_warp] + 4;
                    end else begin
                        next_pc[current_warp] <= pc[current_warp] + 4;
                    end
                    warp_state[current_warp] <= WARP_UPDATE; // assuming execute only takes one cycle
                    
                end
                WARP_UPDATE: begin
                    $display("Warp %d at block %d finished excuting instr x%h at addr x%h", current_warp, core_block_id, fetched_instr[current_warp], pc[current_warp]);
                    warp_state[current_warp] <= (Finish[current_warp]) ? WARP_DONE : WARP_FETCH;
                end
                WARP_DONE: $display("Warp %d at block %d is done", current_warp, core_block_id);
            endcase
        end
    end   
endmodule
