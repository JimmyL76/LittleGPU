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
    output instr_mem_addr_t instr_mem_addr [WARPS_PER_CORE],
    input logic [WARPS_PER_CORE-1:0] instr_mem_resp_valid,
    output logic [WARPS_PER_CORE-1:0] instr_mem_resp_ready,
    input instr_t instr_mem_resp_data [WARPS_PER_CORE],
    // data mem - one per thread - extra lsu for warp scalar regs
    output logic [THREADS_PER_WARP:0] data_mem_valid,
    output data_mem_addr_t data_mem_addr [THREADS_PER_WARP+1],
    output data_t data_mem_data [THREADS_PER_WARP+1],
    output logic [(`DATA_WIDTH/8)-1:0] data_mem_we [THREADS_PER_WARP+1],
    input logic [THREADS_PER_WARP:0] data_mem_resp_valid,
    output logic [THREADS_PER_WARP:0] data_mem_resp_ready,
    input data_t data_mem_resp_data [THREADS_PER_WARP+1]
    );

    initial begin
        if (THREADS_PER_WARP != `DATA_WIDTH) begin
            $fatal(1, "Architecture constraint violated: THREADS_PER_WARP (%0d) must equal DATA_WIDTH (%0d)", 
                THREADS_PER_WARP, `DATA_WIDTH);
        end
    end
    
    data_t num_warps; assign num_warps = kernel_config.num_warps_per_block;
    
    // warp signals    
    warp_state_t warp_state [WARPS_PER_CORE];
    
    // resource allocation - separate execute (ALU) and memory (LSU) resources
    logic [$clog2(WARPS_PER_CORE)-1:0] execute_warp;  // which warp owns ALU resources
    logic execute_resources_busy;
    logic [$clog2(WARPS_PER_CORE)-1:0] memory_warp;   // which warp owns LSU resources
    logic memory_resources_busy;
    
    // execute resource valid check
    logic execute_warp_valid;
    assign execute_warp_valid = execute_resources_busy && (execute_warp < num_warps);
    
    // memory resource valid and type checks
    logic memory_warp_valid;
    assign memory_warp_valid = memory_resources_busy && (memory_warp < num_warps);
    
    logic memory_is_scalar;
    assign memory_is_scalar = memory_warp_valid && (Scalar[memory_warp] == 1);
    
    logic memory_is_vector;
    assign memory_is_vector = memory_warp_valid && (Scalar[memory_warp] != 1);
    
    // signals for the warp currently using execution resources
    warp_state_t execute_warp_state; 
    assign execute_warp_state = execute_warp_valid ? warp_state[execute_warp] : WARP_IDLE;
    logic [THREADS_PER_WARP-1:0] execute_warp_execution_mask; 
    assign execute_warp_execution_mask = execute_warp_valid ? warp_execution_mask[execute_warp] : 0;
    
    // signals for the warp currently using memory resources
    warp_state_t memory_warp_state;
    assign memory_warp_state = memory_warp_valid ? warp_state[memory_warp] : WARP_IDLE;
    logic [THREADS_PER_WARP-1:0] memory_warp_execution_mask;
    assign memory_warp_execution_mask = memory_warp_valid ? warp_execution_mask[memory_warp] : 0;
    
    // per-thread memory active signals (for gating LSU operations)
    logic memory_thread_active [THREADS_PER_WARP];
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            memory_thread_active[t] = memory_is_vector && memory_warp_execution_mask[t];
        end
    end
    
    // per warp module signals
    instr_mem_addr_t pc [WARPS_PER_CORE], next_pc [WARPS_PER_CORE];
    
    logic fetcher_done [WARPS_PER_CORE];
    instr_t fetched_instr [WARPS_PER_CORE];
    
    logic [1:0] Scalar [WARPS_PER_CORE];
    logic LdReg [WARPS_PER_CORE];
    logic [1:0] IsBR_J [WARPS_PER_CORE];
    logic DMemEN [WARPS_PER_CORE];
    logic [1:0] DataSize [WARPS_PER_CORE];
    logic DMemR_W [WARPS_PER_CORE];
    logic Usign [WARPS_PER_CORE];
    logic RS1Mux [WARPS_PER_CORE];
    logic [1:0] BR [WARPS_PER_CORE];
    logic [3:0] ALUK [WARPS_PER_CORE];
    logic RS2Mux [WARPS_PER_CORE];
    logic Finish [WARPS_PER_CORE];
    logic [4:0] RS1Addr [WARPS_PER_CORE], RS2Addr [WARPS_PER_CORE], RDAddr [WARPS_PER_CORE]; 
    data_t IMM [WARPS_PER_CORE];
    
    // scalar registers
    // if THREADS_PER_WARP < data_t, upper bits are cut off of scalar registers[EXEC_MASK_REG]
    logic [THREADS_PER_WARP-1:0] warp_execution_mask [WARPS_PER_CORE];
    data_t s_rs1_per_warp [WARPS_PER_CORE], s_rs2_per_warp [WARPS_PER_CORE];
    data_t s_rs1, s_rs2, s_lsu_out, s_alu_out, s_pc_jump, v_to_s_value;
    lsu_state_t s_lsu_state;
    
    // mux execute warp's scalar register outputs
    assign s_rs1 = s_rs1_per_warp[execute_warp];
    assign s_rs2 = s_rs2_per_warp[execute_warp];
    
    // registered scalar register values for memory stage (to keep stable when execute resources are freed)
    data_t s_rs1_mem, s_rs2_mem;
    data_t s_imm_mem;
    logic [1:0] s_DataSize_mem;
    logic s_DMemR_W_mem;
    logic s_Usign_mem;
        
    // per thread module signals
    data_t rs1_per_warp [WARPS_PER_CORE][THREADS_PER_WARP], rs2_per_warp [WARPS_PER_CORE][THREADS_PER_WARP];
    data_t rs1 [THREADS_PER_WARP], rs2 [THREADS_PER_WARP];
    // mux execute warp's register outputs
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            rs1[t] = execute_warp_valid ? rs1_per_warp[execute_warp][t] : 0;
            rs2[t] = execute_warp_valid ? rs2_per_warp[execute_warp][t] : 0;
        end
    end
    
    // registered vector register values for memory stage (to keep stable when execute resources are freed)
    data_t rs1_mem [THREADS_PER_WARP], rs2_mem [THREADS_PER_WARP];
    data_t v_imm_mem;
    logic [1:0] v_DataSize_mem;
    logic v_DMemR_W_mem;
    logic v_Usign_mem;
    data_t alu_out [THREADS_PER_WARP];
    // branches/jumps use scalar control flow (all threads share same PC)
    // divergence handled via execution masks (predication), not per-thread PCs
    data_t pc_jump [THREADS_PER_WARP]; 
    
    // logic core_we [THREADS_PER_WARP];
    lsu_state_t lsu_state [THREADS_PER_WARP];
    data_t lsu_out [THREADS_PER_WARP];
    
    // one per core modules, since we only run one warp at a time,
    // only one scalar alu and lsu is needed (only one scalar reg per warp)
    alu s_alu_inst(
        .pc(pc[execute_warp]),
        .rs1(s_rs1), 
        .rs2(s_rs2), 
        .imm(IMM[execute_warp]),
        .IsBR_J(IsBR_J[execute_warp]),
        .Usign(Usign[execute_warp]),
        .RS1Mux(RS1Mux[execute_warp]),
        .BR(BR[execute_warp]),
        .ALUK(ALUK[execute_warp]),
        .RS2Mux(RS2Mux[execute_warp]),
        
        .alu_out(s_alu_out),
        .pc_jump(s_pc_jump)
    );

    lsu s_lsu_inst(
        .clk(clk), .reset(reset),
        .warp_state(memory_warp_state),
        .thread_active(memory_is_scalar),  // scalar LSU only for scalar instructions
        // data + control signals - use registered values from execute stage
        .rs1(s_rs1_mem), 
        .rs2(s_rs2_mem), 
        .imm(s_imm_mem),
        .DataSize(s_DataSize_mem),
        .DMemR_W(s_DMemR_W_mem),
        .Usign(s_Usign_mem),
        // data mem - use the last data mem array values
        .mem_valid(data_mem_valid[THREADS_PER_WARP]),
        .mem_addr(data_mem_addr[THREADS_PER_WARP]),
        .mem_data(data_mem_data[THREADS_PER_WARP]),
        .mem_we(data_mem_we[THREADS_PER_WARP]),
        .mem_resp_valid(data_mem_resp_valid[THREADS_PER_WARP]),
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
                .mem_resp_valid(instr_mem_resp_valid[w]),
                .mem_resp_ready(instr_mem_resp_ready[w]),
                .mem_resp_data(instr_mem_resp_data[w]),
                // output back to core
                .done(fetcher_done[w]),
                .out_instr(fetched_instr[w])            
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : decode
            decoder decoder_inst(
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
                .warp_enable(((execute_warp == w) && execute_resources_busy) || (warp_state[w] == WARP_WRITEBACK)), // enable when execute_warp matches or during writeback
                .execution_mask(warp_execution_mask[w]), 
                // data + control signals
                .Scalar(Scalar[w]),
                .LdReg(LdReg[w]),
                .IsBR_J(IsBR_J[w]),
                .DMemEN(DMemEN[w]),               
                // data/addr signals
                .RS1Addr(RS1Addr[w]), .RS2Addr(RS2Addr[w]), .RDAddr(RDAddr[w]),
                // output reg values, per warp
                .rs1(s_rs1_per_warp[w]), .rs2(s_rs2_per_warp[w]),
                // input load reg values, per thread
                // next_pc only ever used for JAL/JALR
                .alu_out(s_alu_out), .lsu_out(s_lsu_out), .next_pc(pc[w] + 4), .v_to_s_value(v_to_s_value)
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : reg_file
            regs #(
                .THREADS_PER_WARP(THREADS_PER_WARP),
                .REGS_PER_THREAD(32)
            ) regs_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .warp_enable(((execute_warp == w) && execute_resources_busy) || (warp_state[w] == WARP_WRITEBACK)), // enable when execute_warp matches or during writeback
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
                .rs1(rs1_per_warp[w]), .rs2(rs2_per_warp[w]),
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
            // vector ALUs - no gating, just direct connections
            // register files handle all read/write gating
            alu alu_inst(
                .pc(pc[execute_warp]),
                .rs1(rs1[t]),
                .rs2(rs2[t]),
                .imm(IMM[execute_warp]),
                .IsBR_J(IsBR_J[execute_warp]),
                .Usign(Usign[execute_warp]),
                .RS1Mux(RS1Mux[execute_warp]),
                .BR(BR[execute_warp]),
                .ALUK(ALUK[execute_warp]),
                .RS2Mux(RS2Mux[execute_warp]),
                
                .alu_out(alu_out[t]),
                .pc_jump(pc_jump[t])
            );
        end for (t = 0; t < THREADS_PER_WARP; t++) begin : thread_lsu
            // vector LSUs - must gate by thread_active to prevent inactive threads from:
            // making memory requests + being counted in lsu_done logic
            lsu lsu_inst(
                .clk(clk), .reset(reset),
                .warp_state(memory_warp_state),
                .thread_active(memory_thread_active[t]),  // gate by execution mask for vector only
                // data + control signals - use registered values from execute stage
                .rs1(rs1_mem[t]), 
                .rs2(rs2_mem[t]), 
                .imm(v_imm_mem),
                .DataSize(v_DataSize_mem),
                .DMemR_W(v_DMemR_W_mem),
                .Usign(v_Usign_mem),
                // data mem - use each thread's respective data mem array values
                .mem_valid(data_mem_valid[t]),
                .mem_addr(data_mem_addr[t]),
                .mem_data(data_mem_data[t]),
                .mem_we(data_mem_we[t]),
                .mem_resp_valid(data_mem_resp_valid[t]),
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
            if (w < num_warps) done_array[w] = (warp_state[w] == WARP_DONE); 
            else done_array[w] = 1;
        end
    end
    assign done = &done_array;
    
    // for lsu done signal
    logic [THREADS_PER_WARP-1:0] lsu_array;
    logic lsu_done;
    always_comb begin
        if (memory_is_scalar) begin
            // scalar load/store - check scalar LSU only
            lsu_done = (s_lsu_state == LSU_DONE);
        end else if (memory_is_vector) begin
            // vector load/store - check all ACTIVE thread LSUs
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                if (memory_warp_execution_mask[t]) begin
                    // active thread - check if LSU is done
                    lsu_array[t] = (lsu_state[t] == LSU_DONE);
                end else begin
                    // inactive thread - always considered "done"
                    lsu_array[t] = 1;
                end
            end
            lsu_done = &lsu_array;
        end else begin
            lsu_done = 0;
        end
    end
    
    // find next warp ready to execute (needs ALU resources)
    logic [WARPS_PER_CORE-1:0] warps_ready_to_execute;
    logic [$clog2(WARPS_PER_CORE)-1:0] next_execute_warp;
    always_comb begin
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            // warp is ready if it's in DECODE and resources are free
            warps_ready_to_execute[w] = (warp_state[w] == WARP_DECODE) && (w < num_warps);
        end
    end
    
    // priority encoder to find first ready warp
    logic [WARPS_PER_CORE-1:0] first_ready_warp_onehot;
    assign first_ready_warp_onehot = warps_ready_to_execute & (~warps_ready_to_execute + 1);
    utility #(WARPS_PER_CORE) exec_warp_selector(first_ready_warp_onehot, next_execute_warp);
    
    // find next warp ready for memory (needs LSU resources)
    logic [WARPS_PER_CORE-1:0] warps_ready_for_memory;
    logic [$clog2(WARPS_PER_CORE)-1:0] next_memory_warp;
    always_comb begin
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            // warp is ready for memory if it's in MEMORY state
            warps_ready_for_memory[w] = (warp_state[w] == WARP_MEMORY) && (w < num_warps);
        end
    end
    
    // priority encoder to find first ready warp for memory
    logic [WARPS_PER_CORE-1:0] first_memory_warp_onehot;
    assign first_memory_warp_onehot = warps_ready_for_memory & (~warps_ready_for_memory + 1);
    utility #(WARPS_PER_CORE) mem_warp_selector(first_memory_warp_onehot, next_memory_warp);
    
    // for vector to scalar - always calculate, let scalar_regs gate the write
    // NOTE: this operation requires THREADS_PER_WARP == DATA_WIDTH (execution mask alignment)
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++) 
            v_to_s_value[t] = alu_out[t];
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            $display("Resetting core %d", core_id);
            execute_warp <= 0;
            execute_resources_busy <= 0;
            memory_warp <= 0;
            memory_resources_busy <= 0;
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                warp_state[w] <= WARP_IDLE;
                pc[w] <= 0;
            end
        end else if (start) begin // upon reset or starting again
            $display("Executing block %d on core %d", core_block_id, core_id);
            execute_warp <= 0;
            execute_resources_busy <= 0;
            memory_warp <= 0;
            memory_resources_busy <= 0;
            for (int w = 0; w < WARPS_PER_CORE; w++) begin // enter fetch state
                if (w < num_warps) begin // extra warps in core don't matter
                    warp_state[w] <= WARP_FETCH;
                    pc[w] <= kernel_config.base_instr_addr;
                end
            end
        end else begin // during execution
        
            /* fetches and decodes happen in parallel across warps */
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                if (w < num_warps) begin
                    if (warp_state[w] == WARP_FETCH && fetcher_done[w]) begin
                        $display("Warp %d at block %d fetched instr x%h at addr x%h", w, core_block_id, fetched_instr[w], pc[w]);
                        warp_state[w] <= WARP_DECODE;
                    end
                end
            end
            
            /* grant execution resources to next ready warp */
            if (!execute_resources_busy && (|warps_ready_to_execute)) begin
                execute_warp <= next_execute_warp;
                execute_resources_busy <= 1;
                $display("Core %d: granting execution resources to warp %d", core_id, next_execute_warp);
            end
            
            /* grant memory resources to next ready warp */
            if (!memory_resources_busy && (|warps_ready_for_memory)) begin
                memory_warp <= next_memory_warp;
                memory_resources_busy <= 1;
                $display("Core %d: granting memory resources to warp %d", core_id, next_memory_warp);
            end
            
            /* execute stage - only for warp that owns execution resources */
            if (execute_warp_valid) begin
                case (warp_state[execute_warp]) 
                    WARP_DECODE: begin // transition to execute
                        warp_state[execute_warp] <= WARP_EXECUTE; 
                    end
                    WARP_EXECUTE: begin
                        $display("Warp %d at block %d executing instr x%h at addr x%h", execute_warp, core_block_id, fetched_instr[execute_warp], pc[execute_warp]);
                        $display("Execution mask: %32b", warp_execution_mask[execute_warp]);
                        if (IsBR_J[execute_warp]) begin // branch/jump
                            next_pc[execute_warp] <= (s_pc_jump) ? s_alu_out : pc[execute_warp] + 4;
                        end else begin
                            next_pc[execute_warp] <= pc[execute_warp] + 4;
                        end
                        // if load/store instruction, go to memory stage
                        if (DMemEN[execute_warp]) begin
                            warp_state[execute_warp] <= WARP_MEMORY;
                            // register values for memory stage (to keep stable when execute resources are freed)
                            if (Scalar[execute_warp] == 1) begin
                                // scalar load/store
                                s_rs1_mem <= s_rs1;
                                s_rs2_mem <= s_rs2;
                                s_imm_mem <= IMM[execute_warp];
                                s_DataSize_mem <= DataSize[execute_warp];
                                s_DMemR_W_mem <= DMemR_W[execute_warp];
                                s_Usign_mem <= Usign[execute_warp];
                            end else begin
                                // vector load/store
                                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                                    rs1_mem[t] <= rs1[t];
                                    rs2_mem[t] <= rs2[t];
                                end
                                v_imm_mem <= IMM[execute_warp];
                                v_DataSize_mem <= DataSize[execute_warp];
                                v_DMemR_W_mem <= DMemR_W[execute_warp];
                                v_Usign_mem <= Usign[execute_warp];
                            end
                        end else begin
                            // alu/branch instructions release resources and go to writeback
                            warp_state[execute_warp] <= WARP_WRITEBACK;
                        end
                        // free execute resources immediately after execute stage
                        execute_resources_busy <= 0;
                    end
                    default: begin
                        // warp left execution stage, free resources if still held
                        if (warp_state[execute_warp] != WARP_DECODE && warp_state[execute_warp] != WARP_EXECUTE) begin
                            execute_resources_busy <= 0;
                        end
                    end
                endcase
            end
            
            /* memory stage - only for warp that owns memory resources */
            if (memory_warp_valid) begin
                case (warp_state[memory_warp])
                    WARP_MEMORY: begin // memory access for loads/stores
                        if (lsu_done) begin
                            warp_state[memory_warp] <= WARP_WRITEBACK;
                            memory_resources_busy <= 0;  // free resources when memory completes
                        end
                    end
                    default: begin
                        // warp left memory stage, free resources if still held
                        if (warp_state[memory_warp] != WARP_MEMORY) begin
                            memory_resources_busy <= 0;
                        end
                    end
                endcase
            end
            
            /* writeback happens independently for each warp */
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                if (w < num_warps && warp_state[w] == WARP_WRITEBACK) begin
                    $display("Warp %d at block %d finished executing instr x%h at addr x%h", w, core_block_id, fetched_instr[w], pc[w]);
                    pc[w] <= next_pc[w];
                    if (Finish[w]) begin
                        warp_state[w] <= WARP_DONE;
                        $display("Warp %d at block %d done", w, core_block_id);
                    end else begin
                        warp_state[w] <= WARP_FETCH;
                    end
                end
            end
        end
    end   
endmodule
