`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Dispatcher Unit Testbench
// Verifies core selection, nth_free_core bit-masking, multi-block dispatches,
// and multi-wave block retirement across clock cycles.
//////////////////////////////////////////////////////////////////////////////////

`include "../Src/common.sv"
import common_pkg::*;
import tb_common_pkg::*;

module tb_dispatcher;
    localparam int NUM_CORES = 4;

    logic clk;
    logic reset;
    logic start;
    kernel_config_t kernel_config;
    logic [NUM_CORES-1:0] core_done;
    logic [NUM_CORES-1:0] cores_in_use;
    logic [NUM_CORES-1:0] core_start;
    data_t core_block_id [NUM_CORES];
    logic finished;

    dispatcher #(
        .NUM_CORES(NUM_CORES)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .kernel_config(kernel_config),
        .core_done(core_done),
        .cores_in_use(cores_in_use),
        .core_start(core_start),
        .core_block_id(core_block_id),
        .finished(finished)
    );

    initial tb_common_pkg::generate_clock(clk, 10);

    initial begin
        tb_common_pkg::watchdog("tb_dispatcher", 50000);
    end

    // -------------------------------------------------------------------------
    // Test Task 1: Single Block Dispatch
    // -------------------------------------------------------------------------
    task test_single_block_dispatch();
        $display("\n--- Testing Single Block Dispatch ---");
        apply_reset(clk, reset);
        core_done = '0;
        kernel_config.num_blocks = 1;

        start = 1;
        @(posedge clk);
        start = 0;
        @(posedge clk);
        #1;

        check_true("Dispatcher", "SingleBlock_cores_in_use_bit0", cores_in_use == 4'b0001);
        check_true("Dispatcher", "SingleBlock_core_block_id_0", core_block_id[0] == 0);

        // Core 0 signals done
        core_done[0] = 1;
        @(posedge clk);
        core_done[0] = 0;
        #1;
        check_true("Dispatcher", "SingleBlock_finished_high", finished == 1);
        check_true("Dispatcher", "SingleBlock_cores_in_use_cleared", cores_in_use == 4'b0000);
    endtask

    // -------------------------------------------------------------------------
    // Test Task 2: Parallel 4-Block Dispatch Across 4 Free Cores
    // -------------------------------------------------------------------------
    task test_parallel_dispatch();
        $display("\n--- Testing Parallel 4-Block Dispatch ---");
        apply_reset(clk, reset);
        core_done = '0;
        kernel_config.num_blocks = 4;

        start = 1;
        @(posedge clk);
        start = 0;
        @(posedge clk);
        #1;

        check_true("Dispatcher", "Parallel_all_cores_in_use", cores_in_use == 4'b1111);
        check_true("Dispatcher", "Parallel_core0_block0", core_block_id[0] == 0);
        check_true("Dispatcher", "Parallel_core1_block1", core_block_id[1] == 1);
        check_true("Dispatcher", "Parallel_core2_block2", core_block_id[2] == 2);
        check_true("Dispatcher", "Parallel_core3_block3", core_block_id[3] == 3);

        // All 4 cores finish together
        core_done = 4'b1111;
        @(posedge clk);
        core_done = '0;
        #1;
        check_true("Dispatcher", "Parallel_finished_high", finished == 1);
        check_true("Dispatcher", "Parallel_cores_cleared", cores_in_use == 4'b0000);
    endtask

    // -------------------------------------------------------------------------
    // Test Task 3: Multi-Wave Block Dispatch (10 blocks over 4 cores)
    // -------------------------------------------------------------------------
    task test_multi_wave_dispatch();
        $display("\n--- Testing Multi-Wave Dispatch (10 blocks) ---");
        apply_reset(clk, reset);
        core_done = '0;
        kernel_config.num_blocks = 10;

        // Pulse start for 1 cycle
        start = 1;
        @(posedge clk);
        start = 0;
        #1;

        // Wave 1: blocks 0..3 on cores 0..3
        check_true("Dispatcher", "Wave1_all_cores_busy", cores_in_use == 4'b1111);

        // Cores 0 and 1 finish wave 1
        core_done[0] = 1; core_done[1] = 1;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;
        // Cores 0 and 1 should now be assigned blocks 4 and 5
        check_true("Dispatcher", "Wave2_core0_block4", core_block_id[0] == 4);
        check_true("Dispatcher", "Wave2_core1_block5", core_block_id[1] == 5);
        check_true("Dispatcher", "Wave2_all_cores_still_busy", cores_in_use == 4'b1111);

        // Cores 2 and 3 finish wave 1
        core_done[2] = 1; core_done[3] = 1;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;
        // Cores 2 and 3 get blocks 6 and 7
        check_true("Dispatcher", "Wave3_core2_block6", core_block_id[2] == 6);
        check_true("Dispatcher", "Wave3_core3_block7", core_block_id[3] == 7);

        // Cores 0 and 1 finish wave 2
        core_done[0] = 1; core_done[1] = 1;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;
        // Cores 0 and 1 get blocks 8 and 9 (last 2 blocks)
        check_true("Dispatcher", "Wave4_core0_block8", core_block_id[0] == 8);
        check_true("Dispatcher", "Wave4_core1_block9", core_block_id[1] == 9);

        // Remaining cores finish
        core_done = 4'b1111;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;
        check_true("Dispatcher", "MultiWave_finished_high", finished == 1);
        check_true("Dispatcher", "MultiWave_all_cores_cleared", cores_in_use == 4'b0000);
    endtask

    // -------------------------------------------------------------------------
    // Test Task 4: Out-Of-Order Core Completion
    // -------------------------------------------------------------------------
    task test_out_of_order_completion();
        $display("\n--- Testing Out-Of-Order Core Completion ---");
        apply_reset(clk, reset);
        core_done = '0;
        kernel_config.num_blocks = 5;

        start = 1;
        @(posedge clk);
        start = 0;
        #1;

        // 4 blocks dispatched (0..3 on cores 0..3)
        check_true("Dispatcher", "OOO_initial_busy", cores_in_use == 4'b1111);

        // Core 2 finishes first out-of-order!
        core_done[2] = 1;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;

        // Core 2 should now receive block 4 (the 5th and final block)
        check_true("Dispatcher", "OOO_core2_gets_block4", core_block_id[2] == 4);
        check_true("Dispatcher", "OOO_core2_reallocated", cores_in_use[2] == 1);

        // All remaining cores finish
        core_done = 4'b1111;
        @(posedge clk);
        core_done = '0;
        @(posedge clk);
        #1;
        check_true("Dispatcher", "OOO_finished", finished == 1);
    endtask

    // -------------------------------------------------------------------------
    // Main Initial Block
    // -------------------------------------------------------------------------
    initial begin
        tb_common_pkg::reset_counters();

        test_single_block_dispatch();
        test_parallel_dispatch();
        test_multi_wave_dispatch();
        test_out_of_order_completion();

        tb_common_pkg::report_summary();
        $finish;
    end
endmodule
