# Testing

Run the package suite from the repository root:

```sh
julia --project=. test/runtests.jl
```

Build the documentation, including executable examples and export coverage:

```sh
julia --project=docs docs/make.jl
```

Tests are layered. Unit tests cover local model behavior. Structural tests cover compilation, sparse patterns, serialization, and typed failures. Analysis tests cover complete solver workflows. `test/verification` compares carefully selected circuits with independent mathematics and checks refinement and conservation.

Every numerical regression should state why its tolerance is appropriate. Prefer dimensionless relative error plus a physically meaningful absolute floor. For transient failures, retain the smallest circuit and the event/time-step settings that reproduce the behavior.

