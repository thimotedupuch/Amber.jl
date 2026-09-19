# Compiler optimization implementation

This first implementation preserves the hierarchy-native typed batch backend.
It adds evaluation scheduling, numerical reuse, and inspection tools around it.

| Review item | Implemented | Further work |
| --- | --- | --- |
| 1. Requested-output evaluation | Residual-only assembly leaves Jacobians intact and skips behavioral gradients. Newton line searches retain the accepted residual separately. Conservative MOS steps evaluate current and charge together with first derivatives; residual-only steps request values. Continuous DAE Jacobians retain second derivatives. | General equation-derived kernels and additional model-specific fusion. |
| 2. Constant contributions | Workspaces cache linear G and C inside mixed nonlinear circuits. Cache fingerprints exclude independent source forcing and nonlinear parameters. Purely linear solves retain numeric factorizations across forcing changes. | Finer incremental updates of individual constant matrix slots. |
| 3. Frequency sweeps | AC uses the fixed union pattern and reuses symbolic LU analysis, with numerical refactorization at each frequency. Solver policy is respected. Statistics expose both counts. | Benchmark an optional KLU backend and extend reuse to other frequency-domain analyses. |
| 4. Device metadata | One dependency contract supplies linearity, forcing, and storage scheduling. Shared local stamp plans supply both slot counts and global positions. | A full constitutive-expression IR and optional behavioral-source AD. |
| 5. Structural analysis | `structural_analysis` provides equation incidence, maximum matching, unmatched rows/unknowns, and SCC blocks in dependency order. It excludes regularization diagonals and distinguishes DC from storage dependencies. | Equation transformations, observable reconstruction, tearing, and DAE index reduction. |
| 6. Repeated structure and updates | Local device stamp plans are reused across instances. `parameter_handle` resolves selectors once. Updates copy each affected batch once and reuse unchanged batch hashes. Sweeps and Monte Carlo reuse handles; Monte Carlo also reuses device records. | Template-level symbolic elimination plans and alternatives to the global contribution sort. |

## Correctness boundaries

- Cached linear matrices are parameter-dependent and independent of temperature,
  time, and state. Device contracts document this stronger meaning of linearity.
- Workspaces own caches; compiled snapshots remain shareable. Parameter handles
  require identity of the compiled topology, including after numerical updates.
- Structural incidence for nonlinear devices is conservative across possible
  states. A full matching does not prove numerical nonsingularity or a particular
  DAE index. Structural analysis currently reports blocks without changing the
  numerical unknown ordering.
- Compact parameter fingerprints encode built-in numerical data directly rather
  than repeatedly formatting expanded model types. They are internal identifiers,
  not a new circuit serialization format.
- Two cached sparse matrices increase workspace storage. Benchmark both assembly
  and complete analyses when evaluating the tradeoff.

## Validation and measurement

`test/Core/compiler_optimizations.jl` covers conservative residual derivatives
using central differences, residual-only callback behavior, constant matrix and
factorization invalidation, analytic RC frequency response, parameter update
isolation, and structural matching/block order. The existing physics,
conservation, transient, solver, serialization, sweep, and Monte Carlo suites
provide integration coverage.

`benchmark/compiler_pipeline.jl` measures passive, charge-based MOS, and
heterogeneous behavioral circuits. It reports elaboration and Julia compilation
separately from warm evaluation, parameter updates, structural analysis, and AC
sweeps. These are workload measurements, not tests of Julia's language behavior.

Validation on Julia 1.12.6: the complete `test/runtests.jl` suite passed all
2,363 tests. A separate two-thread run of `test/Analysis/monte_carlo.jl` passed
all 32 checks. Both benchmark drivers completed successfully during development.

## Initial comparison

Measured on Julia 1.12.6 with one Julia thread against baseline `684ab63`, using
`benchmark/compiler_comparison.jl`, 100 RC cells, and optionally 100 charge-based
MOS devices. Warm minima over 30 samples are used for kernels and updates, five
for compilation, and three for 40-frequency AC sweeps. These local measurements
are indicative; other work was running on the machine, and they are not universal
speedup guarantees.

| Operation | Baseline | Implementation |
| --- | ---: | ---: |
| Passive step residual + Jacobian | 3.21 μs | 1.84 μs |
| Passive line-search residual | 3.21 μs | 1.53 μs |
| Passive 40-frequency AC analysis | 4.09 ms | 2.82 ms |
| MOS step residual + Jacobian | 28.4 ms | 0.256 ms |
| MOS line-search residual | 28.4 ms | 0.196 ms |
| MOS 40-frequency AC analysis | 634 ms | 45.3 ms |
| MOS circuit text parameter update | 84.9 ms | 0.282 ms |
| MOS circuit resolved parameter update | — | 0.0487 ms |
| Passive circuit elaboration | 1.02 ms | 1.15 ms |
| MOS circuit elaboration | 1.79 ms | 3.07 ms |

MOS joint evaluation allocations fell from 17,545,600 to 358,400 bytes; the new
residual-only path allocated 115,200 bytes. Both passive evaluation paths remained
allocation-free. The extra fingerprint initialization makes elaboration slower,
while substantially reducing repeated update costs. Further compilation work
should target that initialization and the global sparse-contribution sort.
