# LittleGPU

A SIMT (Single Instruction, Multiple Thread) GPU implementation in SystemVerilog, featuring multi-core architecture with warp-based execution and a custom C++ assembler toolchain. Current Project Time: ~40 Hours.

## Overview

This project implements a simplified GPU architecture with the purpose of being an introduction to how modern GPUs work. It supports parallel execution of a compute kernel across multiple cores using thread blocks and warps. The instructions are based on a more advanced RISC-V RV32I ISA based on [smol-gpu](https://github.com/Grubre/smol-gpu). Much of this project is heavily inspired by [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu), so I'd recommend checking those projects out if you're curious about some more background and general details on GPU architecture.

## Features

- **Multi-Core SIMT Architecture**: Multiple processing cores executing warps in parallel
- **CUDA-Inspired Threading Model**: Organized execution using blocks and warps
- **Custom Instruction Set**: GPU-specific operations optimized for parallel computation
- **Memory Controller**: Multi-channel memory interface with round-robin-like arbitration
- **C++ Assembler Toolchain**: Complete development environment for GPU kernels
- **Warp-Based Execution**: 32-thread warps with shared program counter
- **Synthesizable Design**: Clean SystemVerilog implementation targeting FPGA platforms

## Architecture

The overall architecture begins with an input of a task or process that is easily broken down into many smaller, parallel computations. The goal of the GPU is to efficiently distribute key resources to perform similar operations on many pieces of data at once, resulting in very high throughput. Some examples of GPU-friendly tasks include 3D graphics rendering, matrix operations, training neural networks, etc.

To begin, we start with threads as the fundamental units of computation. Each thread performs its part of the overall computation with its own input data and output results. Due to the parallel nature of these calculations, they can be organized into groups of threads, called warps, which run the same vector/SIMT instructions at once across each thread. 

To do these calculations, the warps need many Arithmetic Logic Units (ALUs) as well as multiple units to access key shared resources and memory, such as Load Store Units (LSUs), fetchers, decoders, and registers. These can then be organized and grouped into their own compute cores or Streaming Multiprocessors (SMs). To group together warps to run on each SM, one more layer called a block is added. Blocks are then assigned to compute cores/SMs to run in, creating a massively parallel compute organization hierarchy.

To aid with this, vector registers are used, which hold multiple data elements for a group of parallel threads. In terms of memory hierarchy, the memory controller will handle requests from multiple cores to access global memory. This way, input data and output results can be sent through memory channels.

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
The memory controller uses asynchronous ready + synchronous valid signals. This minimizes delay and is intended so that the memory controller can move on to additional memory requests as soon as the handshaking is complete. Otherwise, fully waiting for a request to complete would make memory latency masking impossible. As of now, in this simplified implementation, the handshaking protocol actually does not result in this effect due to the non-pipelined LSUs, fetchers, and memory channels. 

## Core Design

When a core/SM runs a warp, it needs a fetcher, decoder, scalar LSU, scalar ALU, a set of vector registers, and a set of scalar registers. In this simple implementation, there is a set of all of these hardware components for each warp within a core. Thus, within a warp, each thread has the same PC and instructions to run. Inside each core, there are a certain number of shared vector/thread ALUs and LSUs. In LittleGPU, these are only enough to run all the threads within one warp at a time per core.

Together, this means that all warps can proceed through fetch and decode within a core at the same time. However, we must arbitrate and decide which singular warp gets access to the shared ALUs/LSUs to progress through the request/wait (load from memory or registers), execute (ALU operations), and update (store into memory or registers) stages. This is done with the FCFS + bit-masking approach by checking which warps are not in the idle/fetch/done stages.

### Vector SIMT Registers
To perform similar calculations in a highly parallel manner across many pieces of data, each warp has one vector register file, with each vector register consisting of 32 essentially normal scalar registers. For example, `x4` - `x31` are general purpose vector registers, so loading `x4` from the register file would mean loading 32 data values, each being 32-bit themselves. By setting each of these 32 data values to be different, we can perform the same calculation on different pieces of data in parallel. 

Registers `x0` - `x3` are read-only and have special purposes:
|**Register**|**Function**   |
|------------|---------------|
|`x0`        |zero           |
|`x1`        |thread id      |
|`x2`        |block id       |
|`x3`        |block size     |
|`x4`-`x31`  |general purpose|

Notice that if we set thread ids to be values 0 through 31, we can load from 32 different memory addresses. Here is an example program from [smol-gpu](https://github.com/Grubre/smol-gpu) for better visualization:
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
|`s2`-`x31`  |general purpose|

Notice that the example code used the special vector-to-scalar instruction ```sx.slti``` to turn off calculations for a specific thread. This masking is one way to solve the branching issue inside SIMT architectures and ensure the threads properly converge back to the same instruction.

## Testing & Verification

TBD

## Challenges & Lessons Learned

### Parallel Computations
Since many different computations are all going on within each clock cycle, I struggled with ensuring that multi-block/memory logic had no combinational feedback and was optimized for parallel non-sequential logic. Specifically, arbitration and bit-masking proved to be difficult components of logic to design.

### Memory Details
Since many memory accesses happen at a time across the entire GPU, all users accessing memory should be as optimized as possible to not bottleneck the rest of the system. Successful memory usage is needed to keep track of ready, valid, address, data, and WE signals between LSUs/fetchers, memory controllers, and memory itself. 

However, I wasn't able to finish figuring out pipelining accesses, coalescing analysis, cache line size, larger requests for blocks of data ("DRAM burst"), multiple warps in different pipeline stages, memory consistency with separate load/stores, buffering queues, etc. There are a bunch of details to be figured out here, which only goes to show that parallelizing operations isn't a free secret to success (more parallel = more complex logic). 

### SIMT Registers
What makes GPU logic especially complex is handling all the different nuances of modern programs that run on GPUs. These processes have non-linear execution paths, dependent data access patterns, and control flow divergence. In LittleGPU's case, jumps and branches act as scalar operations, despite the fact that certain pieces of data can diverge differently, thus creating the need for special vector-to-scalar instructions. It was important to implement the logic for these instructions while keeping inputs/outputs to scalar and vector registers consistent and separate.

## Next Steps

Next in line...
- [ ] Simulation and verification
- [ ] Implementing on a real process and/or hardware system
- [ ] More sophisticated warp/thread/block scheduling algorithms (global thread indexing?)
- [ ] Greater depth of detail in memory implementation (see above Memory Details)
- [ ] Better handling of branch/jump divergence

## Acknowledgements
Once again, a huge special thanks to [tiny-gpu](https://github.com/adam-maj/tiny-gpu) and [smol-gpu](https://github.com/Grubre/smol-gpu) for their helpful explanations.
