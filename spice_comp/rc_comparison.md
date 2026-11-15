# RC ladder comparison

Measured with Julia 1.13.1 (one thread) and the locked pixi ngspice 41 environment.
Reproduce from the repository root:

```
pixi install --manifest-path spice_comp/pixi.toml
julia --project=. benchmark/ngspice_rc.jl
```

Seconds, minimum of five warmed runs:

| Cells | Amber DC | ngspice DC process | Amber transient | ngspice transient process |
| --- | ---: | ---: | ---: | ---: |
| 100 | 0.000212 | 0.00407 | 0.00336 | 0.00677 |
| 1,000 | 0.00198 | 0.01177 | 0.0380 | 0.0254 |
| 10,000 | 0.0243 | 0.0761 | 0.320 | 0.253 |

No large warmed performance gap was found in these cases. At larger sizes,
ngspice transient process time is about 1.3–1.5 times faster. These are not identical
integration workloads: Amber uses 100 fixed BDF2 steps; ngspice uses adaptive
integration with a 1 microsecond maximum step and a 1 picosecond source rise.
Both simulate a discharged 1 kohm / 1 nF ladder through 100 microseconds. The
script checks convergence, the known 1 V DC solution, and first-node transient
endpoint agreement within 1 mV. This is a basic correctness check, not a full
accuracy-equivalence study. ngspice saves two nodes as text; Amber retains every
node, which increasingly affects memory costs.

The original simulation benchmark warmed a two-cell circuit before timing a
100-cell circuit. Its apparent 61 ms transient fell to 3.3 ms after warming the
actual circuit shape. The benchmark now warms its measured shape. The comparison
reports first-call timing separately: the first 100-cell solve took about 2 s
in this run, and later first calls can share code compiled for earlier cases.
Do not interpret first-call minus warmed time as pure compilation time.

A warmed profile showed sparse LU numeric factorization as the main transient
cost. BDF coefficient roundoff prevents some numeric-factorization reuse; changing
coefficient semantics or accepting approximate matrix cache keys needs additional
accuracy work and is not justified as a fix for a large gap by these measurements.

The machine-readable result of the verification run is `rc_results.toml`.
