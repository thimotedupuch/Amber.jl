# Reproducible numerical experiments

A reproducible circuit result requires more than a netlist. Preserve:

- the circuit and model parameters;
- Amber and Julia versions plus source revision;
- analysis interval, frequencies, tolerances, integration method, and save policy;
- random seed, variation definitions, and sample count;
- status, warnings, failures, and provenance.

Deterministic serialization makes model changes reviewable. Seeded Monte Carlo assigns draws independently of thread scheduling. `replay_sample` links an aggregate statistical result back to one concrete circuit trial.

Reproducibility is not correctness. Combine it with analytic limiting cases, conservation laws, refinement studies, and independent implementations where practical.

