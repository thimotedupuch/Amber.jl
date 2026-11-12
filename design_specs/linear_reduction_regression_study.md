# Reversible linear reduction: regression study

## Implementation boundary

The plan snapshots a numerical operator, eliminates one-/two-term affine
equations, records RHS substitutions, and reconstructs unknowns in original
solver order. Sparse column incidence identifies affected rows. Each step has a
bound on introduced positions; zero is the default. At equal fill/degree cost,
stronger row-relative pivots are preferred. Candidate construction and numerical
updates are deterministic. Any nonfinite coefficient update aborts that step
without modifying the remaining operator.

Repeated RHS values may reuse the operator snapshot. Changed matrix coefficients
require a new plan. `reduced_operating_point` is a linear-contract-only DC entry
point returning a normal result against the original compiled circuit. It
preserves voltage, source current, power and report identities. Nonlinear and
arbitrary behavioral models are conservatively rejected. The default compiler
and solver layouts are unchanged.

This is an initial numerical affine transformation, not a symbolic rewrite of
constitutive expressions or a general Schur-complement compiler. It does not
transform storage equations, DAE constraints, AC feedthrough or noise injections.
Those transformations require separate reconstruction/dependency semantics.

## Numerical regressions found and fixed

### Weak equations hidden by global norms

The initial reconstruction used only a global normwise backward-error check:

```julia
A = sparse([1e-12 1.0; 1e-20 1e-20])
b = [1.0, 2e-20]
```

Eliminating the tiny first pivot reconstructed x1 approximately 0.999866856,
instead of 1.000000000001. The global error was about 6.66e-25, while the weak
second equation had a relative residual of about 6.66e-5.

Acceptance now requires both normwise and componentwise backward error. The
componentwise denominator is `abs(A)*abs(x) + abs(b)` for each equation, retaining
weak equations instead of comparing them with unrelated large coefficients.
Products and residuals are normalized with per-row binary exponents to avoid
overflow and underflow. Stronger-pivot preference avoids this particular unstable
order; an explicitly constructed valid-but-unstable plan tests that the error
guard still catches it and falls back to global LU. The resulting convergence
flag also controls the direct operating-point result.

Backward error does not establish forward accuracy for an ill-conditioned
operator. A global fallback that still exceeds the error tolerance is reported
as unconverged rather than silently labeled successful.

### RHS substitution overflow

For `A = sparse([1e200 1e200; 0.0 1e200])` and
`b = [1e308, -1e308]`, intermediate RHS substitution overflows despite a finite
solution. Both partial and complete reductions are tested. Detection occurs
before reduced LU; the default falls back to the original operator. Strict mode
and standalone RHS/reconstruction helpers reject unrepresentable substitutions.
Real operators also support complex RHS values; integer RHS values are promoted
consistently for substitution, fallback and error diagnostics.

## Performance method

Measurements: Julia 1.13.1, CPU `raptorlake`, 1 Julia thread(s), warm
minima of 20 samples. Other validation was active on the machine; these
are indicative local timings, not general speedup guarantees. Construction is
separate from reused solves. Raw timings and allocations are retained.

### Matrix cases

Time in microseconds. A cycle has no admissible zero-fill elimination; the
operator remains full size. Feed-forward matrices reduce to reconstruction only.

| Matrix | Unknowns | Retained | Construction | Native solve | Reused reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| feedforward | 16 | 0 | 31.96 | 0.16 | 3.00 |
| feedforward | 64 | 0 | 399.10 | 0.52 | 4.97 |
| feedforward | 128 | 0 | 1610.92 | 1.01 | 9.74 |
| cycle | 16 | 16 | 5.71 | 12.12 | 12.85 |
| cycle | 64 | 64 | 20.74 | 33.50 | 37.05 |
| cycle | 128 | 128 | 43.10 | 60.23 | 68.19 |

Reused reduction is slower than native triangular solves in these feed-forward
cases. It pays for RHS/reconstruction buffers and two independent residual
checks. Construction also scales poorly because candidate equations are rescanned
after each accepted substitution: column incidence avoids scanning all equations
for every affected column, but it does not remove the repeated candidate scan.
The warm timing/allocation growth on the chain cases makes this limitation
visible. Incremental candidate queues and persistent symbolic/template plans are
future work, not claimed optimizations.

### Circuit cases

Resistor ladders; time in microseconds, including construction in both direct
entry points. The unreduced direct baseline isolates the cost of bypassing
Newton continuation from the cost of elimination itself.

| Sections | Default Newton | Direct unreduced | Direct reduced | Eliminated |
| --- | ---: | ---: | ---: | ---: |
| 8 | 39.48 | 14.32 | 14.59 | 10 |
| 16 | 54.73 | 20.17 | 23.71 | 18 |

Direct linear DC solving explains much of the improvement versus Newton in these
examples. Reduction is slower than direct unreduced solving on the larger
ladder. These results do not justify enabling elimination by default. Future
work should measure factor fill and larger coupled systems, retain reusable
numerical workspaces, and account explicitly for construction amortization.

## Validation

115 new assertions pass. Another 166 existing operating-point, convergence,
result, report, current/power readout and display assertions pass. Tests include
independent permutations, repeated RHS, fill bounds, immutable source snapshots,
complex coefficients/RHS, integer RHS, extreme scale, singularity, parameter
updates, and original circuit observable reconstruction. The full package suite
was not rerun for this isolated opt-in addition. `git diff --check` is clean.

- [Benchmark driver](../benchmark/linear_reduction.jl)
- [Raw measurements](measurements/linear_reduction_julia_1_13.toml)
- [Chart](linear_reduction_benchmark.html)
