# Operating-point analysis

`operating_point` solves the nonlinear DC equilibrium. Capacitors contribute no DC current and inductors impose their DC constraint. Time-varying sources use their DC value.

```@example op
using Amber
c = Circuit(:diode_bias)
vdd = node!(c, :vdd)
anode = node!(c, :anode)
gnd = ground!(c)
add!(c, voltage_source(vdd, gnd; dc=5.0); name=:supply)
add!(c, resistor(vdd, anode; value=2.2kΩ); name=:bias)
add!(c, diode(anode, gnd); name=:d1)
observe!(c, voltage(anode))
r = operating_point(c)
(r.stats[:status], voltage(r, :anode)[1])
```

The solver uses scaled Newton iterations, sparse linear solves, source/gmin continuation, adaptive continuation-step subdivision, and a pseudo-transient fallback for regenerative folds. `r.stats[:rejected_continuation_steps]` records subdivisions caused by rejected homotopy steps, while `r.stats[:strategy]` reports the path that ultimately converged. A result carries status, warnings, provenance, and the values needed to evaluate registered observables. Inspect `validity_report(r)` even after convergence: mathematical convergence is not the same as physical model validity.

Failures raise structured exceptions rather than returning plausible-looking partial vectors. `explain_failure` turns those exceptions into a concise diagnosis; `explain` describes successful results.
