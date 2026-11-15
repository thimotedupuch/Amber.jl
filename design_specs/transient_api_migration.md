# Explicit transient controls

Transient simulations now use adaptive local error control, exact event handling,
and throwing failures by default. Neither output sampling nor a maximum step
implicitly selects fixed stepping. Existing numerical experiments that require
fixed stepping must opt in.

```julia
# Default: adapt integration steps and land on requested output timestamps.
r = transient(circuit, 0s => 1ms;
    saveat=10μs, max_step=20μs,
    solver=SolverOptions(reltol=1e-8),
    integration=IntegrationOptions(reltol=1e-5, voltage_abstol=10nV))

# Deliberate fixed-grid experiment; refine max_step independently for accuracy.
f = transient(circuit, 0s => 1ms; adaptive=false, max_step=1μs)
```

The same settings apply to `Transient(...)` descriptors, `simulate`, sweeps,
Monte Carlo, and replay. Descriptors validate their controls when constructed.
New serialization stores the Boolean stepping choice. When reading historical
serialized descriptors whose choice was `nothing`, decoding resolves their old
inference once and supplies the old effective fixed step where necessary;
new calls never use that inference. Historical failure policies are preserved.

## Migration

- `transient(...; reltol=..., abstol=..., maxiters=...)` now raises an actionable
  error. Use `solver=SolverOptions(reltol=..., current_abstol=...,
  voltage_abstol=..., state_abstol=..., max_newton_iterations=...)` for Newton
  convergence. Use `integration=IntegrationOptions(...)` for local integration
  error tolerances. The numerical domains must be chosen deliberately.
- `saveat=...` and `max_step=...` keep adaptive integration enabled. To preserve
  a prescribed-grid workload, add `adaptive=false, max_step=...`. Fixed mode
  requires an explicit `max_step`; `saveat` alone does not specify a solver step.
- Nondefault integration tolerances and a nonzero adaptive `min_step` are rejected
  with fixed stepping. `IntegrationOptions(max_steps=...)` still limits attempted
  steps in both modes. An adaptive `min_step` must not exceed the effective
  `max_step`; the initial step respects that bound too (required output/event
  boundaries may shorten individual steps). Newton tolerances still apply to
  every implicit solve.
- `saveat` specifies retained timestamps. The solver lands on those timestamps;
  they can shorten steps, but do not modify the configured `max_step`. This is
  not dense-output interpolation. Waveform/switch events and the final stop may
  shorten adaptive or prescribed-grid steps too.
- Exact `Step`/`Pulse` and switch events are now enabled by default. Explicitly
  pass `event_mode=nothing` to disable them. Finite edges still need resolution.
- Failed integration throws `ConvergenceError`. Explicitly request
  `failure_policy=:return_partial` when an incomplete result is useful, and
  check its convergence flag and actual stop before consuming measurements.

Results expose `:stepping_mode`, `:local_error_control`, `:nonlinear_tolerances`,
`:integration_tolerances`, `:maximum_step`, and `:sampling_policy`. Fixed runs
report `nothing` for `:integration_tolerances` and `:error_estimates`; zeros would
incorrectly suggest measured integration accuracy. Adaptive estimates are
normalized local error indicators, not global error bounds or a substitute for
independent refinement.

Historical ngspice comparison benchmarks have explicit fixed mode so their
workloads remain reproducible. PSS shooting explicitly keeps its deterministic
mesh and translates its own nonlinear options before invoking transient.

State-only checkpoints retain the saved method and temperature and restart BDF
history at order one. Sampling, stepping, tolerances, and failure policy come
from the `resume_transient` call and its normal transient defaults. Pass
`adaptive=false, max_step=...` explicitly to resume a prescribed-grid experiment.

## Validation

The full repository run passed 3,657 checks and exposed two obsolete test
assumptions in results/display tests: fixed-grid-only metadata and implicit
partial results. After migrating those tests, the affected suites pass 141/141.
The final numerical-control suite passes 67/67, including three additional
step-bound checks. This covers 3,685 distinct checks across the full run and
scoped reruns. The practical RC and nonlinear rectifier example scripts both
complete successfully. `git diff --check` passes.
