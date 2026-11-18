# Large-circuit comparison

Julia 1.13.1, one thread; local pixi ngspice 41. This extends the prior warmed
comparison without changing solver code. Both circuits use 1 kohm resistors and
1 nF capacitors. A path is a series resistor ladder with shunt capacitors. A bank
has independent RC loads sharing one ideal voltage source.

Each batch performs exactly ten complete analyses. Warm Amber results are the
minimum of three batches after first-analysis and exact-shape batch warm-up.
ngspice runs ten analyses in one process, destroys each plot, and is timed over
three process invocations (minimum). No extra ngspice warm analysis is included.
Both retain all node and branch unknowns per analysis, discard results between
analyses, and produce no text waveform output inside the timed batches.

## Results

Times below are batch times divided by ten, in milliseconds per analysis. AC
sweeps contain 101 linearly spaced points from 10 Hz to 1 MHz.

| Topology | Devices | Unknowns | Analysis | Amber warm | ngspice process/batch | ngspice / Amber |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| path | 20,001 | 10,002 | ac | 104.74 ms | 147.56 ms | 1.41x |
| path | 20,001 | 10,002 | dc | 19.87 ms | 10.63 ms | 0.53x |
| path | 100,001 | 50,002 | ac | 580.05 ms | 909.69 ms | 1.57x |
| path | 100,001 | 50,002 | dc | 138.12 ms | 62.86 ms | 0.46x |
| bank | 20,001 | 10,002 | ac | 484.79 ms | 208.31 ms | 0.43x |
| bank | 20,001 | 10,002 | dc | 48.28 ms | 89.13 ms | 1.85x |

Amber wins the 100,001-device ladder AC comparison by about 1.57x. The matrix
has 50,002 unknowns, so this is not a tiny-matrix result. Its automatic connected
path solver uses pivoted tridiagonal LU at each frequency. The same advantage
does not extend to all large circuit matrices: at 20,001 devices, ngspice wins
the bank AC comparison by about 2.3x. Amber wins bank DC by about 1.8x; a separate
DC correctness rerun confirms this (50.2 ms versus 89.8 ms per analysis).
ngspice wins ladder DC. Device count alone does not predict the winner.

## Compilation, memory, and accuracy

Circuit construction and Amber circuit compilation are reported separately and
excluded from solve timing. The first ladder case took 0.81 s to construct,
1.35 s to compile, and 3.92 s for first AC analysis (which includes Julia code
compilation). The later 100,001-device case benefits from already compiled code;
its 0.60 s first analysis is not an independent cold-start measurement.
ngspice timing includes startup and parsing once per ten analyses. Thus these
results show warm analysis throughput, not startup-free factorization kernels
or a complete cold construction-to-result comparison.

The 100,001-device ladder AC result retains approximately 101 MB including circuit
metadata; its voltage/current array alone is approximately 80.8 MB. A ten-analysis
batch allocates about 4.53 GB cumulatively, not simultaneously live. ngspice peak
memory was not measured, so this establishes no comparative memory advantage.

Every first-node AC response is checked against ngspice over the full frequency
grid, maximum absolute difference below 5e-7 at printed precision. The bank
response also matches the analytical RC transfer function to 1e-12. DC checks
verify all Amber node voltages against the known 1 V solution. The updated
benchmark also checks ngspice first/last DC nodes; the separate 10,000-cell rerun
passes those checks for both topologies. This does not validate every AC internal
node independently; prior path-solver regression tests compare all states with
SuiteSparse on smaller circuits.

The test circuits are large synthetic passive networks. These measurements do
not establish an Amber advantage for large nonlinear transistor circuits,
dense meshes, or parasitic networks with different connectivity.

## Reproduce

```sh
pixi install --manifest-path spice_comp/pixi.toml
AMBER_SPICE_TOPOLOGIES=path AMBER_SPICE_REPEATS=10 julia --project=Amber benchmark/ngspice_large.jl
AMBER_SPICE_TOPOLOGIES=bank AMBER_SPICE_CELLS=10000 AMBER_SPICE_REPEATS=10 julia --project=Amber benchmark/ngspice_large.jl
```

Raw data: `large_path_results.toml`, `large_bank_results.toml`, and
`large_dc_checked_results.toml`. The benchmark exposes `AMBER_SPICE_CELLS`,
`AMBER_SPICE_TOPOLOGIES`, `AMBER_SPICE_KINDS`, `AMBER_SPICE_POINTS`, and
`AMBER_SPICE_REPEATS`. No new solver changes were needed; the benchmark completed
with convergence/response checks and `git diff --check` passes.
