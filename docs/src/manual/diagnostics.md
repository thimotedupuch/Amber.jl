# Diagnostics and failure handling

Amber treats diagnosability as part of the numerical API.

1. `check(c)` finds structural problems before solving.
2. `describe(c)` summarizes nodes, components, observables, and model structure.
3. Results expose status, warnings, provenance, and validity information.
4. Typed exceptions distinguish validation, convergence, linear-solve, and serialization failures.

```@example diagnostics
using Amber
c = Circuit(:diagnostic_example)
n = node!(c, :floating)
ground!(c)
add!(c, resistor(n, n; value=1kΩ); name=:r)
try
    operating_point(c)
catch err
    explain_failure(err)
end
```

A convergence error is a symptom, not automatically a solver defect. Look first for floating nodes, contradictory ideal sources, impossible initial conditions, extreme scales, and operation outside model validity. When changing tolerances, record the change and demonstrate convergence under further refinement.
