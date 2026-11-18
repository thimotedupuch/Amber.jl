# Extended ngspice comparison

Reproduce from the repository root:

```sh
pixi install --manifest-path spice_comp/pixi.toml
julia --project=Amber benchmark/ngspice_extended.jl
```

Julia 1.13.1, one thread, ngspice 41. Each circuit is compiled before its first
analysis; first analysis time is recorded separately. Warm timings are the minimum
of five subsequent analyses of the exact same compiled circuit. ngspice timings
include process startup, parsing and text output. Earlier cases may contribute
shared Julia compilation to later cases. These are simulation timings, not circuit
construction comparisons.

Baseline seconds:

| Analysis | Cells | Amber warm | ngspice process | Amber / ngspice |
| --- | ---: | ---: | ---: | ---: |
| Diode DC | 10 | 0.000238 | 0.00385 | 0.06 |
| Diode DC | 100 | 0.00113 | 0.00488 | 0.23 |
| Diode DC | 1,000 | 0.00941 | 0.0158 | 0.60 |
| Diode transient | 10 | 0.0131 | 0.0102 | 1.29 |
| Diode transient | 100 | 0.0559 | 0.0270 | 2.07 |
| Diode transient | 1,000 | 0.517 | 0.246 | 2.10 |
| RC AC sweep | 10 | 0.00281 | 0.00472 | 0.60 |
| RC AC sweep | 100 | 0.0199 | 0.00805 | 2.48 |
| RC AC sweep | 1,000 | 0.164 | 0.0308 | 5.33 |

Diode circuits contain independent parallel 1 kohm / 1 nF loads with identical
Is=1e-12, N=1 diodes at 300 K. Transients run to 100 us, maximum step 100 ns,
relative tolerance 1e-6. Amber retains all unknowns; ngspice prints the first load.
Amber's fixed stepping and ngspice's adaptive integration are different workloads.
The DC and final transient voltages agree to 0.21 microvolt, but final values alone
do not establish time-domain accuracy equivalence.

AC circuits are RC ladders, swept over 501 linearly spaced frequencies from 10 Hz
to 1 MHz. Both use a unit AC voltage source. Initial checks establish agreement
at the final frequency within ngspice's default print precision. Separate
investigations cover the AC and diode transient gaps, strengthening correctness
checks before accepting optimizations.

Raw baseline data: `extended_results.toml`.

## Fixes and validation

Two investigation subagents profiled the warmed gaps independently.

The AC sweep now detects a connected path in the matrix union sparsity pattern,
permutes it to tridiagonal form and uses pivoted LU. This preserves zero-pivot
handling for ideal voltage sources. Other graphs fall back to SuiteSparse.
Passing explicit `SolverOptions` retains the requested SuiteSparse policy;
omitting it selects the automatic path, including through `SmallSignal` analysis
descriptors. Tests compare every state/frequency with SuiteSparse, including
arbitrary permutations and nonsymmetric matrices, and cover singular systems,
cycles/disconnected fallback, and explicit ordering options.

Nonlinear Newton solves now reuse numerical factors when the normalized matrix
is bit-identical, provided the full existing cache key and variable scales also
match. No approximate coefficient comparison is used. Tests cover settled diode
reuse and invalidation after temperature changes.

Final warm timings, seconds (five repeats; full test process paused during timing):

| Analysis | Cells | Amber before | Amber after | ngspice after | Amber speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| dc | 10 | 0.000238 | 0.000270 | 0.004612 | 0.88x |
| dc | 100 | 0.001131 | 0.001102 | 0.005208 | 1.03x |
| dc | 1,000 | 0.009411 | 0.009140 | 0.015693 | 1.03x |
| transient | 10 | 0.013087 | 0.010749 | 0.007700 | 1.22x |
| transient | 100 | 0.055895 | 0.052084 | 0.026802 | 1.07x |
| transient | 1,000 | 0.516943 | 0.435268 | 0.241872 | 1.19x |
| ac | 10 | 0.002813 | 0.000341 | 0.004637 | 8.25x |
| ac | 100 | 0.019942 | 0.002778 | 0.008851 | 7.18x |
| ac | 1,000 | 0.164288 | 0.030561 | 0.030469 | 5.38x |

The 1,000-cell AC gap is eliminated: approximately 164 ms to 31 ms, comparable
to ngspice's 30 ms including startup. The 1,000-load transient improves about
16%, but remains about 1.8x slower at 100 ns. This remaining ratio is not an
accuracy-normalized comparison.

Full transient trajectory checks reveal a 5.10 mV startup discrepancy at 100 ns.
At 25 ns it drops to 0.358 mV (about 14x smaller). The refined 1,000-load run costs
1.250 s in Amber versus 0.905 s in ngspice; see `extended_refined_results.toml`.
Reproduce refinement with:

```sh
AMBER_SPICE_KINDS=transient AMBER_SPICE_CELLS=100,1000 AMBER_SPICE_STEP=2.5e-8 julia --project=Amber benchmark/ngspice_extended.jl
```

ngspice's adaptive steps, Amber's fixed-step integration, and output retention
still differ. Amber retains every node (8.8 MB at 1,000 loads/1,001 times), while
ngspice prints one load. This investigation does not establish which simulator
wins at an identical error target for all nonlinear circuits. AC validation
checks the complete first-node frequency response against ngspice; regression
tests additionally compare all states with the original SuiteSparse solve.

Focused compiler, operating-point, transient and small-signal tests pass.
The full `julia --project=Amber Amber/test/runtests.jl` suite also passes: 3,599/3,599
tests, 9 minutes 46.5 seconds (excluding the timing pause).
Raw after data: `extended_results_after.toml`.
