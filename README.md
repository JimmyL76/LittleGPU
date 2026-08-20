# LittleGPU

A SIMT (Single Instruction, Multiple Thread) GPU implementation in SystemVerilog, featuring multi-core architecture with warp-based execution, latency hiding, memory coalescing, and a custom C++ assembler toolchain.

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

## Challenges & Lessons Learned

### Parallel Computations
Since many different computations are all going on within each clock cycle, I struggled with ensuring that multi-block/memory logic had no combinational feedback and was optimized for parallel non-sequential logic. Specifically, arbitration, bit-masking, and dynamic multi-wave block dispatch proved to be difficult components of logic to design.

### Memory Subsystem & Latency Hiding
Since many memory accesses happen at a time across the entire GPU, all users accessing memory should be as optimized as possible to not bottleneck the rest of the system. Earlier on, I struggled with figuring out pipelined accesses, coalescing 32 thread accesses, handling multiple warps across different pipeline stages, and buffering responses without race conditions. Implementing the 128-byte parallel coalescer and per-core memory scoreboard solved this by letting warps park upon issue and matching returning responses out-of-order with request tags. It showed me firsthand that parallelizing operations isn't just a free solution for speeding up everything, and why memory latency hiding is a huge challenge in GPU architecture.

### SIMT Registers & Control Flow
What makes GPU logic especially complex is handling all the different nuances of modern programs that run on GPUs. These processes have non-linear execution paths, dependent data access patterns, and control flow divergence. In LittleGPU's case, jumps and branches act as scalar operations, despite the fact that certain pieces of data can diverge differently, thus creating the need for special vector-to-scalar instructions (`sx.slt`, `sx.slti`). It was important to implement the logic for these instructions while keeping inputs/outputs to scalar and vector registers consistent and separate.

## Next Steps

Currently working on...
- [x] Multi-channel response-buffered memory controller
- [x] Parallel 128-byte memory coalescer
- [x] Fine-grained warp latency-hiding scheduler and memory scoreboard
- [x] Automated test suite & top-level GPU benchmark verification (`tb_gpu`)

Next in line...
- [ ] Extended `tb_gpu` suite (sub-word formatting, strided memory stress, predication)
- [ ] Integrating C++ assembler toolchain directly into memory preload pipeline
- [ ] Standalone Software Golden Reference Model for automated differential fuzz testing
- [ ] Hardware branch reconvergence stack for nested control flow divergence
- [ ] FPGA synthesis, clock frequency analysis, and resource utilization in Vivado

## Acknowledgements
Once again, a huge special thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu).
