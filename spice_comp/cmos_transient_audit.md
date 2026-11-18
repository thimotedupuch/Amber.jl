# Audit of the CMOS transient bank and chain

This revisits the transient conclusions in `cmos_comparison.md`. The prior speed
ratios are timings of specific fixed/adaptive workflows. They do not establish
an equal-accuracy performance ratio, and should not be read that way.

## What checked out

The bank really has independent matched inverter loads on shared input/supply;
the chain really connects each output to the next gate. Pulse rise, fall, width,
delay and period match. Initial operating points use the same input levels.
The BDF2 charge-history formula and copied charge storage are consistent.

The all-output audit checks ten chain stages rather than just endpoints; every
stage switches between the rails. The maximum discrepancy on Amber's saved grid
still occurs at the first stage, about 9.816 mV. Hidden middle-stage errors did
not explain this example's slowdown. All 100 bank outputs are identical across
all 3,361 saved times: maximum spread is zero (`cmos_bank_symmetry.toml`).

## The comparison problem

Amber's combination of `max_step` and `saveat` selected fixed-step integration.
Its `SolverOptions(reltol=1e-6)` controls Newton convergence, not a local
truncation-error acceptance test. ngspice's `RELTOL` also governs adaptive
integration. Equal tolerance flags and maximum steps therefore did not mean
equal integration accuracy.

The original verification interpolated ngspice onto Amber's saved times only,
and used default printed precision. It reported a one-sided sampled discrepancy,
not a bound on the whole continuous waveform. The new audit uses high-precision
all-node traces and separate finer ngspice references. Agreement between 4 ps
and 2 ps references is about 25.2 microvolts at the worst node. On the dense
2 ps reference grid, linearly interpolated 62.5 ps traces differ by approximately
14.31 mV for Amber and 6.33 mV for ngspice. These values include interpolation
error. At each simulator's own sample times, the corresponding maxima are
14.31 mV for Amber and 4.49 mV for ngspice. The 4 ps versus 2 ps agreement is an
empirical refinement check, not a rigorous bound on absolute error.

Thus the former 9.82 mV mutual discrepancy was not an error bound for either
simulator. A fair equal-accuracy speed claim would require independently tuning
each simulator against a common reference and timing those chosen settings.
This audit does not claim to have completed that parameter search.

## Work and performance diagnosis

At 62.5 ps over 210 ns, Amber accepts 3,360 steps. ngspice retains 3,574 internal
points for one inverter and 4,592 for the ten-stage chain. Saved ngspice points
are not counts of rejected steps or all internal Newton iterations. Nevertheless,
the slower Amber run is not taking substantially more accepted steps.

A counter-instrumented single-inverter run records 7,024 transient Newton
iterations (7,042 including initialization) and 6,236 numeric factorizations
including initialization. CPU profiling puts about 58% of active samples in
UMFPACK numerical factorization. This is a five-unknown matrix. No missed
reuse opportunity between bit-identical consecutive normalized matrices was
observed in that run, so simply weakening a cache key is not an evidence-based
fix. Tiny numerical Jacobian changes still require refactorization under the
current exact-reuse policy.

An isolated diagnostic substitutes a dense solve into the Newton method in a
separate Julia process, with one BLAS thread. It makes no change to Amber's
production source or selected solver policy. Minimum of five warmed analyses:

| Case | Existing sparse solve | Dense diagnostic | Max full-trace difference |
| --- | ---: | ---: | ---: |
| 1-gate bank | 102.58 ms | 39.14 ms | 1.3e-15 V |
| 10-gate chain | 285.94 ms | 110.24 ms | 1.8e-14 V |
| 100-gate bank | 756.13 ms | 1030.06 ms | 1.3e-14 V |

The dense diagnostic speeds up the five-unknown inverter and fourteen-unknown
chain, but slows the 104-unknown bank. This identifies small-matrix backend
selection as an optimization target; it does not justify replacing sparse LU
for every circuit or silently ignoring an explicitly requested SuiteSparse
policy. No approximate Jacobian reuse or relaxed convergence test was introduced.
These diagnostic timings isolate implementation overhead and are not a new
ngspice equal-error comparison.

## Benchmark corrections and reproduction

`ngspice_cmos.jl` now explicitly selects `adaptive=false`, labels the error grid,
records accepted steps, saved points and Newton iterations, records ngspice
points per analysis, and separates the tolerance meanings in metadata/comments.
It checks symmetry over every output of a transient bank. Existing first/last
waveform checks remain a quick smoke check; the independent audit supplies the
all-node and fine-reference checks.

```sh
# Original workflow with corrected metadata and all-bank symmetry assertion:
AMBER_SPICE_KINDS=transient AMBER_SPICE_CELLS=1,100 AMBER_SPICE_REPEATS=1 julia --project=Amber benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_TOPOLOGY=chain AMBER_SPICE_CELLS=10 AMBER_SPICE_REPEATS=1 julia --project=Amber benchmark/ngspice_cmos.jl
# Independent all-node, high-precision reference accuracy audit:
julia --project=Amber benchmark/ngspice_cmos_audit.jl
# Diagnostic only, in its own Julia process:
julia --project=Amber benchmark/cmos_linear_solver_diagnostic.jl
```

Raw metadata rechecks: `cmos_transient_audit_recheck.toml`,
`cmos_chain_audit_recheck.toml`. Dense diagnostic: `cmos_linear_solver_diagnostic.toml`.

All-node reference data: `cmos_audit_results.toml`. The audit additionally asserts
finite and ordered traces, full rail switching of every chain stage, and
4 ps versus 2 ps reference agreement within 0.1 mV.

Validation: the independent accuracy audit ran successfully end to end with its
convergence, finiteness, time-ordering, rail-swing and reference-refinement
assertions. Main benchmark bank1/bank100 and chain10 rechecks pass; the final
bank runs also pass the newly integrated all-output symmetry assertion. The
dense diagnostic passes full-state/full-time waveform equivalence assertions.
`git diff --check` passes. This pass changes benchmark diagnostics and reports,
not production solver equations or solver selection.
