# Bounded batch specialization

Small compiled collections retain typed tuples. Above the configurable
`specialization_limit` (default 8 batches), the parameter store uses a vector of
abstract compiled batches. Runtime dispatch crosses one batch boundary and then
executes the same typed device loop. The compiled-circuit type no longer encodes
every combination of callback/model parameter types. Distinct kernels still
need their own Julia compilation; this does not erase model diversity itself.

All assembly, storage, forcing, constant-cache and linearity paths support both
containers. Parameter updates preserve the selected container and old result
snapshots. Representation policy does not change physical fingerprints or
unknown/stamp ordering. Already compiled inputs remain idempotent; select a new
policy when compiling the original design.

## Regression investigation

The first erased loop passed view/scalar argument tuples through dynamic calls
for every batch. Allocations grew with batch count. A mutable execution context
now boxes those arguments once per pass, and the dispatch boundary passes two
existing references. This context type contains evaluation state, not circuit-wide
batch diversity. It currently has a fixed allocation cost; it is not claimed to
be allocation-free.

The driver runs each layout in a fresh process with increasing diversity 1, 8,
40. Each callback type has its own law/gradient type. Prior cases warm shared
kernels, so first-assembly JIT is sequence-dependent, not a full fresh-model
startup measurement. Storage setup precedes assembly timing. Fifty warmed samples
measure evaluation; first assembly JIT comes from Julia's `@timed` compiler
accounting. Design construction plus compilation is also recorded. Measurements
are local Julia 1.13.1 data, not universal speedup guarantees.

| Callback types | Tuple JIT s | Bounded JIT s | Tuple warm µs | Bounded warm µs | Tuple bytes | Bounded bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.454 | 0.723 | 0.18 | 2.57 | 0 | 448 |
| 8 | 1.423 | 1.049 | 34.82 | 5.50 | 5504 | 448 |
| 40 | 12.267 | 4.641 | 189.13 | 17.11 | 193488 | 448 |

Tiny collections are faster with tuples. Long heterogeneous tuples also encounter
Julia inference/code-generation limits; in this workload their warm allocations
and time increase sharply. The default boundary of eight total batches is a
conservative, configurable heuristic informed by this evidence, not an optimal
threshold for every Julia release or circuit. `specialization_limit=0` forces
the bounded path; a larger limit permits more tuple specialization.

## Validation

23 new assertions and 152 existing compiler/template/optimization assertions
pass. Tests compare residuals, Jacobians, storage, forcing, AC, noise, transient
results, parameter updates, snapshot ownership, and compiled type stability across
batch diversity. Read-only review found no concrete correctness defects.

- [Driver](../benchmark/bounded_specialization.jl)
- [Tuple measurements](measurements/specialization_tuple.toml)
- [Bounded measurements](measurements/specialization_bounded.toml)
