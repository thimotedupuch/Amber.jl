# Cases where warmed Amber wins

Julia 1.13.1, one thread, local pixi ngspice 41. Uses the AC path optimization
implemented during the preceding investigation. No additional solver changes.

## Dense frequency sweeps of small path-shaped circuits

Both simulators sweep identical 1 kohm / 1 nF RC ladders over 10,001 linearly
spaced frequencies, 10 Hz to 1 MHz. Each batch contains 20 complete sweeps.

| RC stages | Amber batch | ngspice batch | Amber speedup |
| --- | ---: | ---: | ---: |
| 1 | 28.83 ms | 134.15 ms | 4.65x |
| 2 | 39.43 ms | 146.11 ms | 3.71x |
| 5 | 77.86 ms | 161.08 ms | 2.07x |

This win persists when ngspice performs all sweeps in a single process. The
ngspice batch includes one extra warm analysis, parsing and startup; that extra
sweep accounts for 5%, not the observed 2–4.7x gap. No text waveform output is
produced in timed batches. Both simulators save every node/branch for each sweep
and discard the result before the next. ngspice destroys each plot. Amber runs
the complete analysis each time; it does not memoize the response.

Amber's pivoted tridiagonal solver handles these very small path-shaped matrices
without general sparse factorization overhead. The result measures complete
analysis APIs, including allocation and ngspice control interpretation, rather
than isolated factorization kernels.

Correctness: outside timing, compare every first-node complex response at every
frequency with ngspice (maximum absolute disagreement ~5.02e-7, consistent with
printed precision). The one-stage response additionally agrees with the analytical
transfer function `1/(1+j*2*pi*f*R*C)` to 1e-12.

First-call analysis in the fresh Julia process took 3.77 seconds for the first
case, versus 1.44 ms per sweep warmed. These are warm performance wins. For a
single cold invocation of this tiny problem, ngspice is much faster; amortizing
Julia's first-call cost can require hundreds of these sweeps. Later first calls
in the same process share compiled code and must not be treated as independent
cold starts. Circuit construction is outside Amber timings, while ngspice parsing
is inside its process timing (amortized over the batch).

Reproduce:

```sh
pixi install --manifest-path spice_comp/pixi.toml
AMBER_SPICE_CELLS=1,2,5 AMBER_SPICE_POINTS=10001 AMBER_SPICE_REPEATS=20 AMBER_SPICE_KINDS=ac julia --project=. benchmark/ngspice_amber_wins.jl
```

## Where the win disappears

A separate batch experiment uses 100 analyses per process and 501 AC frequencies:

| Analysis | Cells | Amber batch | ngspice batch | ngspice / Amber |
| --- | ---: | ---: | ---: | ---: |
| ac | 10 | 38.71 ms | 58.52 ms | 1.51x |
| ac | 100 | 299.70 ms | 334.29 ms | 1.12x |
| ac | 1000 | 3505.94 ms | 3457.09 ms | 0.99x |
| dc | 10 | 22.53 ms | 7.08 ms | 0.31x |
| dc | 100 | 125.11 ms | 18.94 ms | 0.15x |
| dc | 1000 | 1030.58 ms | 219.98 ms | 0.21x |

The earlier small-DC win against a fresh ngspice process does not survive batching.
ngspice may benefit from previous operating points in repeated DC commands, whereas
Amber's `operating_point` API starts afresh here. This is a useful workflow result,
not evidence that Amber's nonlinear solver is faster. At 1,000 RC cells, AC batch
performance is approximately equal. The default batch experiment is reproduced by
`julia --project=. benchmark/ngspice_amber_wins.jl`.

Likely favorable workloads (inferences, not all benchmarked here): long-lived Julia
sessions running many small structured frequency sweeps; parameter exploration
that preserves a path-shaped matrix; and Julia-native processing of the resulting
arrays without external data transfer. Actual parameter-changing sweeps and
end-to-end optimization loops need separate measurement. Arbitrary large meshes
or cold command-line invocations should not be assumed to share this advantage.

Raw data: `amber_wins_small_ac.toml`, `amber_wins_results.toml`.
