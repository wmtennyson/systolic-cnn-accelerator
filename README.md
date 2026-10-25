# INT4 Systolic CNN Accelerator

An FPGA inference accelerator built around an 8×8 two-dimensional systolic array for low-precision convolution. The project connects quantization-aware VGG16 training, integer reference modeling, RTL verification, and FPGA implementation targeting the Intel Cyclone IV GX.

**Status:** In development. Performance and verification results will be added as implementation progresses.

## Overview

The accelerator targets convolution with 4-bit activations and 4-bit weights. An adapted VGG16 layer with eight input channels and eight output channels serves as the initial workload, aligning its channel dimensions with the processing array.

The project spans:

- Quantization-aware training and model evaluation.
- Integer convolution modeling and stimulus generation.
- RTL design of the processing array, memory interfaces, and datapath.
- End-to-end simulation against software-generated reference outputs.
- FPGA synthesis, placement and routing, timing analysis, and power estimation.

## Architecture

The planned hardware architecture includes:

| Component | Function |
|-----------|----------|
| 8×8 systolic array | Parallel multiply-accumulate computation |
| Activation and weight scratchpads | Local operand storage |
| Partial-sum scratchpad | Intermediate and accumulated result storage |
| L0 buffer | Operand staging and delivery to the array |
| Output FIFO | Buffering array results before scratchpad writes |
| Special function unit | Partial-sum accumulation and ReLU |

The RTL hierarchy separates the processing logic from the scratchpad memories:

- `core.v` integrates the corelet and scratchpad memories for simulation.
- `corelet.v` contains the processing array, buffers, and special function unit, and serves as the FPGA synthesis target.

## Quantized Model

VGG16 is adapted for quantization-aware training using 4-bit input activations and 4-bit weights.

A selected convolution layer is reduced to eight input and eight output channels, with no batch normalization immediately following it. The selected layer provides the workload for hardware verification.

The software reference reconstructs the convolution output from quantized operands, applies the required scaling and ReLU, and compares the result with the captured input to the next layer.

### Targets

- Classification accuracy above 90%.
- At least one convolution layer with eight input and eight output channels.
- Maximum absolute reconstruction error below 1e-3.

## Verification

The verification flow connects the trained model to the RTL simulation:

1. Export quantized activations, weights, and expected outputs.
2. Load activation and weight scratchpads through the testbench.
3. Transfer kernel weights into the processing elements through L0.
4. Stage activations and execute the convolution.
5. Transfer partial sums through the output FIFO into scratchpad storage.
6. Accumulate partial sums and apply ReLU in the special function unit.
7. Compare hardware outputs against the software reference.

The target is zero mismatches between RTL results and the exported expected outputs.

## FPGA Implementation

| Setting | Target |
|---------|--------|
| FPGA family | Intel Cyclone IV GX |
| Device | EP4CGX150DF31I7AD |
| Toolchain | Quartus Prime 19.1 |
| Synthesis top level | `corelet` |
| Timing characterization | Slow corner |
| Power estimation | 20% input activity factor |

## Results

Measured results will be populated after training, verification, and FPGA implementation.

| Metric | Result |
|--------|--------|
| Model accuracy | Pending |
| Maximum software reconstruction error | Pending |
| RTL output mismatches | Pending |
| Slow-corner maximum frequency | Pending |
| Estimated power | Pending |
| Logic utilization | Pending |
| Register utilization | Pending |
| DSP utilization | Pending |

## Reproducibility

Training instructions, model checkpoints, stimulus-generation commands, simulation steps, and FPGA build settings will be documented as each stage becomes available.

## Acknowledgments

This project builds on concepts and development resources from UC San Diego's ECE 284 course. Attribution for any reused RTL, testbench templates, and third-party software will be included alongside the relevant files.
