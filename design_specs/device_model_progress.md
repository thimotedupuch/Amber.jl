# Device model first increments

Implemented for roadmap items 1, 2, and 4:

- `TemperaturePolicy` defines nominal/ambient/absolute-instance/offset semantics,
  accepts Unitful kelvin inputs and rejects invalid resolved temperatures.
  `device_temperature(policy)` resolves absolute-instance precedence. This is
  currently an explicit analysis-input helper, not per-device kernel plumbing.
- `CompactModelCallback` and `compact_model_point` establish an optional Julia
  callback characterization contract for terminal currents, charges and their
  Jacobians, with shape, finiteness, conservation and reference-invariance checks.
  A callback can wrap an external library without SPICE syntax or compatibility.
  It is not yet a circuit primitive or a foreign-library loader.
- Behavioral amplifier dominant-pole slew and symmetric output current limits
  now affect residuals and Jacobians. Positive finite output resistance is
  required for finite current limiting; ideal zero resistance remains supported
  with unlimited output current. Infinite limits preserve previous equations. Nonzero saturation
  recovery is still rejected. Hard limit knees are nondifferentiable; AC/noise
  behavior at these knees is not qualified, and noise injection clipping is
  not yet modeled.

Validation: standalone `julia --project=. test/Devices/model_extensions.jl`
checks callback conservation/errors, temperature precedence, loaded-follower
current limiting and transient slew bounds. Existing hardening expectations
were updated for newly supported parameters. All 13 extension assertions and
all 7 existing device-reference assertions pass (including ideal-output AC/DC).

Next substantial steps: propagate per-instance resolved temperature through all
current/charge/noise kernels; implement and verify nominal-temperature parameter
scaling per device; add external callback stamping with arbitrary terminal/state
counts and sparse derivatives; characterize a real external compact model;
qualify limit-region AC/noise, supply currents and saturation recovery. These
remain work, not completed capabilities.
