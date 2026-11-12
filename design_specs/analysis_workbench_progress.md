# Analysis and workbench increments

These changes retain Amber's native Julia architecture and add no SPICE compatibility.

## Named specifications (roadmap 11)

`MeasurementSpec(:ripple, peak_to_peak(voltage(:out); window=1ms=>2ms);
upper=10mV)` wraps an existing or custom metric. `assess(spec, result)` retains
name, physical value, limits, status and reason. Inclusive limits preserve units;
nonfinite/missing values, incompatible dimensions and metric exceptions produce
`:unresolved`. Interrupts propagate. Lists reject duplicate names.

Existing metrics retain responsibility for window/crossing selection; no new,
inconsistent crossing convention is introduced. This increment does not yet
provide a specification UI, waveform failure highlights or study replay wiring.

## Quasi-static distortion (roadmap 6)

`quasistatic_distortion(x, y; bias)` fits a cubic DC transfer characteristic in
a scaled input coordinate. Coefficients retain physical units. `distortion_harmonics`
and `distortion_intermodulation` give peak single-tone harmonic and equal-tone
IM2/IM3 products through cubic order, retaining coefficient signs and the fit
residual. Combined input peaks must stay within the characterized bias radius.

This is explicitly a memoryless approximation: it does not implement general
frequency-dependent small-signal distortion, nonlinear stored-charge effects,
Volterra kernels or per-device attribution. Fit error is diagnostic, not an
accuracy certificate. Users should characterize a narrow bias interval and
repeat with a smaller interval and input amplitude. Two-tone frequencies must
avoid coincident products. Dynamic distortion remains future work.

## Convergence investigation (roadmap 12)

AmberMakie's `convergenceview(result)` reads stored Newton history, preserving
residual/update norms, damping, source scale and gmin. `convergenceplot` links
iteration axes across residual and damping/continuation panels. Logarithmic
display omits zero/nonfinite residuals without changing stored history. Empty
history is labeled. Inspection never reruns or mutates the circuit.

This is a diagnostic plot increment, not a full interactive failure workbench.
Device-row selection, transient rejected-step visualization and explicit rerun
controls remain future work.

## Integration

Core includes (after Metrics): Analysis/Specifications.jl,
Analysis/QuasiStaticDistortion.jl. Export MeasurementSpec,
MeasurementAssessment, assess, QuasiStaticDistortion, quasistatic_distortion,
distortion_harmonics, distortion_intermodulation. Root test include:
test/Analysis/specifications_and_distortion.jl. AmberMakie test include:
test/convergence.jl.

Core validation: 21 assertions pass, including physical-unit specification limits,
unresolved outcomes, exact cubic coefficients, linear limits, invalid domains,
and independent discrete Fourier projection of single- and two-tone signals.
The graphics test covers retained history, zero residuals, linked panel creation
and empty histories.
Graphics validation: 5 assertions pass with backend-neutral Makie figure and
axis construction. No rendered-image check was performed: CairoMakie is not
available in the active development environment (it is declared as a test extra).
