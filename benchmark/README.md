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
