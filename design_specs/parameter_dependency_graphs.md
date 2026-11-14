# Retained parameter dependency graphs

Physical elaboration now records local primitive/field formulas, not inferred
relationships between hidden names. Capacitor calibrated loss retains the exact
fixed ESR offset and reference-frequency formula; absorption branches retain
fraction/time-constant formulas. Roles certify complete physical expansion groups.
Local references bind to hierarchy-qualified compiled parameter locations.

The compiled graph validates unique writers, acyclicity, initial formula values
and expansion coverage. Topological ranks and outgoing adjacency schedule only
rules affected by changed sources. Updates operate on private batch copies and
copy each touched batch once. Derived targets are read-only, and all writes,
including propagated writes, respect structural rebuild guards. Changing a main
capacitance updates the associated resistor/capacitor children before fingerprints
are recomputed. Existing snapshots and independent instances remain unchanged.

## Serialization contract

Schema 4 persists explicit formulas, expansion roles and rebuild declarations.
The reader accepts schemas 3 and 4. Legacy or incomplete physical expansions do
not silently acquire update support: numerical changes require rebuilding when
complete source metadata is unavailable. The data format stores only validated
operation tags and finite numeric coefficients, not executable callbacks.

## Regressions found and fixed

Review exposed propagated writes bypassing structural guards and partial metadata
enabling stale children. Both have dedicated tests. Propagation now checks target
rebuild requirements, and missing required physical expansion roles block source
updates. Formula values are checked against initial target values at compilation.

Numerically absent loss expansions retain rebuild guards so a numerical-only
update cannot introduce a missing physical element. Calibrated formulas preserve
the original arithmetic and finite reference-frequency metadata even when an
intermediate frequency product overflows. Invalid/nonfinite or nonpositive
derived passive values are rejected transactionally.

## Costs

One Julia 1.13.1 run, warm medians of 30 samples, microseconds:

| Capacitors | Rules | Unrelated forcing update | Derived C update | Derived update bytes |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3 | 10.01 | 40.05 | 26304 |
| 16 | 48 | 13.38 | 194.71 | 111632 |
| 128 | 384 | 13.52 | 1282.14 | 767736 |

Unrelated forcing updates do not traverse every graph rule. Derived updates still
copy touched parameter batches and recompute their content fingerprints; that
cost grows with batch size even for a small affected subgraph. Persistent/chunked
parameter storage is not implemented. Derived C updates previously required a
rebuild, so this table is a cost study, not a historical speedup claim.

## Validation

50 new assertions and 502 existing serialization/passive/compiler assertions
pass. Tests cover tuple/bounded layouts, repeated and transitive updates, initial
consistency, copy-on-write ownership, readonly targets, cycles, structural guards,
partial/legacy snapshots, roundtrips, and independent hierarchical instances.

- [Driver](../benchmark/parameter_dependencies.jl)
- [Measurements](measurements/parameter_dependencies.toml)
