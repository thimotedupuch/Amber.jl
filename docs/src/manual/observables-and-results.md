# Observables and results

Observables give semantic names to quantities derived from solver state. Register them before analysis:

```julia
observe!(c, voltage("vout", out, ground))
observe!(c, current("isupply", supply))
observe!(c, power("pload", load))
```

Voltage orientation follows node order; component current follows the component terminal convention; positive power means the component absorbs power. Device state and stored charge are available where the model exposes them.

Results support named access and analysis-specific helpers. `trace(result, "vout")` returns a sampled trace, while `result["vout"]` is convenient for stored observable access. `available_observables` is the authoritative list. `result_table` produces a Tables.jl-compatible representation.

Every result records `provenance`. Status, warnings, and `validity_report` belong in scientific reports alongside numbers. `compare` provides structured comparison between compatible results; it is not a replacement for physically justified tolerances.

