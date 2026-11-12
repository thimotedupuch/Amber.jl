# Structural solve plan: numerical and performance study

## Scope and method

This is an experimental executable equation-block ordering, with an opt-in
operating-point integration. Default Newton solves retain their existing
factorization reuse. No unknowns or equations are eliminated.

Measurements use `benchmark/structural_solve_plan.jl`, Julia 1.13.1, CPU
`raptorlake`, 1 Julia thread(s). Times below are warm minima of 20 samples.
They are indicative local measurements; compilation/tests were also running on
the machine. Allocations help identify implementation costs but these samples
do not support general statistical speedup claims. Plan construction is measured
separately. Raw data and the chart are retained beside this report.

Three linear-solve baselines matter: Julia's native sparse `A\b`, Amber's
explicit `SuiteSparseLU` policy, and the plan executor. Neither direct LU path
caches factors in the matrix microbenchmark. Actual default operating points
retain factorization reuse within the simulation.

## Matrix microbenchmarks

128 unknowns; time in microseconds; allocation column is plan bytes per solve.

| Matrix | Native sparse | Amber LU policy | Plan | Plan bytes |
| --- | ---: | ---: | ---: | ---: |
| feedforward | 0.98 | 14.47 | 12.58 | 23328 |
| symmetric_coupled | 26.51 | 53.97 | 58.83 | 168432 |
| nonsymmetric_coupled | 53.53 | 54.19 | 57.55 | 168448 |

The feed-forward plan is substantially slower than native sparse backslash.
Inspection of the installed SparseArrays `linalg.jl` confirms native dispatch
recognizes triangular matrices and directly performs triangular solves. The
plan additionally scans compatibility, permutes CSC storage, constructs result
and diagnostic buffers, and checks backward error. Component timings in the raw
data measure those costs separately. This overhead is a real limitation of this
prototype, not a reason to imply a faster native solve is using a comparable
LU algorithm.

For symmetric coupled matrices native dispatch selects a Hermitian route.
Nonsymmetric coupled matrices avoid that algorithm-selection difference and
provide the cleaner comparison with Amber's configured LU policy. A single SCC
has no block decomposition benefit. An initial version needlessly permuted and
extracted that whole block; the implementation now routes such plans directly
to the original matrix's configured global LU. Validation and diagnostics still
cost time and allocations. Singletons in multi-block plans use direct division
rather than constructing one LU factorization per scalar.

## End-to-end operating points

16 feed-forward stages, with or without a diode at each stage. Time in
microseconds. Iteration counts are global / plan.

| Circuit | Default | Plan | Iterations | Fallbacks |
| --- | ---: | ---: | ---: | ---: |
| Linear | 37.05 | 39.63 | 10 / 10 | 0 |
| Nonlinear | 135.34 | 117.84 | 25 / 25 | 0 |

Both strategies converge to equivalent states and have identical Newton
iteration counts in these cases. This illustrates why tiny matrix-solve costs
alone cannot predict a complete simulation: source continuation, scaling,
assembly, sparse factorization and allocations contribute differently. These
particular feed-forward circuits expose scalar blocks. They do not establish
benefits for strongly coupled analog circuits or other models.

The plan remains opt-in. Block factorization reuse, persistent CSC slot routing,
multiple RHS, and block-local nonlinear iteration remain future work. Repeated
nonlinear solves involving larger coupled blocks may pay substantial additional
cost because the executor currently re-extracts and refactors them.

## Numerical regression found and fixed

Review reproduced an actual bug in the initial backward-error diagnostic:

```julia
A = sparse([1e200 1e200; 0.0 1e200])
b = [1e308, -1e308]
```

Block substitution overflows, but configured global LU returns the finite
solution `[2e108, -1e108]`. Directly evaluating `A*x-b` still overflows and the
old diagnostic returned `NaN` after successful fallback.

The fix retains the ordinary calculation for ordinary scales, then uses
normalized operands and aligned binary exponents when products or norms would
overflow. The final diagnostic must be finite. Tests cover this reproducer and
a zero-RHS case whose unnormalized residual overflows. Backward error still
measures residual quality, not conditioning or forward solution accuracy.

## Validation

The targeted plan suite passes 60 assertions, including permutations, complex
matrices, integer RHS, incompatible matrices, numerical fallback, singularity,
parameter changes, storage-inclusive Jacobians, and operating-point equivalence.
A fresh full package run after the overflow fix passes all 3,212 assertions
(Julia 1.13.1, 6m47.6s). `git diff --check` is clean.

This study compares strategies within the implementation. It does not measure
historical-checkout default-path timing or claim broad performance equivalence.

- [Raw measurements](measurements/structural_solve_plan_julia_1_13.toml)
- [Performance chart](structural_solve_benchmark.html)
