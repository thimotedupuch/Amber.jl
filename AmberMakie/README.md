# AmberMakie

Backend-neutral Makie visualizations for [Amber](..). AmberMakie is a separate
Julia package and does not add Makie as a dependency of Amber.

```julia
using Amber, AmberMakie, CairoMakie

handle = bodeplot(Figure()[1, 1], result; input=voltage(:input), output=voltage(:output))
```

Available views cover transient, frequency, spectral, noise, periodic, RF,
control, statistical, and CMOS analyses. Semantic adapters preserve numerical
data and units; workbench handles link selections, measurements, warnings, and
provenance. Use an interactive Makie backend for mouse-driven exploration or
CairoMakie for headless PNG/SVG/PDF export.

## Measurements

Time/frequency workbenches provide linked A/B cursors. Click in an axis to place cursor A and
Shift-click to place cursor B. Readouts always snap to the original numerical data:

```julia
handle = workbench(spectrum_result)
handle.measurements[:cursors][]  # Δx, Δy, slope, ratio, decades, and octaves
handle.measurements[:interval][] # mean, RMS, peak-to-peak, integral, and energy

setcursor!(handle.cursors, :a, 1e3)
setinterval!(handle.cursors, 1e3 => 10e3)
close(handle)                    # disconnects all event subscriptions
```

Transient and PSS workbenches accept multiple Amber observables and provide a
domain-specific signal selector. Mixed voltage/current/power collections are
shown with per-trace units and can be selected programmatically:

```julia
handle = workbench(transient_result; signals=[:output, current(:V1)])
selectsignal!(handle, current(:V1))
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

Control analysis includes Bode views for Amber linear responses and loop-gain
results, plus
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


## CMOS characterization

Characterize the native charge-based MOS model on a reproducible bias grid,
then compose plots or open a dashboard:

```julia
using Amber, AmberMakie, CairoMakie
model = ChargeBasedMOSFET(width=8μm, length=2μm,
    channel_length_modulation=0.02)
view = mosfetview(model; vgs=range(0.0, 1.5; length=101),
    vds=[0.05, 0.6, 1.2], temperature=300)
handle = workbench(view)
selectbias!(handle; vgs=0.9, vds=1.2)
savefigure("cmos.png", handle)
close(handle)
```

The dashboard links transfer current, transconductance efficiency, intrinsic gain
versus gm/ID, and gate capacitance through one selected gate/drain bias. Moving
the slider or clicking a plot inspects stored data. `copyrecipe(handle)` retains
the model, grid and selection; exported metadata contains physical parameters.

- `mosfetplot(fig[1,1], view; scale=:log)` shows transfer-current families.
- `gmidplot(fig[1,1], view)` shows gm/|ID| versus |ID|/(W × multiplicity), in A/m.
- `mosfetplot(fig[1,1], view; quantity=:intrinsic_gain, x=:gm_over_id, scale=:log)` shows the gain/efficiency tradeoff.
- `mosfetplot(fig[1,1], output_view; x=:vds)` shows output characteristics. Construct `output_view` with a dense drain grid and a few gate voltages.
- `capacitanceplot(fig[1,1], view.points[i,j])` shows the **signed** terminal-charge Jacobian, in fF, with charge terminals as rows and voltage terminals as columns.

Use `kind=:pmos` for PMOS. Grid voltages are polarity-normalized VSG/VSD in that
case; current plots show magnitudes. Underlying operating points retain signed
currents. Zero/nonfinite values are omitted on logarithmic plots without changing
the stored data. These views inherit the model's documented long-channel limits.

The circuit-study helpers below cover inverter transfer/noise margins, switching
delay and energy versus load/supply, and offset or mismatch across temperature
and geometry. Other studies, such as current-mirror error, can compose the
existing transient, sweep, and statistical plots. These measurements require
circuit-level simulations; the transistor dashboard characterizes one device.

### CMOS circuit studies

Numerical `Amber.invertermetrics` and `Amber.switchingmetrics` require only
Amber. `switchingmetrics` is re-exported here for compatibility; loading both
packages refers to the same function. `inverterview` adapts the core measurements
for plotting, preserving the measurements and warnings.

Available helpers include:

- `inverterview` / `inverterplot`: DC transfer, differential gain, switching
  threshold, and unity-gain noise margins; accepts an Amber sweep or raw samples.
- `switchingmetrics`, `switchingview` / `switchingplot`: 50% propagation delays
  and integrated supply energy versus load and supply, with explicit windows.
- `mismatchview` / `mismatchplot`: offset or mismatch empirical distributions
  and mean ± standard deviation grouped by temperature and W/L, retaining failed
  samples, seeds, and caller-provided simulation records.

See [`demo/cmos_studies.jl`](demo/cmos_studies.jl) for runnable inverter and
seeded transistor-pair examples. The switching study retains refinement history
and requires less than 1% successive change in delays and energy, with a bounded
number of halvings. Statistical parameters are illustrative.

Switching energy includes leakage over the entire supplied window; choose a
settled full cycle for energy/cycle. Missing or ambiguous output crossings yield
`NaN` delays. Inverter views report warnings for unresolved noise-margin
crossings; retain those warnings and failed study points in exported results.

## Reproduce the rendering gallery

[`demo/generate.jl`](demo/generate.jl) renders the analysis gallery and CMOS bias
examples; [`demo/cmos_studies.jl`](demo/cmos_studies.jl) renders the circuit studies.
Run them in an environment containing Amber, AmberMakie, and CairoMakie. Set
`AMBERMAKIE_DEMO_OUTPUT` to choose an output directory. CairoMakie is a test/demo
backend dependency; the package itself remains backend-neutral.
