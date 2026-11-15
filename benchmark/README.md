# Amber benchmarks

Run the one-million-device construction benchmark with:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.instantiate()'
julia --project=benchmark benchmark/construction.jl
```

`AMBER_BENCH_CELLS` controls the number of two-device cells. The default is
500,000 cells (one million primitive devices). Output is machine-readable TOML.

Run the streamed hierarchy compiler benchmark with:

```sh
julia --project=benchmark benchmark/compilation.jl
```

This measures the public hierarchy-native compiler. No flattened compatibility
graph is constructed.

Run the compiler pipeline benchmark from the repository root with:

```sh
AMBER_BENCH_CELLS=100 julia --project=. benchmark/compiler_pipeline.jl
```

It covers passive hierarchies, charge-based MOS networks, and several behavioral
kernel types. TOML output separates first-call Julia compilation time, warmed
circuit elaboration, residual/Jacobian evaluation, parameter updates, structural
analysis, and AC sweeps. First-call measurements are ordered within one process;
later cases can benefit from shared compiled code. Warm measurements report the
fastest of repeated samples and its allocated bytes. Compare end-to-end timings
as well as kernel timings; the constant matrices add workspace storage.

`compiler_comparison.jl` uses APIs available before these optimizations as well
as after them, and can run against another checkout using
`julia --project=/path/to/checkout benchmark/compiler_comparison.jl`. It measures
the same 100-cell passive and MOS circuits in both revisions; set
`AMBER_BENCH_CELLS` to change their size. The older line-search path assembles a
Jacobian, so its residual timing is the joint assembly timing. See
`design_specs/compiler_optimization_progress.md` for measured results and scope.

Compare DC operating points and RC ladder transients with the local ngspice:

```sh
pixi install --manifest-path spice_comp/pixi.toml
julia --project=. benchmark/ngspice_rc.jl
```

`AMBER_SPICE_CELLS=100,1000,10000` selects sizes. The comparison reports circuit
construction separately, the first transient call, and the fastest of five
same-circuit warm solves. ngspice measurements include process startup, parsing,
and text output; Amber solves retain all node values. See
`spice_comp/rc_comparison.md` for measured results and limitations.

Extend the ngspice comparison to diode-loaded DC/transient networks and RC AC sweeps:

```sh
julia --project=. benchmark/ngspice_extended.jl
```

`AMBER_SPICE_CELLS` selects comma-separated sizes (default `10,100,1000`). See
`spice_comp/extended_comparison.md` for methodology, limitations and results.
`AMBER_SPICE_KINDS=dc,transient,ac` selects analyses and `AMBER_SPICE_STEP`
sets the transient maximum timestep in seconds (default `1e-7`).


Batch many analyses into one ngspice process to distinguish startup savings from
persistent analysis throughput:

```sh
julia --project=. benchmark/ngspice_amber_wins.jl
```

`AMBER_SPICE_CELLS`, `AMBER_SPICE_KINDS`, `AMBER_SPICE_POINTS` and
`AMBER_SPICE_REPEATS` configure this experiment. See `spice_comp/amber_wins.md`
for measured favorable cases, cold-start caveats and reproduction commands.

Compare larger RC networks (up to 100,001 primitive devices by default):

```sh
AMBER_SPICE_TOPOLOGIES=path AMBER_SPICE_REPEATS=10 julia --project=. benchmark/ngspice_large.jl
AMBER_SPICE_TOPOLOGIES=bank AMBER_SPICE_CELLS=10000 AMBER_SPICE_REPEATS=10 julia --project=. benchmark/ngspice_large.jl
```

This batches equal numbers of analyses in both simulators, separates construction,
circuit compilation, and first analysis, and validates the AC response outside timing.
See `spice_comp/large_comparison.md` for results and scope.

Compare matched simplified Level-1 CMOS inverter banks or chains:

```sh
AMBER_SPICE_KINDS=dc,ac AMBER_SPICE_CELLS=1000,10000 AMBER_SPICE_REPEATS=10 julia --project=. benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_CELLS=1,100 julia --project=. benchmark/ngspice_cmos.jl
AMBER_SPICE_KINDS=transient AMBER_SPICE_TOPOLOGY=chain AMBER_SPICE_CELLS=10 AMBER_SPICE_REPEATS=1 julia --project=. benchmark/ngspice_cmos.jl
```

`AMBER_SPICE_STEP` controls the transient maximum step (default 62.5 ps), and
`AMBER_SPICE_STOP` controls duration (default 210 ns). See
`spice_comp/cmos_comparison.md` for model matching, accuracy and limitations.

Audit CMOS transient accuracy separately from runtime:

```sh
julia --project=. benchmark/ngspice_cmos_audit.jl
```

This compares all ten chain nodes using 17-digit ngspice traces, distinguishes
native-sample errors from reconstructed-curve errors, and checks 4 ps versus
2 ps reference refinement. It asserts convergence, ordered/finite data and full
rail switching. See `spice_comp/cmos_transient_audit.md` for corrected interpretation.

`benchmark/cmos_linear_solver_diagnostic.jl` is an isolated-process diagnostic
that temporarily substitutes dense solves in the private Newton method to measure
small-matrix overhead. It does not implement or change Amber's solver policy.
