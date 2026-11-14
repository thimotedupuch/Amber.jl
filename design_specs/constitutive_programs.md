# Requested-output constitutive instruction programs

Typed expression laws can now lower into a shared instruction DAG. Canonical
operation/operand keys share intermediates across current, charge, and explicit
first/higher derivative requests. Neither instruction count nor graph shape is
part of the executable or workspace type. Lowering and evaluation use iterative
traversals with explicit node/work limits rather than recursive runtime calls.

`compile_constitutive` accepts `ConstitutiveRequest` records. The mutable,
task-owned `ConstitutiveWorkspace` caches values by epoch during one call;
subsequent inputs always advance the epoch. Requested roots evaluate only their
dependencies. Piecewise branches are lazy, so inactive overflow/domain-error
expressions and unrequested derivatives are not evaluated. Vector inputs follow
`program.input_names`; NamedTuple inputs are also available for inspection.
The numerical backend is finite Float64, not arbitrary precision or units in
expressions. Programs are immutable by convention after construction.

This remains an experimental reference backend for the existing constitutive
IR. Production device batches continue using their established kernels. Opaque
external callbacks, general native code generation, and automatic model migration
are outside this increment.

## Correctness regressions investigated

Read-only review exposed output-index vectors aliasing the evaluation stack:
node traversal cleared the indices and silently truncated output writes. Guards
now reject aliases with all scratch arrays, aliases between input/output buffers,
and destinations overlapping program storage. Offset-indexed vectors also gave
wrong partial results because input slots are one-based. Inputs/destinations now
explicitly require one-based indexing. Both issues have dedicated regressions.
Epoch wraparound, failed-evaluation recovery, partial inputs, inactive overflow
branches and workspace/program ownership are tested separately.

## Measurements

The equal-output diode benchmark compares current, charge, conductance,
capacitance and capacitance slope. One Julia 1.13.1 run, warm medians over 100
samples, time in microseconds:

| Backend/request | Median µs | Minimum bytes |
| --- | ---: | ---: |
| handwritten | 0.198 | 0 |
| tree | 0.224 | 0 |
| program_all | 1.127 | 0 |
| program_values | 0.483 | 0 |

The interpreter is slower than specialized handwritten/tree kernels. Zero warm
allocations and bounded graph-shape specialization do not establish a speed
advantage. It is not enabled as the production backend. The program contains
75 unique nodes; this bias executes 64 nodes for all outputs and
31 for current/charge only, demonstrating requested work scheduling.
First-build/JIT data and raw timings are retained; these are local tiny-kernel
measurements, not whole-simulation predictions.

## Validation

43 new assertions and 351 existing constitutive-IR/dependency assertions pass.
Independent diode kernels validate first/second derivatives across bias and
temperature. Additional tests cover common subexpressions, lazy branches,
requests, epoch invalidation, limits, ownership, failure recovery and indexing.

- [Driver](../benchmark/constitutive_programs.jl)
- [Measurements](measurements/constitutive_programs.toml)
