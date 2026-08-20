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
    input logic [WARPS_PER_CORE-1:0] instr_mem_ready,
    input logic [WARPS_PER_CORE-1:0] instr_mem_resp_valid,
    output logic [WARPS_PER_CORE-1:0] instr_mem_resp_ready,
    input instr_t instr_mem_resp_data [WARPS_PER_CORE],
    // data mem - one per thread - extra lsu for warp scalar regs
    output logic [THREADS_PER_WARP:0] data_mem_valid,
    output data_mem_addr_t data_mem_addr [THREADS_PER_WARP+1],
    output data_t data_mem_data [THREADS_PER_WARP+1],
    output logic [(DATA_WIDTH/8)-1:0] data_mem_we [THREADS_PER_WARP+1],
    input logic [THREADS_PER_WARP:0] data_mem_resp_valid,
    output logic [THREADS_PER_WARP:0] data_mem_resp_ready,
    input data_t data_mem_resp_data [THREADS_PER_WARP+1],
    // multi-round coalescer handshake, vector path (threads) and scalar path
    // (the +1 lane) are separate coalescer instances downstream in gpu.sv,
    // each with its own independent round tracking, so each needs its own
    // issue/response tag connection to the shared per-core scoreboard
    output logic [REQ_TAG_WIDTH-1:0] data_mem_issue_round_tag_vec,
    input logic data_mem_round_start_vec,
    input logic [REQ_TAG_WIDTH-1:0] data_mem_resp_round_tag_vec,
    output logic [REQ_TAG_WIDTH-1:0] data_mem_issue_round_tag_scl,
    input logic data_mem_round_start_scl,
    input logic [REQ_TAG_WIDTH-1:0] data_mem_resp_round_tag_scl
    );

    initial begin
        if (THREADS_PER_WARP != DATA_WIDTH) begin
            $fatal(1, "Architecture constraint violated: THREADS_PER_WARP (%0d) must equal DATA_WIDTH (%0d)", 
                THREADS_PER_WARP, DATA_WIDTH);
        end
    end
    
    data_t num_warps; assign num_warps = kernel_config.num_warps_per_block;
    
    // warp signals    
    warp_state_t warp_state [WARPS_PER_CORE];
    stall_reason_t stall_reason [WARPS_PER_CORE]; // per-warp parking reason
    
    // resource allocation - separate execute (ALU) and memory (LSU) resources
    logic [$clog2(WARPS_PER_CORE)-1:0] execute_warp;  // which warp owns ALU resources
    logic execute_resources_busy;
    logic [$clog2(WARPS_PER_CORE)-1:0] memory_warp;   // which warp owns LSU resources
    logic memory_resources_busy;
    
    // declared here (ahead of the rest of the per-warp decode/control signal
    // block further below) since memory_is_scalar/memory_warp_execution_mask
    // reference them immediately below - xvlog rejects the forward reference
    // for unpacked-array signals that decoder/scalar_regs otherwise also drive
    logic [1:0] Scalar [WARPS_PER_CORE];
    logic [THREADS_PER_WARP-1:0] warp_execution_mask [WARPS_PER_CORE];
    
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
    
    // scoreboard entry_available, declared here so memory_thread_active below
    // can reference it - driven by the scoreboard instance further down,
    // where the rest of the sb_* signals are declared and the instance lives
    logic sb_entry_available;
    
    // per-thread memory active signals (for gating LSU operations)
    // folds in scoreboard backpressure: a thread's lsu only ever presents a
    // request while a scoreboard entry actually exists to catch the response,
    // same fold pattern as memory_is_vector - one comparison computed once
    // here, broadcast to all THREADS_PER_WARP lanes
    logic memory_thread_active [THREADS_PER_WARP];
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            memory_thread_active[t] = memory_is_vector && memory_warp_execution_mask[t] && sb_entry_available;
        end
    end
    
    // per warp module signals
    instr_mem_addr_t pc [WARPS_PER_CORE], next_pc [WARPS_PER_CORE];
    
    logic fetcher_done [WARPS_PER_CORE];
    instr_t fetched_instr [WARPS_PER_CORE];
    
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
    data_t s_rs1_per_warp [WARPS_PER_CORE], s_rs2_per_warp [WARPS_PER_CORE];
    data_t s_rs1, s_rs2, s_alu_out, v_to_s_value;
    logic s_pc_jump;
    
    // mux execute warp's scalar register outputs
    assign s_rs1 = s_rs1_per_warp[execute_warp];
    assign s_rs2 = s_rs2_per_warp[execute_warp];
    
    // registered scalar register values for memory stage (to keep stable when execute resources are freed).
    // per-warp arrays: memory_resources_busy is held for a warp's entire
    // round trip while execute_resources_busy is freed after every
    // instruction, so other warps keep running ALU/DMemEN transitions
    // through the execute stage while an earlier warp is still parked
    // waiting on memory - a single shared register here would let a later
    // warp's DMemEN transition clobber an earlier, still-outstanding warp's
    // latched address/data before the coalescer/scoreboard ever captures it
    data_t s_rs1_mem [WARPS_PER_CORE], s_rs2_mem [WARPS_PER_CORE];
    data_t s_imm_mem [WARPS_PER_CORE];
    logic [1:0] s_DataSize_mem [WARPS_PER_CORE];
    logic s_DMemR_W_mem [WARPS_PER_CORE];
    logic s_Usign_mem [WARPS_PER_CORE];
    // registered vector counterparts, declared here (rather than down by
    // rs1_mem/rs2_mem) so they exist before the scoreboard port connections
    // below reference them - xvlog implicitly declares on first use otherwise,
    // which then collides with the later explicit declaration
    logic [1:0] v_DataSize_mem [WARPS_PER_CORE];
    logic v_DMemR_W_mem [WARPS_PER_CORE];
    logic v_Usign_mem [WARPS_PER_CORE];
    
    // scoreboard signals
    logic sb_issue_valid;
    logic [$clog2(WARPS_PER_CORE)-1:0] sb_issue_warp_id;
    logic [4:0] sb_issue_rd_addr;
    logic [THREADS_PER_WARP-1:0] sb_issue_thread_mask;
    logic sb_issue_is_scalar;
    logic [REQ_TAG_WIDTH-1:0] sb_alloc_tag;
    logic sb_issue_accept;
    logic [THREADS_PER_WARP-1:0] sb_resp_thread_valid;
    logic [REQ_TAG_WIDTH-1:0] sb_resp_tag;
    data_t sb_resp_data [THREADS_PER_WARP];
    logic sb_wb_valid;
    logic [$clog2(WARPS_PER_CORE)-1:0] sb_wb_warp_id;
    logic [4:0] sb_wb_rd_addr;
    logic [THREADS_PER_WARP-1:0] sb_wb_thread_mask;
    logic sb_wb_is_scalar;
    data_t sb_wb_data [THREADS_PER_WARP];
    logic sb_tag_error;

    // per-thread byte offset (addr[1:0]) at issue, needed by the scoreboard to
    // format halfword/byte loads once the (now fire-and-forget) lsu is gone by
    // the time the response arrives. scalar path reuses lane 0 of this array.
    // declared here, driven further below once rs1_mem/v_imm_mem exist -
    // Verilog module-level signals are visible everywhere in the module
    // regardless of declaration order, this split just keeps the driving
    // logic next to the signals it reads
    logic [1:0] sb_issue_byte_off [THREADS_PER_WARP];

    memory_scoreboard #(
        .SCOREBOARD_DEPTH(SCOREBOARD_DEPTH),
        .MSHR_COUNT(MSHR_COUNT),
        .REQ_TAG_WIDTH(REQ_TAG_WIDTH),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .THREADS_PER_WARP(THREADS_PER_WARP)
    ) scoreboard_inst (
        .clk(clk), .reset(reset),
        .issue_valid(sb_issue_valid),
        .issue_warp_id(sb_issue_warp_id),
        .issue_rd_addr(sb_issue_rd_addr),
        .issue_thread_mask(sb_issue_thread_mask),
        .issue_is_scalar(sb_issue_is_scalar),
        .issue_data_size(sb_issue_is_scalar ? s_DataSize_mem[memory_warp] : v_DataSize_mem[memory_warp]),
        .issue_usign(sb_issue_is_scalar ? s_Usign_mem[memory_warp] : v_Usign_mem[memory_warp]),
        .issue_byte_off(sb_issue_byte_off),
        .entry_available(sb_entry_available),
        .alloc_tag(sb_alloc_tag),
        .issue_accept(sb_issue_accept),
        .resp_thread_valid(sb_resp_thread_valid),
        .resp_tag(sb_resp_tag),
        .resp_data(sb_resp_data),
        .wb_valid(sb_wb_valid),
        .wb_warp_id(sb_wb_warp_id),
        .wb_rd_addr(sb_wb_rd_addr),
        .wb_thread_mask(sb_wb_thread_mask),
        .wb_is_scalar(sb_wb_is_scalar),
        .wb_data(sb_wb_data),
        .tag_error(sb_tag_error)
    );

    // ---- scoreboard issue side ----
    // present the memory-granted warp's op the moment it enters the memory
    // stage (not after lsu_done - there is no lsu_done anymore, the lsus are
    // fire-and-forget). issue_accept is what actually gates the request (see
    // memory_thread_active above), so presenting early just means issue_valid
    // sits high until entry_available allows the handshake through.
    assign sb_issue_valid = memory_warp_valid;
    assign sb_issue_warp_id = memory_warp;
    assign sb_issue_rd_addr = RDAddr[memory_warp];
    assign sb_issue_is_scalar = (Scalar[memory_warp] == 1);
    assign sb_issue_thread_mask = sb_issue_is_scalar ? {{THREADS_PER_WARP-1{1'b0}}, 1'b1} : warp_execution_mask[memory_warp];

    // ---- coalescer round-tag handshake ----
    // vector and scalar are separate coalescer instances (gpu.sv), each with
    // independent round tracking, so each gets its own issue/response tag
    // wired to this shared scoreboard. alloc_tag is presented to both; only
    // the one actually issuing this cycle (memory_thread_active true for its
    // lane(s)) will see its coalescer capture a round and pulse round_start.
    assign data_mem_issue_round_tag_vec = sb_alloc_tag;
    assign data_mem_issue_round_tag_scl = sb_alloc_tag;

    // ---- scoreboard response side ----
    // vector and scalar coalescers can each deliver on the same cycle; the
    // scoreboard response port only accepts one batch per cycle, so vector
    // is given priority and the scalar delivery is held (via lsu_resp_ready,
    // wired in gpu.sv) whenever vector has a response this cycle. holding
    // costs a cycle of latency on the rarer path, not data loss - the
    // coalescer already holds a presented-but-unaccepted response stable.
    logic sb_resp_from_vec;
    assign sb_resp_from_vec = |data_mem_resp_valid[THREADS_PER_WARP-1:0];
    always_comb begin
        if (sb_resp_from_vec) begin
            sb_resp_thread_valid = data_mem_resp_valid[THREADS_PER_WARP-1:0];
        end else begin
            sb_resp_thread_valid = '0;
            sb_resp_thread_valid[0] = data_mem_resp_valid[THREADS_PER_WARP]; // scalar's single lane
        end
    end
    assign sb_resp_tag = sb_resp_from_vec ? data_mem_resp_round_tag_vec : data_mem_resp_round_tag_scl;
    always_comb begin
        for (int t = 0; t < THREADS_PER_WARP; t++)
            sb_resp_data[t] = sb_resp_from_vec ? data_mem_resp_data[t] : data_mem_resp_data[THREADS_PER_WARP];
    end
    // scalar coalescer only ever delivers on its single lane (index 0 of its
    // own port), so gate its acceptance off when vector is using the bus
    assign data_mem_resp_ready[THREADS_PER_WARP-1:0] = {THREADS_PER_WARP{1'b1}};
    assign data_mem_resp_ready[THREADS_PER_WARP] = !sb_resp_from_vec;
        
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
    
    // registered vector register values for memory stage (to keep stable when
    // execute resources are freed) - per-warp, see comment at s_rs1_mem above
    data_t rs1_mem [WARPS_PER_CORE][THREADS_PER_WARP], rs2_mem [WARPS_PER_CORE][THREADS_PER_WARP];
    data_t v_imm_mem [WARPS_PER_CORE];

    // drives sb_issue_byte_off (declared above, near the scoreboard instance)
    data_t s_addr_mem; // scalar addr = rs1 + imm, recomputed here since lsu.sv no longer exposes it
    data_t v_addr_mem [THREADS_PER_WARP];
    always_comb begin
        s_addr_mem = s_rs1_mem[memory_warp] + s_imm_mem[memory_warp];
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            v_addr_mem[t] = rs1_mem[memory_warp][t] + v_imm_mem[memory_warp];
            sb_issue_byte_off[t] = memory_is_scalar ? s_addr_mem[1:0] : v_addr_mem[t][1:0];
        end
    end

    data_t alu_out [THREADS_PER_WARP];
    data_t s_alu_out_reg [WARPS_PER_CORE];
    data_t alu_out_reg [WARPS_PER_CORE][THREADS_PER_WARP];
    // branches/jumps use scalar control flow (all threads share same PC)
    // divergence handled via execution masks (predication), not per-thread PCs
    logic pc_jump [THREADS_PER_WARP]; 
    
    // registered copy of the scoreboard's writeback payload. sb_wb_data/
    // sb_wb_valid are combinational (see memory_scoreboard.sv) and only true
    // for the one cycle a matching response arrives - warp_state only reads
    // WARP_WRITEBACK the cycle *after* that (state transitions register on
    // the same edge sb_wb_valid fires), so the payload has to be captured
    // here or regs.sv/scalar_regs.sv would sample stale/garbage data.
    // per-warp registered scoreboard load data to support concurrent warp parking
    data_t lsu_out [WARPS_PER_CORE][THREADS_PER_WARP]; // registered scoreboard load data, vector
    data_t s_lsu_out [WARPS_PER_CORE]; // registered scoreboard load data, scalar (lane 0 of wb_data)
    
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

    // fire-and-forget: address/write-data datapath only, no response handling
    // (see lsu.sv). thread_active folds in memory_is_scalar and scoreboard
    // entry_available, same as the vector lanes' memory_thread_active
    logic scalar_thread_active;
    assign scalar_thread_active = memory_is_scalar && sb_entry_available;

    lsu s_lsu_inst(
        .thread_active(scalar_thread_active),
        // data + control signals - use registered values from execute stage,
        // indexed by memory_warp (the warp currently owning memory resources)
        .rs1(s_rs1_mem[memory_warp]), 
        .rs2(s_rs2_mem[memory_warp]), 
        .imm(s_imm_mem[memory_warp]),
        .DataSize(s_DataSize_mem[memory_warp]),
        .DMemR_W(s_DMemR_W_mem[memory_warp]),
        // data mem - use the last data mem array values
        .mem_valid(data_mem_valid[THREADS_PER_WARP]),
        .mem_addr(data_mem_addr[THREADS_PER_WARP]),
        .mem_data(data_mem_data[THREADS_PER_WARP]),
        .mem_we(data_mem_we[THREADS_PER_WARP])
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
                .mem_ready(instr_mem_ready[w]),
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
                .warp_enable((warp_state[w] == WARP_DECODE) || (warp_state[w] == WARP_WRITEBACK)),
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
                .alu_out(s_alu_out_reg[w]), .lsu_out(s_lsu_out[w]), .next_pc(pc[w] + 4), .v_to_s_value(v_to_s_value)
            );
        end for (w = 0; w < WARPS_PER_CORE; w++) begin : reg_file
            // next_pc is per-thread in regs.sv, broadcast the warp's pc+4
            data_t next_pc_bcast [THREADS_PER_WARP];
            always_comb begin
                for (int t = 0; t < THREADS_PER_WARP; t++) next_pc_bcast[t] = pc[w] + 4;
            end

            regs #(
                .THREADS_PER_WARP(THREADS_PER_WARP),
                .REGS_PER_THREAD(32)
            ) regs_inst(
                .clk(clk), .reset(reset),
                .warp_state(warp_state[w]),
                .warp_enable((warp_state[w] == WARP_DECODE) || (warp_state[w] == WARP_WRITEBACK)),
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
                .alu_out(alu_out_reg[w]), .lsu_out(lsu_out[w]), .next_pc(next_pc_bcast)
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
            // vector LSUs - fire-and-forget address/write-data datapath only.
            // gated by memory_thread_active (execution mask AND scoreboard
            // entry_available), so inactive threads and a full scoreboard both
            // hold off presenting a request, exactly like the old thread_active
            // gate did for the execution mask alone
            lsu lsu_inst(
                .thread_active(memory_thread_active[t]),
                // data + control signals - use registered values from execute
                // stage, indexed by memory_warp (the warp owning memory resources)
                .rs1(rs1_mem[memory_warp][t]), 
                .rs2(rs2_mem[memory_warp][t]), 
                .imm(v_imm_mem[memory_warp]),
                .DataSize(v_DataSize_mem[memory_warp]),
                .DMemR_W(v_DMemR_W_mem[memory_warp]),
                // data mem - use each thread's respective data mem array values
                .mem_valid(data_mem_valid[t]),
                .mem_addr(data_mem_addr[t]),
                .mem_data(data_mem_data[t]),
                .mem_we(data_mem_we[t])
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
    
    
    // find next warp ready to execute (needs ALU resources)
    logic [WARPS_PER_CORE-1:0] warps_ready_to_execute;
    logic [$clog2(WARPS_PER_CORE)-1:0] next_execute_warp;
    always_comb begin
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            // warp is ready if in DECODE, not stalled, and within active range
            warps_ready_to_execute[w] = (warp_state[w] == WARP_DECODE) && (stall_reason[w] == STALL_NONE) && (w < num_warps);
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
            // warp is ready for memory if in MEMORY state, not stalled
            warps_ready_for_memory[w] = (warp_state[w] == WARP_MEMORY) && (stall_reason[w] == STALL_NONE) && (w < num_warps);
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
                stall_reason[w] <= STALL_NONE;
                pc[w] <= 0;
            end
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                s_lsu_out[w] <= 0;
                for (int t = 0; t < THREADS_PER_WARP; t++) lsu_out[w][t] <= 0;
            end
        end else if (start) begin // upon reset or starting again
            $display("Executing block %0d on core %0d", core_block_id, core_id);
            execute_warp <= 0;
            execute_resources_busy <= 0;
            memory_warp <= 0;
            memory_resources_busy <= 0;
            for (int w = 0; w < WARPS_PER_CORE; w++) begin // enter fetch state
                if (w < num_warps) begin // extra warps in core don't matter
                    warp_state[w] <= WARP_FETCH;
                    stall_reason[w] <= STALL_NONE;
                    pc[w] <= kernel_config.base_instr_addr;
                end
            end
        end else begin // during execution
        
            /* fetches and decodes happen in parallel across warps */
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                if (w < num_warps) begin
                    if (warp_state[w] == WARP_FETCH && fetcher_done[w]) begin
                        warp_state[w] <= WARP_DECODE;
                    end
                end
            end
            
            /* grant execution resources to next ready warp */
            if (!execute_resources_busy && (|warps_ready_to_execute)) begin
                execute_warp <= next_execute_warp;
                execute_resources_busy <= 1;
            end
            
            /* grant memory resources to next ready warp */
            if (!memory_resources_busy && (|warps_ready_for_memory)) begin
                memory_warp <= next_memory_warp;
                memory_resources_busy <= 1;
            end
            
            /* execute stage - only for warp that owns execution resources */
            if (execute_warp_valid) begin
                case (warp_state[execute_warp]) 
                    WARP_DECODE: begin // transition to execute
                        warp_state[execute_warp] <= WARP_EXECUTE; 
                    end
                    WARP_EXECUTE: begin
                        if (fetched_instr[execute_warp] != 0) begin // DEBUG prints
                            $display("[Core %0d|Block %0d|Warp %0d] Executing PC x%0H: %s (Mask: %0b)", core_id, core_block_id, execute_warp, pc[execute_warp], common_pkg::decode_instr(fetched_instr[execute_warp]), warp_execution_mask[execute_warp]);
                        end
                        if (IsBR_J[execute_warp]) begin // branch/jump
                            // DEBUG prints
                            if (IsBR_J[execute_warp] == 2'b10) begin // JAL/JALR
                                $display("[Core %0d|Block %0d|Warp %0d]   -> Jump to PC x%0H", core_id, core_block_id, execute_warp, s_alu_out);
                            end else begin // branch
                                if (s_pc_jump)
                                    $display("[Core %0d|Block %0d|Warp %0d]   -> Branch taken, PC x%0H", core_id, core_block_id, execute_warp, s_alu_out);
                                else
                                    $display("[Core %0d|Block %0d|Warp %0d]   -> Branch not taken, PC x%0H", core_id, core_block_id, execute_warp, pc[execute_warp] + 4);
                            end
                            next_pc[execute_warp] <= (s_pc_jump) ? s_alu_out : pc[execute_warp] + 4;
                        end else begin
                            next_pc[execute_warp] <= pc[execute_warp] + 4;
                        end
                        // if load/store instruction, go to memory stage
                        if (DMemEN[execute_warp]) begin
                            warp_state[execute_warp] <= WARP_MEMORY;
                            // stall_reason stays STALL_NONE here - this warp is
                            // ready for the memory grant, not yet waiting on a
                            // response. setting WAIT_MEM would make it ineligible
                            // for warps_ready_for_memory and deadlock since
                            // nothing else can ever clear the stall. WAIT_MEM is
                            // set below, at the moment memory is actually granted
                            // register values for memory stage (to keep stable when execute resources are freed)
                            if (Scalar[execute_warp] == 1) begin
                                // scalar load/store - latched per-warp (indexed
                                // by execute_warp) since this warp may sit
                                // parked waiting for memory_resources_busy while
                                // other warps pass through execute in the meantime
                                s_rs1_mem[execute_warp] <= s_rs1;
                                s_rs2_mem[execute_warp] <= s_rs2;
                                s_imm_mem[execute_warp] <= IMM[execute_warp];
                                s_DataSize_mem[execute_warp] <= DataSize[execute_warp];
                                s_DMemR_W_mem[execute_warp] <= DMemR_W[execute_warp];
                                s_Usign_mem[execute_warp] <= Usign[execute_warp];
                                $display("[Core %0d|Block %0d|Warp %0d]   -> Scalar %s addr=0x%0h", core_id, core_block_id, execute_warp, DMemR_W[execute_warp] ? "store" : "load", s_rs1 + IMM[execute_warp]);
                            end else begin
                                // vector load/store - same per-warp latching as above
                                for (int t = 0; t < THREADS_PER_WARP; t++) begin
                                    rs1_mem[execute_warp][t] <= rs1[t];
                                    rs2_mem[execute_warp][t] <= rs2[t];
                                end
                                v_imm_mem[execute_warp] <= IMM[execute_warp];
                                v_DataSize_mem[execute_warp] <= DataSize[execute_warp];
                                v_DMemR_W_mem[execute_warp] <= DMemR_W[execute_warp];
                                v_Usign_mem[execute_warp] <= Usign[execute_warp];
                                $display("[Core %0d|Block %0d|Warp %0d]   -> Vector %s base addrs = [%0d+%0d, ...]", core_id, core_block_id, execute_warp, DMemR_W[execute_warp] ? "store" : "load", rs1[0], IMM[execute_warp]);
                            end
                        end else begin
                            s_alu_out_reg[execute_warp] <= s_alu_out;
                            for (int t = 0; t < THREADS_PER_WARP; t++)
                                alu_out_reg[execute_warp][t] <= alu_out[t];
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
            
            /* memory stage & writeback */
            if (sb_wb_valid) begin
                if (sb_wb_is_scalar) begin
                    s_lsu_out[sb_wb_warp_id] <= sb_wb_data[0];
                end else begin
                    for (int t = 0; t < THREADS_PER_WARP; t++)
                        lsu_out[sb_wb_warp_id][t] <= sb_wb_data[t];
                end
                warp_state[sb_wb_warp_id] <= WARP_WRITEBACK;
                stall_reason[sb_wb_warp_id] <= STALL_NONE;
            end
            
            // Release memory issue slot once accepted by scoreboard or if warp left WARP_MEMORY
            if (sb_issue_accept) begin
                stall_reason[memory_warp] <= STALL_WAIT_MEM;
                memory_resources_busy <= 0;
            end else if (memory_warp_valid && (warp_state[memory_warp] != WARP_MEMORY)) begin
                memory_resources_busy <= 0;
            end
            
            /* writeback happens independently for each warp */
            for (int w = 0; w < WARPS_PER_CORE; w++) begin
                if (w < num_warps && warp_state[w] == WARP_WRITEBACK) begin
                    pc[w] <= next_pc[w];
                    if (Finish[w]) begin
                        warp_state[w] <= WARP_DONE;
                        $display("[Core %0d|Block %0d|Warp %0d] Done", core_id, core_block_id, w);
                    end else begin
                        // DEBUG print writeback result (suppress if no register actually written)
                        if (LdReg[w]) begin
                            if (Scalar[w] == 2'b01) begin // scalar writeback
                                if (RDAddr[w] != 0) // don't print writes to x0 - NOPs do this
                                    $display("[Core %0d|Block %0d|Warp %0d]   -> WB x%0d = 0x%0h", core_id, core_block_id, w, RDAddr[w], DMemEN[w] ? s_lsu_out[w] : s_alu_out_reg[w]);
                            end else if (Scalar[w] == 2'b00) begin // vector writeback
                                if (RDAddr[w] > 3) begin // registers 0-3 are reserved (zero/thread_id/block_id/block_size)
                                    $write("[Core %0d|Block %0d|Warp %0d]   -> WB v%0d = [", core_id, core_block_id, w, RDAddr[w]);
                                    for (int t = 0; t < THREADS_PER_WARP; t++) begin
                                        if (warp_execution_mask[w][t])
                                            $write("t%0d:0x%0h ", t, DMemEN[w] ? lsu_out[w][t] : alu_out_reg[w][t]);
                                    end
                                    $display("]");
                                end
                            end else begin // vec-to-scalar
                                if (RDAddr[w] != 0)
                                    $display("[Core %0d|Block %0d|Warp %0d]   -> WB x%0d = 0x%0h (vec->scalar)", core_id, core_block_id, w, RDAddr[w], s_alu_out_reg[w]);
                            end
                        end
                        warp_state[w] <= WARP_FETCH;
                    end
                end
            end
        end
    end   
`ifndef SYNTHESIS
    // =========================================================================
    // assertions
    // =========================================================================

    // stall exclusion: warp with non-zero stall reason cannot be ready
    genvar i;
    generate
        for (i = 0; i < WARPS_PER_CORE; i++) begin : stall_assertions
            assert property (@(posedge clk) disable iff(!reset) 
                (stall_reason[i] != STALL_NONE) |-> !warps_ready_to_execute[i] && !warps_ready_for_memory[i]);
        end
    endgenerate

    // execute resource hold: if execute_resources_busy high, execute_warp stable next cycle
    assert property (@(posedge clk) disable iff(!reset) 
        (execute_resources_busy) |=> $stable(execute_warp));

    // response resume latency: target warp transitions out of WARP_MEMORY within 1 cycle of response
    assert property (@(posedge clk) disable iff(!reset) 
        (sb_wb_valid) |=> (warp_state[$past(sb_wb_warp_id)] == WARP_WRITEBACK));
`endif

endmodule
