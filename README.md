# LittleGPU

A SIMT (Single Instruction, Multiple Thread) GPU implementation in SystemVerilog, featuring multi-core architecture with warp-based execution and a custom C++ assembler toolchain.

## Overview

This project implements a simplified GPU architecture with the purpose of being an introduction to how modern GPUs work. It supports parallel execution of a compute kernel across multiple cores using thread blocks and warps. The instructions are based on a more advanced RISC-V RV32I ISA based on [smol-gpu](https://github.com/Grubre/smol-gpu). Much of this project is heavily inspired by [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu), so I'd recommend checking those projects out if you're curious about some more background and general details on GPU architecture.

**NOTE: LittleGPU is very much a work-in-progress and more will be added to this project as I complete further parts of it. Feel free to check out what I have so far!**

## Features

- **Multi-Core SIMT Architecture**: Multiple processing cores executing warps in parallel
- **CUDA-Inspired Threading Model**: Organized execution using blocks and warps
- **Custom Instruction Set**: GPU-specific operations optimized for parallel computation
- **Memory Controller**: Multi-channel memory interface with round-robin arbitration
- **C++ Assembler Toolchain**: Complete development environment for GPU kernels
- **Warp-Based Execution**: 32-thread warps with shared program counter
- **Synthesizable Design**: Clean SystemVerilog implementation targeting FPGA platforms

## Architecture

The overall architecture begins with an input of a high-level task that is easily broken down into many smaller, parallel computations. The goal of the GPU is to efficiently distribute key resources perform similar operations on many pieces of data at once, resulting in very high throughput. Some examples of GPU-friendly tasks include 3D graphics rendering, matrix operations, training neural networks, etc. 

To begin, we start with threads which are the fundamental units of computation. Each thread performs a part of the overall computation. Warps are a group of potentially 32 threads that execute in a SIMD manner, which are organized and grouped into blocks. Blocks are then each assigned to their own compute core to run in, creating a massively parallel compute organization hierarchy.

To aid with this, we also have vector registers that hold multiple data elements for a group of parallel threads. In terms of memory hierarchy, the memory controller will handle requests from multiple cores to access global memory.

## Assembly

For this project, I created an assembly to binary assembler that translates instructions based on smol-gpu's modified RV32I ISA. 

### C++ Assembler Key Features
- `std::pair<string, vector<string>>` for mnemonic + operands
- `std::map` for instruction encoding tables
- Regular expressions for parsing memory addressing format `offset(base)` 
- Label resolution with PC-relative offset calculation

This allows for supporting GPU-specific addressing modes, scalar/vector register notations, and comprehensive error handling.

For the block/warp model, I also chose to use CUDA-style `.blocks <num_blocks>` and `.warps <num_warps>` directives. This seems to better mirror real GPU architectures versus centralized control registers.

## Core/Block Dispatch Logic 
GPU dispatcher uses bit-masking for efficient matching of pending blocks to free cores, dispatching up to 4 blocks per cycle:
1. Identifies free cores using `core_reset` status
2. Employs `first_clear = (~core_reset[i]) & (core_reset[i] + 1)` for O(1) free core detection
3. Parameterized utility function to convert one-hot to binary for core indexing

## Memory Controller Design

The memory controller handles requests from users (load store units/LSUs, fetching units), arbitrates based on the number of free memory channels and a rotating priority, then sends memory accesses to the global memory through multiple channels. Since the GPU's input, output, and shared data across all of its thread blocks will be in global memory, this is a key aspect to optimize to prevent bottlenecks, particularly in modern GPUs.

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
Time T3: Channels 1,3,0,2 fetch cache lines I,J,K,L (different again!)
```

With the first example, the ability to predict and optimize same row accesses, prefetch next cache lines, and have efficient pipelining are all available. Although we trade the possibility of access hotspots and load imbalances, this address decode approach seems advantageous in this simple implementation.

Notice that, for block/core dispatching, FCFS + bit masking was used because computer blocks do not seem to have the same spatial relationships and optimizations that memory addresses do.

### Handshaking Protocol
The memory controller uses asynchronous ready + synchronous valid signals. This minimizes delay and also ensures that the memory controller can move on to additional memory requests as soon as the handshaking is complete. Otherwise, fully waiting for a request to complete would make memory latency masking impossible.

## Testing & Verification

TBD

## Challenges & Lessons Learned

### Parallel Computations
Since many different computations are all going on within each clock cycle, I struggled with ensuring that multi-block/memory logic had no combinational feedback and optimizing parallel non-sequential logic.

## Next Steps

Currently working on...
- [ ] Finishing memory, core, ALU/LSU/fetcher units, and scalar/vector registers
- [ ] Simulation and verification

Next in line...
- [ ] Implementing on a real process and/or hardware system
- [ ] More sophisticated warp/thread/block scheduling algorithms
- [ ] Greater depth of detail in memory implementation, possibly with L1/L2 cache

## Acknowledgements
Once again, much of this project's learning and ISA/architecture is heavily inspired by [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu). 
