# Architecture

Amber is organized as a pipeline:

```text
CircuitDesign → hierarchy validation → streamed batch compilation → equation assembly → solver → result layer
```

`Core` owns names, paths, templates, serialization, typed unknown/equation layouts, device batches, and compilation. `Devices` defines models and residual/Jacobian contributions. `Solvers` implements operating-point, transient, AC, and noise algorithms. `Analysis` provides descriptors, sweeps, Monte Carlo, and metrics. `Results` resolves hierarchy paths without reconstructing a flat object graph. `Diagnostics` supplies structural and numerical explanations.

Keep these boundaries when extending Amber. A device should describe physics, not choose a global time step. A solver should consume the assembled contract, not special-case user-facing component names. Results should preserve provenance instead of reaching back into mutable input objects.
