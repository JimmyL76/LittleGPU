# LittleGPU

A SIMT (Single Instruction, Multiple Thread) GPU implementation in SystemVerilog, featuring multi-core architecture with warp-based execution, latency hiding, memory coalescing, and a custom C++ assembler toolchain.

**Tech Stack:**
* **Languages:** SystemVerilog, C++, PowerShell, modified RISC-V RV32I assembly
* **Tools:** Xilinx Vivado, XSim
* **Concepts:** SIMT execution, warp scheduling, latency hiding, memory coalescing, multi-channel arbitration, MSHRs

## At a Glance

| | |
| :--- | :--- |
| **Design size** | 13 SystemVerilog modules |
| **Default configuration** | 4 cores x 2 warps/core x 32 threads/warp (8 warps, 32-wide lanes per core, 128 execution units total, 256 resident threads) |
| **Memory subsystem** | 8 data + 8 instruction channels, 128-byte line transactions, 32 thread accesses coalesced into 1 |
| **Execution Model** | SIMT with SIMD pipeline, scoreboard-driven data hazard resolution, and hardware divergence handling |
| **Verification** | 12 testbenches including full-datapath `tb_gpu` with 4 benchmark kernels |
| **Toolchain** | Two-pass C++ assembler for custom SIMT ISA |

## Overview

This project implements a parameterized SIMT GPU architecture in SystemVerilog designed to explore hardware-level parallelism, memory coalescing, and latency hiding in modern GPUs. It supports parallel compute kernel execution across multiple cores using a CUDA-style hierarchy of thread blocks and 32-thread warps. The core executes a modified RISC-V RV32I SIMT instruction set with dedicated vector registers, scalar registers, and custom vector-to-scalar instructions for predication and branch divergence.

## Features

- **Multiprocessor Threading Model**: Organized execution using thread blocks and 32-thread warps across multiple cores
- **Warp Scheduler**: Cycle-by-cycle warp scheduling with warp parking to hide memory latency
- **Memory Scoreboard & MSHRs**: Per-core tracking table for non-blocking out-of-order memory response routing
- **Line-Wide Memory Coalescer**: Merges 32 thread accesses into 128-byte line transactions with multi-outstanding request support
- **Multi-Channel Memory Controller**: Multi-channel memory interface (8 data channels, 8 instruction channels) with rotating priority arbitration, response buffering, and backpressure
- **C++ Assembler Toolchain**: Translates assembly for GPU kernels

## Architecture

The overall architecture begins with an input of a task or process that can be broken down into many smaller, parallel computations. The goal of the GPU is to efficiently distribute key resources to perform similar operations on many elements of data at once, resulting in very high throughput. Some examples of GPU-friendly tasks include 3D graphics rendering, matrix operations, training neural networks, etc.

To begin, we start with threads as the fundamental units of computation. Each thread performs its part of the overall computation with its own input data and output results. Due to the parallel nature of these calculations, they can be organized into groups of threads, called warps, which run the same vector/SIMT instructions at once across each thread. 

To do these calculations, the warps need many Arithmetic Logic Units (ALUs) as well as multiple units to access key shared resources and memory, such as Load Store Units (LSUs), fetchers, decoders, and registers. These can then be organized and grouped into their own compute cores or multiprocessors. To group together warps to run on each core, one more layer called a block is added. Blocks are then assigned to cores to run in, creating a massively parallel compute organization hierarchy.

To aid with this, vector registers are used, which hold multiple data elements for a group of parallel threads. In terms of memory hierarchy, the memory controller handles requests from multiple cores to access global memory through parallel channels.

## Assembly

For this project, I created an assembly to binary assembler that translates instructions based on smol-gpu's modified RV32I ISA. 

### C++ Assembler Key Features
- `std::pair<string, vector<string>>` for mnemonic + operands
- `std::map` for instruction encoding tables
- Regular expressions for parsing memory addressing format `offset(base)` 
- Label resolution with PC-relative offset calculation

This allows for supporting GPU-specific addressing modes, scalar/vector register notations, and comprehensive error handling.

This particular block/warp model is based on CUDA-style directives `.blocks <num_blocks>` and `.warps <num_warps>`.

## Instruction Set Architecture (ISA)

LittleGPU implements a modified **RISC-V RV32I SIMT** instruction set with dedicated Vector, Scalar, Control Flow, and Vector-to-Scalar Predication extensions.

### Opcode Encoding Scheme
Instructions use standard 32-bit RISC-V encoding. Bit 6 of the 7-bit opcode designates **Vector (`0`)** vs. **Scalar (`1`)**:

| Category | Opcode (Hex) | Opcode (Binary) | Description / Instructions |
| :--- | :---: | :---: | :--- |
| **Vector R-Type** | `0x33` | `0010011` | `add`, `sub`, `sll`, `slt`, `sltu`, `xor`, `srl`, `sra`, `or`, `and` (SIMD per-lane) |
| **Vector I-Arith** | `0x13` | `0010011` | `addi`, `slli`, `slti`, `sltui`, `xori`, `srli`, `srai`, `ori`, `andi` |
| **Vector Load** | `0x03` | `0000011` | `lw`, `lh`, `lhu`, `lb`, `lbu` (Coalesced 128B memory transactions) |
| **Vector Store** | `0x23` | `0100011` | `sw`, `sh`, `sb` (Byte write-mask merging) |
| **Vector Upper Imm**| `0x37` / `0x17` | `0110111` / `0010111` | `lui`, `auipc` |
| **Scalar R-Type** | `0x73` | `1110011` | `s.add`, `s.sub`, `s.sll`, `s.slt`, `s.sltu`, `s.xor`, `s.srl`, `s.sra`, `s.or`, `s.and` |
| **Scalar I-Arith** | `0x53` | `1010011` | `s.addi`, `s.slli`, `s.slti`, `s.sltui`, `s.xori`, `s.srli`, `s.srai`, `s.ori`, `s.andi` |
| **Scalar Load** | `0x43` | `1000011` | `s.lw`, `s.lh`, `s.lhu`, `s.lb`, `s.lbu` |
| **Scalar Store** | `0x7B` | `1111011` | `s.sw`, `s.sh`, `s.sb` (Re-mapped from `0x23` to prevent branch conflicts) |
| **Scalar Branch** | `0x63` | `1100011` | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` (Warp-level control flow) |
| **Scalar Jumps** | `0x6F` / `0x67` | `1101111` / `1100111` | `jal`, `jalr` |
| **Vector-to-Scalar**| `0x7E` / `0x7D` | `1111110` / `1111101` | `sx.slt`, `sx.slti` (SIMD comparison reduction to scalar mask) |

### Vector-to-Scalar Predication (`sx.*`)
Branch divergence is handled via execution mask predication rather than per-thread program counters:
- **`sx.slt rd, rs1, rs2`** (`0x7E`): Evaluates `rs1 < rs2` across each active thread lane in parallel. The boolean outcome of lane $t$ (`alu_out[t][0]`) is written to bit $t$ of scalar register `rd` (typically `s1`, the execution mask).
- **`sx.slti rd, rs1, imm`** (`0x7D`): Compares each thread lane against immediate `imm`, writing the resulting bitmask to `rd`.



## Core/Block Dispatch Logic 
GPU dispatcher uses bit-masking for efficient matching of pending blocks to free cores, dispatching up to 4 blocks per cycle:
1. Identifies free cores using `cores_in_use` status
2. Employs `first_cleared = ~cores_in_use & (cores_in_use + 1)` for fast free core detection
3. Uses previous results for next nth_free_core 
4. Parameterized utility function to convert one-hot to binary for core indexing
5. Dynamic multi-wave block retirement and dispatch when total blocks exceed number of physical cores

## Memory Subsystem & Coalescing

The memory subsystem handles requests from core users (load store units `lsu.sv`, fetching units `fetcher.sv`), coalesces warp accesses into line-wide requests (`coalescer.sv`), tracks in-flight loads (`memory_scoreboard.sv`), arbitrates based on rotating priority across memory channels (`mem_controller.sv`), and sends memory accesses to global memory. Since the GPU's input, output, and shared data across all of its thread blocks will be in global memory, this is a key aspect to optimize to prevent bottlenecks.

### Arbitration Strategy
The memory controller uses address decode + rotating priority (or essentially a Round-Robin strategy without time constraints). This was chosen over a first come first serve (FCFS) strategy in order to be able to optimize for GPU memory access patterns.

For example, memory accesses might look like:
```
Sequential access pattern over time: 
Time T1: Channels 0,1,2,3 fetch cache lines A,B,C,D (related data) 
Time T2: Channels 0,1,2,3 fetch cache lines E,F,G,H (next related data)
Time T3: Channels 0,1,2,3 fetch cache lines I,J,K,L (next related data)

Random assignment over time:
Time T1: Channels 0,1,2,3 fetch cache lines A,B,C,D 
Time T2: Channels 2,0,3,1 fetch cache lines E,F,G,H (different mapping) 
Time T3: Channels 1,3,0,2 fetch cache lines I,J,K,L (different again)
```

With the first example, the ability to predict and optimize same row accesses, prefetch next cache lines, and have efficient pipelining are all available. Middle-bit channel interleaving (`[row | channel | byte-in-line]`) ensures consecutive 128-byte lines distribute across all 8 channels evenly.

Notice that, for block/core dispatching, FCFS + bit masking was used because compute blocks do not seem to have the same spatial relationships and optimizations that memory addresses do.

### Memory Coalescing (`coalescer.sv`)
To avoid sending 32 individual memory transactions when a warp performs a vector load or store, a line-wide coalescer merges thread accesses:
* **128-Byte Line Transactions:** Groups 32 thread requests into 128-byte memory lines.
* **Multi-Outstanding Line Issue:** Allows multiple line requests in parallel for scattered or uncoalesced memory accesses.
* **Write-Merge Conflict Resolution:** When 32 threads write to the same 128-byte line, their individual byte write-enables are combined into a single 128-byte write mask. If two threads happen to write to the exact same byte address at the same time, the lowest thread index takes priority and its data is written.

```
 31                                 10 9             7 6                         2 1     0
+-------------------------------------+---------------+---------------------------+-------+
|           Dense Row Address         | Channel Select|   Word Slot Inside Line   |  Byte |
|              bits [31:10]           |   bits [9:7]  |        bits [6:2]         | [1:0] |
+-------------------------------------+---------------+---------------------------+-------+
|<---------- Per-Channel Row -------->|<- 8 Channels->|<- 32 Words in 128B Line ->|<-4B ->|
|<---------------------- line_id = bits [31:7] ------>|
```

### Handshaking & Response Buffering
The memory controller uses valid/ready handshaking with dedicated per-user response buffering (`RESP_BUF_DEPTH`) and request tagging. When downstream units or channels are busy, backpressure prevents dropped requests and enables non-blocking asynchronous memory issue.

## Core Design & Latency Hiding

When a core runs a warp, it needs a fetcher, decoder, scalar LSU, scalar ALU, a set of vector registers, and a set of scalar registers. Inside each core, there are shared vector ALUs and LSUs sized to execute one warp at a time per core.

### Warp Scheduler & Warp Parking
All warps proceed through fetch and decode concurrently. To hide long memory latencies:
1. When a warp executes a memory load, it transitions to `STALL_WAIT_MEM` upon issue acceptance and **parks** (yields execution resources immediately).
2. The core scheduler instantly selects another ready warp to execute ALU operations, branches, or fetches on subsequent clock cycles.
3. A per-core **Memory Scoreboard** (MSHR pool) tracks the in-flight load using request tags, matches responses as they return out-of-order, formats sub-word values (bytes/halfwords with sign or zero extension), and signals writeback to wake the parked warp.

### Vector SIMT Registers
To perform similar calculations in a highly parallel manner across many pieces of data, each warp has one vector register file, with each vector register consisting of 32 essentially normal scalar registers. For example, `x4` - `x31` are general purpose vector registers, so loading `x4` from the register file would mean loading 32 data values, each being 32-bit themselves. By setting each of these 32 data values to be different, the same calculation can be performed on different pieces of data in parallel. 

Registers `x0` - `x3` are read-only and have special purposes:
|**Register**|**Function**   |
|------------|---------------|
|`x0`        |zero           |
|`x1`        |thread id      |
|`x2`        |block id       |
|`x3`        |block size     |
|`x4`-`x31`  |general purpose|

Notice that when thread ids are set to be values 0 through 31, we can load from 32 different memory addresses. Here is an example program from [smol-gpu](https://github.com/Grubre/smol-gpu) for better visualization:
```python
.blocks 32
.warps 12

# This is a comment
jalr x0, label              # jump to label
label: addi x5, x1, 1       # x5 := thread_id + 1
sx.slti s1, x5, 5           # s1[thread_id] := x5 < 5 (mask)
sw x5, 0(x1)                # mem[thread_id] := x5 (only non-masked threads execute this)
halt                        # Stop the execution
```

### Scalar registers
There are also similarly 32 scalar registers:
|**Register**|**Function**   |
|------------|---------------|
|`s0`        |zero           |
|`s1`        |execution mask |
|`s2`-`s31`  |general purpose|

Notice that the example code used the special vector-to-scalar instruction ```sx.slti``` to turn off calculations for a specific thread. This masking is one way to solve the branching issue inside SIMT architectures and ensure the threads properly converge back to the same instruction.

## Testing & Verification

The design is verified with a comprehensive suite of 12 self-checking SystemVerilog testbenches in Vivado XSim. A PowerShell test runner (`run_sim.ps1`) automates simulation, supporting sequential runs, parallel multi-process execution, or running individual testbenches.

### Simulation Commands
```powershell
# Run all tests sequentially
.\run_sim.ps1

# Run all tests concurrently in parallel
.\run_sim.ps1 -Parallel

# Run a specific testbench (e.g. top-level GPU)
.\run_sim.ps1 tb_gpu

# List available testbenches
.\run_sim.ps1 -List
```

### Test Suite Status

| Testbench | Focus Area | Status |
| :--- | :--- | :---: |
| `tb_alu` | Vector & scalar arithmetic, shifts, logic, branch comparisons | **PASS** |
| `tb_decoder` | RV32I & SIMT instruction decoding and field extraction | **PASS** |
| `tb_fetcher` | Multi-warp instruction fetch handshaking and alignment | **PASS** |
| `tb_lsu` | Byte, halfword, word load/store operations and write-enables | **PASS** |
| `tb_regs` | Vector register file, thread-masked writes, bypass logic | **PASS** |
| `tb_scalar_regs` | Scalar register file, execution mask (`s1`), V-to-S moves | **PASS** |
| `tb_coalescer` | 128B line grouping, byte write-merging, multi-round tags | **PASS** |
| `tb_mem_controller` | Channel arbitration, response buffers, stall backpressure | **PASS** |
| `tb_memory_scoreboard`| MSHR allocation, out-of-order response matching, formatting | **PASS** |
| `tb_dispatcher` | Multi-wave block dispatch, free core detection, retirement | **PASS** |
| `tb_core` | Warp scheduler, latency hiding, scoreboard integration | **PASS** |
| `tb_gpu` | **Top-level integration & benchmarks (3,057 checks)** | **PASS** |

### Benchmark Kernels (`tb_gpu.sv`)
* **Vector Addition:** `C[i] = A[i] + B[i]` (N=64 across 2 blocks)
* **SAXPY:** `Y[i] = 3 * X[i] + Y[i]` (N=64 scale and accumulate)
* **Vector Sum Reduction:** Parallel array loading and memory writeback (N=32)
* **GEMM Matrix Multiplication:** 4x4 Matrix Multiply (`C = A * B`)
* **Stress & Control Flow:** Multi-block dispatch (10 blocks across 4 cores), multi-warp execution (256 threads), branch/loop counters, and constrained-random stress tests.

## Synthesis & FPGA Resource Scaling

Out-of-context synthesis across a sweep of core/warp/SIMD-width configurations (9 so far) on Xilinx Vivado, Artix-7 `-1` speed grade, 100 MHz target (10 ns period). None close timing at 100 MHz, so $F_{\text{max}}$ below is derived from Worst Negative Slack (WNS) as $F_{\text{max}} = \frac{1}{10\text{ns} - \text{WNS}}$ as an estimate.

**Lanes** = `THREADS_PER_WARP`, the physical SIMD width of one core. **Resident threads** = `cores x warps/core x threads/warp`, the peak thread count in flight across the design. Both warps and cores raise resident threads without widening a lane: each core gets its own ALU/LSU/coalescer (`gpu.sv` instantiates one `coalescer` per core), so warps on that core time-multiplex onto already existing hardware, and a second core just repeats that same fixed-width hardware rather than widening it anywhere.

| Config | Cores | Warps/Core | Lanes | Resident Threads | LUTs | FF | WNS | Est. $F_{\text{max}}$ |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`C1W1_T4`** | 1 | 1 | 4 | 4 | 11.9k | 8.7k | -1.699 ns | 85.5 MHz |
| **`C1W2_T4`** | 1 | 2 | 4 | 8 | 16.4k | 14.7k | -1.640 ns | 85.9 MHz |
| **`C1W4_T4`** | 1 | 4 | 4 | 16 | 25.2k | 26.4k | -1.640 ns | 85.9 MHz |
| **`C1W1_T8`** | 1 | 1 | 8 | 8 | 25.8k | 15.7k | -13.147 ns | 43.2 MHz |
| **`C1W1_T16`**| 1 | 1 | 16 | 16 | 56.7k | 29.7k | -42.528 ns | 19.0 MHz |
| **`C2W2_T4`** | 2 | 2 | 4 | 16 | 32.7k | 28.3k | -4.781 ns | 67.6 MHz |
| **`C2W2_T8`** | 2 | 2 | 8 | 32 | 67.3k | 51.2k | -13.147 ns | 43.2 MHz |
| **`C4W2_T4`** | 4 | 2 | 4 | 32 | 66.1k | 55.7k | -8.068 ns | 55.3 MHz |
| **`C4W2_T32`**| 4 | 2 | 32 | 256 | 833.1k | 381.2k | -110.740 ns | 8.3 MHz |

The first 8 configurations physically fit on an Artix-7 200T (`xc7a200tfbg484-1`, 134,600 LUT / 269,200 FF), with `C1W1_T4` (52.1% LUT / 21.0% FF) and `C1W2_T4` (72.3% LUT / 35.2% FF) fitting the 35T on the Basys 3. The full 128-lane / 256-thread flagship design (`C4W2_T32`) scales to 833.1k LUTs / 381.2k FFs, only fitting on high-end datacenter FPGAs (e.g. AMD Virtex UltraScale+ `VU9P`).

### Takeaways

**Lane width dominates area and timing.** Holding `C=1, W=1` and widening lanes 4 -> 8 -> 16 roughly doubles LUTs at each step and drops $F_{\text{max}}$ from 85.5 to 43.2 to 19.0 MHz. `coalescer.sv` isolates a priority leader, muxes its address, compares it against every other lane's line ID, and inserts matching bytes into a shared write mask across all `T` lanes at once. `regs.sv` reads `registers[t][RS1Addr]` for `rs1`/`rs2` independently per lane, so both blocks add a `T`-wide mux/comparator tree as lanes grow. For `C1W1_T16` this puts 60 logic levels on the critical path (52.5 ns of delay), expanding to 164 logic levels (120.8 ns of delay, ~91.8k LUTs per coalescer) in the 32-lane `C4W2_T32` build.


**Scaling warps is timing-neutral and scaling cores adds only minor delays.** Holding `C=1, T=4` and going 1 -> 2 -> 4 warps (4 -> 16 resident threads) moves $F_{\text{max}}$ by under 1% (85.5 to 85.9 MHz, run-to-run noise) because warps time-multiplex onto the one fixed-width coalescer/ALU/LSU their core already has. Cores don't share that hardware (`C1W2_T4` -> `C2W2_T4` doubles the coalescer/ALU/LSU count), but they do still share the memory controller's arbiter: `gpu.sv` sets `NUM_DATA_USERS = NUM_CORES * 2`, so each added core deepens that one shared arbitration tree by a couple of logic levels. That shows up as `C1W2_T4`'s critical path going from 15 levels/11.6 ns to `C2W2_T4`'s 17 levels/14.5 ns, which is far cheaper than widening a lane.

**Replicating cores beats widening lanes at equal resident thread count on FPGAs.** `C2W2_T4` and `C1W1_T16` both reach 16 resident threads, but `C2W2_T4` hits 67.6 MHz and uses 42% fewer LUTs (32.7k vs. 56.7k) against `C1W1_T16`'s 19.0 MHz (a 3.5x higher $F_{\text{max}}$). This is because core replication replaces a sprawling 16-lane crossbar with two localized 4-lane coalescers, only paying the small per-core arbiter cost instead of growing the `T`-wide coalescer/regs muxing. The same holds at 32 resident threads: `C4W2_T4` (4 lanes x 4 cores) reaches 55.3 MHz and 66.1k LUTs versus `C2W2_T8`'s (8 lanes x 2 cores) 43.2 MHz and 67.3k LUTs. The trade-off is that wider SIMD amortizes one fetch/decode instance across more lanes, but pays for it with a wider coalescer/regs mux tree and a larger coalesced line per lane group. Multi-core scaling duplicates fetch/decode/coalescer per core instead of widening them, keeping each core's critical path short with the minor arbiter path cost.

**For area-constrained designs, scaling warps per core is the cheapest way to add resident threads.** `C1W4_T4` holds 16 resident threads in 25.2k LUTs / 26.4k FF, 23% fewer LUTs than 2 cores (`C2W2_T4`, 32.7k) and 56% fewer than 16-wide SIMD (`C1W1_T16`, 56.7k), delivering fewer LUTs and FFs than either alternative at the same resident-thread count. Warps duplicate fetch/decode and scheduling logic per warp while sharing one set of ALUs/LSUs per core, which is cheaper than replicating a whole core or widening a lane. The tradeoff is that extra warps buy latency-hiding occupancy for memory-bound kernels, not added per-cycle throughput the way a second core does.

## Challenges & Lessons Learned

### Parallel Computations
Since many different computations are all going on within each clock cycle, I struggled with ensuring that multi-block/memory logic had no combinational feedback and was optimized for parallel non-sequential logic. Specifically, arbitration, bit-masking, and dynamic multi-wave block dispatch proved to be difficult components of logic to design.

### Memory Subsystem & Latency Hiding
Since many memory accesses happen at a time across the entire GPU, all users accessing memory should be as optimized as possible to not bottleneck the rest of the system. Earlier on, I struggled with figuring out pipelined accesses, coalescing 32 thread accesses, handling multiple warps across different pipeline stages, and buffering responses without race conditions. Implementing the 128-byte parallel coalescer and per-core memory scoreboard solved this by letting warps park upon issue and matching returning responses out-of-order with request tags. It showed me firsthand that parallelizing operations isn't just a free solution for speeding up everything, and why memory latency hiding is a huge challenge in GPU architecture.

### Handshake Race Condition
The original `memory_model` in `tb_common.sv` is always ready and answers in one cycle, which means a request is accepted the moment it is presented. But since real memory stalls, I added a second `memory_model_stall` model with randomized latency and request backpressure to test the memory controller's per-channel logic. In the arbiter's grant branch, the controller latches `next_pending[c] = mem_ready[c]` in the cycle it selects a channel - one cycle *before* it raises `mem_valid[c]`. If memory deasserts `ready` in between, the controller records a request as delivered that the memory never accepted, so no response is received and the channel hangs forever. 

The fix was to detect the real handshake, such that the grant branch now leaves `pending` deasserted, and a separate "presented, not yet taken" branch watches for `valid && ready` while `mem_valid` is actually high. The lesson I learned here is that any testbench should extensively test the backpressure path, since this bug existed the whole time but the passing test suite said nothing about it until memory was allowed to stall. 

### SIMT Registers & Control Flow
What makes GPU logic especially complex is handling all the different nuances of modern programs that run on GPUs. These processes have non-linear execution paths, dependent data access patterns, and control flow divergence. In LittleGPU's case, jumps and branches act as scalar operations, despite the fact that certain pieces of data can diverge differently, thus creating the need for special vector-to-scalar instructions (`sx.slt`, `sx.slti`). It was important to implement the logic for these instructions while keeping inputs/outputs to scalar and vector registers consistent and separate.

### Hardware Synthesis & Parameterization
Moving from simulation to synthesis exposed edge cases sim never hit: a `[-1:0]` part-select in the arbiter's single-user case, and a mask/data-width coupling that blocked warps below 32 threads. Every simulated config had happened to avoid both. Fixed and reflected in the sweep above.

## Next Steps

Currently working on...
- [x] Multi-channel response-buffered memory controller
- [x] Parallel 128-byte memory coalescer
- [x] Fine-grained warp latency-hiding scheduler and memory scoreboard
- [x] Automated test suite & top-level GPU benchmark verification (`tb_gpu`)
- [x] Out-of-context synthesis + sweep over core/warp/thread configurations
    - [x] Fix arbiter indexing syntax error on single-user
    - [x] Separate mask width from data width for warps < 32 threads

Next in line...
- [ ] Extended `tb_gpu` suite (sub-word formatting, strided memory stress, predication) + `valid`/`ready` handshake assertions
- [ ] Integrating C++ assembler toolchain directly into memory preload
- [ ] Standalone Software Golden Reference Model for automated testing
- [ ] Move vector registers from flip-flops to Block RAM (BRAM) / banked RAM
- [ ] Hardware branch reconvergence stack for nested control flow divergence
- [ ] `little-soc`: Connect LittleGPU to [LittleRISC-V](https://github.com/JimmyL76/LittleRISC-V) over AXI4-Lite, CPU-vs-GPU GEMM speedup study


## Acknowledgements

This project started from two open-source references:
* The overall SIMT model (block/warp/thread hierarchy, one core per block, one PC per warp) follows [tiny-gpu](https://github.com/adam-maj/tiny-gpu).
* The instruction set is [smol-gpu](https://github.com/Grubre/smol-gpu)'s modified RV32I encoding, including the `sx.*` vector-to-scalar predication instructions and the `.blocks` / `.warps` directive style.

Since the references are single-core or non-coalescing designs, the following made this a multi-core GPU with a more realistic memory hierarchy:
* The entire memory subsystem: the 128-byte line coalescer, the multi-channel memory controller with rotating-priority arbitration and middle-bit channel interleaving, dense per-channel address compaction, tagged split-transaction request/response routing, and per-user response buffering with end-to-end valid/ready backpressure.
* The per-core memory scoreboard (MSHR pool) and the warp-parking scheduler that together provide latency hiding - warps yield on memory issue and are woken by tag-matched out-of-order responses.
* Multi-wave block dispatch with bit-mask free-core detection and dynamic block retirement.
* The C++ assembler, verification environment, and PowerShell regression runner.

Once again, a huge special thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu).
