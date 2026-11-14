# Template symbolic compilation reuse

Compilation now creates one local connectivity/auxiliary-layout/stamp plan per
registered template, then instantiates it across instances. The previous second
hierarchy walk remapped terminals while allocating branch/state unknowns; the
new pass instantiates precomputed local offsets. Global unknown ordering and
stamp ordinals are unchanged. Numerical parameters and controlled-source
bindings are always freshly materialized/resolved.

Default compilation builds these local plans directly. An optional caller-owned
`SymbolicCompilationCache` reuses them across compilation calls. Cache equality
uses complete, length-delimited binary keys containing local connectivity and
device contract/stamp shape; numerical parameter values are excluded. Changes to
contract state or stamp layouts alter the key. No global slots, locators or
numerical coefficients are cached. A lock protects shared cache state, capacity
is bounded, and eviction cannot invalidate instantiated circuits.

## Historical comparison and regression investigation

The same benchmark driver was run against commit `ce5f105f` in an isolated jj
workspace and against this implementation. Both use Julia 1.13.1, CPU
`raptorlake`, one Julia thread, and 20 warmed samples. Allocation debt is collected
before each group; all per-sample times are retained. Other development activity
on the machine limits statistical claims. These are compilation timings, not
whole-simulation speedups.

Median time in microseconds, minimum allocated bytes:

| Instances | Historical | Local reuse | Persistent cache | Historical bytes | Local bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 52.90 | 55.51 | 59.96 | 45056 | 40432 |
| 16 | 295.65 | 254.01 | 253.38 | 212520 | 135416 |
| 128 | 2486.26 | 1483.60 | 1503.21 | 1430192 | 811904 |
| 512 | 8788.62 | 5840.95 | 5832.13 | 5670016 | 3208720 |

The first prototype regressed the one-instance case materially: its generic
fingerprint serializer formatted every integer stamp coordinate. Binary key
encoding removed that formatting cost. The default path now avoids persistent
cache key generation entirely, because the template registry already deduplicates
templates within a design. The remaining small-design fixed plan-construction
overhead is visible above and is not presented as an improvement. Repeated
instances amortize local plans. Persistent-cache benefit is not established for
these tiny two-device templates; that option remains caller controlled.

Global CSC contribution sorting remains in place. This change reuses local
symbolic work, not full template-level Schur elimination or a new global sparse
construction algorithm.

## Validation

20 new cache/ownership/capacity/concurrency assertions pass, together with 139
existing compiler, optimization and device-reference assertions. Fresh parameter
values, source forcing, retained hierarchy, controlled-source bindings and the
original auxiliary-unknown order are covered. Read-only review found no concrete
correctness defects. `git diff --check` is clean.

- [Driver](../benchmark/template_plans.jl)
- [Historical samples](measurements/template_plans_baseline_ce5f105f.toml)
- [Current samples](measurements/template_plans_current.toml)
