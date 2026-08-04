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

This measures the hierarchy-to-batch compiler directly, excluding the temporary
flat exact-solver compatibility bridge.
