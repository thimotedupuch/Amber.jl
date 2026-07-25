# Architecture

Amber is organized as a pipeline:

```text
Circuit IR → validation → compilation → equation assembly → solver → result layer
```

`Core` owns ports, units, circuit IR, serialization, equation indexing, and compilation. `Devices` defines models and residual/Jacobian contributions. `Solvers` implements operating-point, transient, AC, and noise algorithms. `Analysis` provides descriptors, sweeps, Monte Carlo, and metrics. `Results` turns raw states into named, inspectable artifacts. `Diagnostics` supplies structural and numerical explanations.

Keep these boundaries when extending Amber. A device should describe physics, not choose a global time step. A solver should consume the assembled contract, not special-case user-facing component names. Results should preserve provenance instead of reaching back into mutable input objects.

