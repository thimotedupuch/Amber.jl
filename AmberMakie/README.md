# AmberMakie

Backend-neutral Makie visualizations for [Amber](..). AmberMakie is a separate
Julia package and does not add Makie as a dependency of Amber.

```julia
using Amber, AmberMakie, CairoMakie

handle = bodeplot(Figure()[1, 1], result; input=voltage(:input), output=voltage(:output))
```

The initial implementation includes semantic adapters, engineering formatting,
accessible themes, transient traces, Bode plots, spectra, harmonics, noise-density
plots, and typed workbench handles.

## Measurements

Every workbench owns linked A/B cursors. Click in an axis to place cursor A and
Shift-click to place cursor B. Readouts always snap to the original numerical data:

```julia
handle = workbench(spectrum_result)
handle.measurements[:cursors][]  # Δx, Δy, slope, ratio, decades, and octaves
handle.measurements[:interval][] # mean, RMS, peak-to-peak, integral, and energy

setcursor!(handle.cursors, :a, 1e3)
setinterval!(handle.cursors, 1e3 => 10e3)
close(handle)                    # disconnects all event subscriptions
```

Warnings and Amber provenance snapshots are available as `handle.warnings` and
`handle.provenance` for workbench panels and export tooling.

Noise workbenches combine density, cumulative RMS, and ranked component
contributions. Their frequency-band control updates both the RMS metric and the
contribution ranking, while the shared A/B cursors remain linked across the
density and cumulative views:

```julia
handle = workbench(noise_result; referred=:output)
handle.measurements[:band_rms][]
handle.measurements[:contributions][]
```

`noisebudgetplot` adds a stacked frequency-dependent budget grouped by source,
component, or mechanism. The phase-noise workbench combines the same budget with
a live integration band, ranked phase contribution panel, and validity report.

`workbench(phase_noise_result; carrier_frequency=...)` provides a live
phase/jitter integration band. Periodic-noise results have a sideband workbench
with a shared offset-frequency cursor.

Transient results also support eye folding and numerical mask tests. A mask is a
predicate returning `true` for forbidden phase/value samples:

```julia
eye = eyediagramplot(fig[1, 1], transient_result;
    signal=:output, period=1 / bit_rate,
    mask=(ui, value) -> 0.8 < ui < 1.2 && abs(value) < minimum_opening)
eye.view.violations
```

Threshold-crossing analysis provides TIE, period jitter, cycle-to-cycle jitter,
histogram, and empirical bathtub views from the same transient record:

```julia
jitterplot(fig[1, 1], transient_result;
    signal=:clock, nominal_period=1 / clock_rate, kind=:bathtub)
```

## Control and RF

M2 adds Bode views for Amber linear responses and loop-gain results, plus
`nyquistplot`, `nicholsplot`, `polezeroplot`, `rootlocusplot`, `marginplot`, and
`groupdelayplot`. Periodic and RF workflows use `pssplot`, `orbitplot`,
`networkplot`, `smithplot`, `stabilitycircleplot`, and `mixedmodeplot`.

The network workbench links selectable S, Z, or Y matrix elements across
magnitude, phase, Smith, resistance, and reactance panels. All port pairs are
available; diagonal reflection terms additionally provide complex impedance and
admittance conversion readouts:

```julia
handle = workbench(network_result; element=(1, 1))
handle.measurements[:smith_a][]
```

Small-signal workbenches similarly link Bode and Nyquist views and accept
`inputs` and `outputs` collections for live domain selectors.

Every result workbench has a context toolbar. Its trace legend isolates a single
trace, **Show all** restores hidden traces, and **Help** displays view-specific
actions. The same behavior is scriptable and reconstructed by `copyrecipe`:

```julia
isolatetrace!(handle, "magnitude")
toggletrace!(handle, "phase")
showalltraces!(handle)
helptext(handle)
```

## Sweeps and studies

`sweepplot`, `ensembleplot`, and `correlationplot` retain and visibly distinguish
failed points. `explore` provides bounded asynchronous execution, superseding,
result caching, pinning, parameter controls, and explicit execution:

```julia
study = explore(
    values -> simulate(build_circuit(values), analysis);
    parameters=(R=(1e3, 100e3, :log), C=(1e-12, 10e-9, :log)),
)

runstudy!(study)
pin!(study)
close(study)
```

Monte Carlo workbenches combine the ensemble, failure summary, Spearman rank
correlation matrix, parameter scatter, metric cards, and a sample browser.
Clicking the histogram, correlation samples, or failure categories updates one
linked sample selection across all panels. Supplying the original circuit enables
reproducible replay and a visible comparison with the stored metric:

```julia
handle = workbench(monte_carlo_result; circuit, metric)
selectsample!(handle, 17)
comparison = replay_sample!(handle)
```

PSS workbenches link Floquet diagnostics back to the stored orbit. Selecting a
multiplier chooses its dominant participating state; participation bars can also
be clicked directly to inspect that raw state trajectory with the shared time
cursor.

Operating-point workbenches provide searchable node/component browsing, linked
selection highlights, node voltages, device current/power and operating regions,
plus the solver continuation summary. Sweep post-processing includes
`transfercharacteristicplot` for derivatives and forward/reverse hysteresis, and
`sensitivityplot` for signed parameter rankings.

Further engineering views include two-parameter binned yield maps,
safe-operating-area trajectories with explicit voltage/current/power limits,
device power and efficiency dashboards, descriptor-system pole participation,
and 3D waterfall plots. SOA voltage is supplied explicitly as an Amber
observable or numerical trace, avoiding assumptions about multi-terminal device
voltage conventions.

Publication reports use structured measurement tables, analysis-specific notes,
and explicit provenance blocks. `savefigure` writes the same measurements,
warnings, axis limits, and provenance to a TOML sidecar.
