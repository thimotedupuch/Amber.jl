# Transient and distributed-line development

Implemented first increments for roadmap items 7, 9, and 10. No SPICE parsing or compatibility is introduced.

## Integration (9)

`transient(...; method=:trapezoidal)` uses conserving charge-form trapezoidal integration. Startup, waveform corners, and switch events use backward Euler, preventing old derivatives from crossing a discontinuity. Adaptive integration compares the second-order candidate against backward Euler; this conservative embedded estimate can require more steps than a dedicated third-order estimator. Existing BDF defaults are unchanged.

Stats now retain `accepted_step_sizes`, `error_estimates`, `rejected_step_sizes`, and `integration_method`. Error estimates are normalized embedded differences, not rigorous global error bounds; fixed-step runs record zero because an estimate is not computed. These arrays support a future AmberMakie integration diagnostics panel. Trapezoidal ringing remains possible on stiff systems; BDF is still appropriate there.

Validation: analytic RC decay refinement (second order including startup), adaptive RC decay, diagnostic array consistency, and the existing transient tests.

## Distributed lines (7)

`DistributedLine` describes uniform per-length RLGC parameters and physical length, with Unitful conversions. `line_abcd(line, frequency)` evaluates the exact distributed two-port chain matrix, including removable DC singularities. Tests cover lossless phase/impedance, reciprocity, DC series resistance, and invalid inputs.

This is an analytic frequency characterization API, not a new MNA transient device. The existing `transmission_line` remains the lumped ladder. Next steps are frequency assembly contracts for nonrational devices, delay/history contracts for transient integration, coupled conductors, and line workbenches. Extreme electrical lengths can overflow hyperbolic functions; a scattering representation is a future improvement.

## Restart (10)

`save_checkpoint(path, transient_result)` writes a portable schema-versioned TOML endpoint state with circuit fingerprints, method, time, and temperature. `resume_transient(circuit, path, stop; ...)` rejects changed topology/parameters and resumes from that state. The new run explicitly restarts at first order and reports `checkpoint_restart=:first_order`; it does not promise bitwise identity with uninterrupted BDF integration. Solver and integration options should be passed explicitly when resuming.

`transient(...; recorder=(time, state) -> ...)` invokes a caller-owned streaming callback at the initial state and each accepted endpoint. It receives a copy of the raw SI solver state, so callbacks can select columns and write to disk without corrupting integration history. Combine this with coarse `saveat` to retain only two internal state vectors and a small returned result. Exceptions in the callback propagate; the caller owns file lifetime. The callback is deliberately absent from serialized analysis descriptions.

Remaining: exact multistep/adaptive-history checkpoints, checkpointing during a running solve, named-observable streaming adapters, bounded-memory result readers, and progressive AmberMakie browsing. The current checkpoint contains all solver unknowns because restarting from selected observables is generally impossible.
