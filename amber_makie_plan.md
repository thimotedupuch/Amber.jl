# AmberMakie: interactive visualization for analog electronics

## Vision

`AmberMakie.jl` is a separate Julia package that depends on Amber and Makie. It is
not an Amber extension, does not live in Amber's source tree, and does not make a
Makie backend a dependency of Amber.

The package should become the visual working environment for Amber: a place where
an engineer can inspect a circuit response, place measurement cursors, relate a
transient phenomenon to its spectrum, compare corners, understand stability and
noise, and export a figure without rebuilding the analysis by hand.

The goal is not merely to make `plot(result)` work. There are two equally important
layers:

1. **Composable recipes** for notebooks, scripts, publications, and custom Makie
   layouts.
2. **Electronics workbenches** that combine linked views, controls, measurements,
   diagnostics, and provenance into a coherent daily tool.

The first release should feel useful with five lines of code while remaining fully
programmable:

```julia
using Amber, AmberMakie, GLMakie

result = small_signal(Filter(), 10Hz => 10MHz; source=:Input)
workbench(result)
```

```julia
fig = Figure()
bodeplot(fig[1, 1], result; input=voltage(:input), output=voltage(:output))
noiseplot(fig[1, 2], noise_result)
fig
```

## Design principles

- **Electronics semantics first.** APIs speak about gain, phase, ports, harmonics,
  noise density, margins, poles, operating regions, and measurements—not generic
  `x` and `y` arrays.
- **One canonical API per concept.** Amber is early-stage; remove superseded APIs
  rather than accumulating aliases or deprecation shims.
- **No hidden simulation.** A plotting recipe consumes results. An interactive
  study may run Amber only through an explicit `explore(...)` API that displays its
  analysis and parameter controls before execution.
- **Backend independent.** AmberMakie depends on `Makie`, not `GLMakie`,
  `CairoMakie`, or `WGLMakie`. Users choose the backend. Cairo produces static
  output; GL and WGL enable interaction.
- **Returned handles are part of the API.** Every high-level function returns a
  typed handle containing the figure/layout, axes, plots, selection state,
  measurements, and cleanup function.
- **Reactive without global state.** Inputs, selections, cursors, and computed
  display data are local Observables. Event subscriptions are owned by the returned
  handle and can be disconnected deterministically.
- **Large data must remain interactive.** Display decimation never changes the
  underlying measurements or exported numerical values.
- **Publication quality is not a separate mode.** The same semantic plot should
  work interactively and export cleanly through CairoMakie.
- **Never conceal validity.** Failed points, extrapolation, transfer nulls,
  undersampling, unconverged PSS, and model warnings are visible in the plot and
  inspectable from the workbench.

## Package and repository structure

Create a new `AmberMakie.jl` repository with its own UUID, versioning, CI,
documentation, and release process.

```text
AmberMakie.jl/
├── Project.toml
├── src/
│   ├── AmberMakie.jl
│   ├── adapters.jl
│   ├── formatting.jl
│   ├── themes.jl
│   ├── recipes/
│   │   ├── transient.jl
│   │   ├── frequency.jl
│   │   ├── spectrum.jl
│   │   ├── noise.jl
│   │   ├── control.jl
│   │   ├── network.jl
│   │   └── statistics.jl
│   ├── interaction/
│   │   ├── cursors.jl
│   │   ├── selection.jl
│   │   ├── measurements.jl
│   │   └── linking.jl
│   ├── workbenches/
│   │   ├── result.jl
│   │   ├── frequency.jl
│   │   ├── transient.jl
│   │   ├── stability.jl
│   │   ├── noise.jl
│   │   └── study.jl
│   └── export.jl
├── test/
├── docs/
└── benchmark/
```

Core dependencies:

- `Amber`
- `Makie`

Use Makie's public primitives for colors, geometry, layouts, and Observables where
possible. Do not add GraphMakie, DSP, DataFrames, Tables, or a backend to core
unless a concrete feature cannot be implemented cleanly without it. CairoMakie is
a test/docs dependency; GLMakie and WGLMakie are exercised in optional CI jobs.

Pin a compatible Makie minor series initially. Makie's recipe compute pipeline is
still evolving, and its current documentation notes that dynamic recipe attribute
manipulation described there applies to Makie 0.24 and later.

## Architecture

### Semantic adapters

Recipes must not repeatedly rediscover how an Amber object should be displayed.
Introduce an internal, tested adapter layer that converts Amber results into
semantic display models:

- `TraceView`: axis values, complex/real trace, label, physical quantity, unit,
  warnings, and provenance.
- `FrequencyView`: frequency, complex response, magnitude convention, phase,
  input/output labels, and crossings.
- `SpectrumView`: bins, calibrated amplitude/PSD, fundamental, harmonic table, and
  noise bands.
- `NetworkView`: port labels, parameter kind, reference impedances, and matrix
  traces.
- `EnsembleView`: samples, failures, parameter values, yield predicate, and
  confidence data.

Adapters contain no Makie objects. Their numerical tests should therefore be fast,
deterministic, and backend-free.

### Recipes

Use full `Makie.@recipe` recipes when AmberMakie introduces a semantic plot type,
and narrow `convert_arguments` methods only where an Amber type naturally maps to
an existing Makie primitive. A conversion must always return a tuple, as required
by Makie's recipe pipeline.

Each full recipe defines documented attributes, inherits common attributes from an
AmberMakie theme, implements `preferred_axis_type` and
`preferred_axis_attributes`, and builds child plots in `Makie.plot!`. Dynamic
derived data should use the recipe `ComputeGraph` (`map!` or
`register_computation!`) rather than disconnected Observable chains.

Do not overload an undifferentiated `plot(::SimulationResult)` as the primary API:
the same result can legitimately represent voltage, current, power, gain, or
impedance. Provide explicit semantic functions and reserve `plot(result)` as a
small dispatcher that opens `workbench(result)` only if this remains unambiguous.

### Workbenches

Workbenches are ordinary Makie `Figure`/`GridLayout` compositions, not giant plot
recipes. They use Blocks such as `Menu`, `Toggle`, `Textbox`, `Slider`, and
`IntervalSlider`, plus Makie events for keyboard and pointer interaction.

```julia
handle = workbench(result; view=:auto)
handle.figure
handle.selection[]
handle.measurements
close(handle)
```

`WorkbenchHandle` owns:

- the `Figure` or target `GridPosition`;
- named axes and plot handles;
- selected traces and active measurement tool;
- cursor and interval Observables;
- warnings/provenance state;
- event subscription handles;
- asynchronous study task, if any;
- `close`/cleanup behavior.

No callback may retain a closed figure or simulation result.

## Public visualization API

### Universal trace and comparison plots

- `traceplot(position, result; signals, interval, transform=:identity)`
- `compareplot(position, results; signals, alignment=:strict)`
- `sweepplot(position, sweep; x, metric, failed=:mark)`
- `ensembleplot(position, monte_carlo; metric, predicate=nothing)`

Transient traces default to engineering-formatted time and physical units. Complex
traces require an explicit transform such as `:real`, `:magnitude`, or `:phase`.
Comparisons show deltas and tolerance bands, not only overlaid lines.

### Frequency and control plots

- `bodeplot(position, result_or_model; input, output, magnitude=:db)`
- `nyquistplot(position, response; critical_point=-1+0im)`
- `nicholsplot(position, response)`
- `polezeroplot(position, model)`
- `rootlocusplot(position, model, gains)`
- `marginplot(position, loop_gain_result)`
- `groupdelayplot(position, response)`

`bodeplot` creates linked magnitude and phase axes by default. It displays cutoff,
crossover, resonance, and margin markers when available. Phase unwrap state is a
visible control, not an implicit mutation. Nyquist plots preserve direction with
frequency-colored segments or sparse arrows and make encirclement of the critical
point inspectable.

### Spectrum and periodic plots

- `spectrumplot(position, spectrum_result; scale=:rms)`
- `harmonicplot(position, harmonic_result; orders=:all)`
- `spectrogramplot(position, transient_result; signal, window, overlap)`
- `pssplot(position, pss_result; cycles=1)`
- `orbitplot(position, pss_result; x, y)`

Spectrum cursors report bin frequency, calibrated amplitude, phase, PSD, and the
nearest harmonic or intermodulation product. Harmonic plots distinguish the
fundamental, harmonics, spurs, and integrated noise. PSS views show cycle closure
error and convergence status visibly.

### Noise plots

- `noiseplot(position, noise_result; referred=:output)`
- `noisecontributionplot(position, noise_result; top=10)`
- `integratednoiseplot(position, noise_result)`

An interval selection on the density plot updates integrated RMS noise live.
Contribution selection highlights the devices and frequency band responsible for
the displayed noise. Input-referred transfer nulls appear as invalid regions, not
enormous unqualified lines.

### Network and RF plots

- `networkplot(position, network_result; parameter=:s, element=(2, 1))`
- `smithplot(position, network_result; element=(1, 1))`
- `stabilitycircleplot(position, network_result)`
- `mixedmodeplot(position, network_result)`

Smith charts are native polar/complex-domain recipes with impedance/admittance
grids, reference impedance annotation, frequency direction, and cursor conversion
between reflection coefficient and normalized/physical impedance.

### Operating-point and diagnostic views

- `operatingpointplot(position, operating_point)`
- `diagnosticplot(position, circuit_or_result)`

These views do not attempt to draw the circuit. They provide a searchable
component/node browser, operating-point values, device regions, power, warnings,
convergence information, and links to relevant traces. Selecting an entry
highlights every displayed observable associated with it.

Automatic circuit or schematic rendering is outside AmberMakie's scope. Amber
contains electrical topology but not the geometric and semantic intent needed for
a readable schematic: coordinates, orientation, wire routing, functional groups,
preferred signal flow, and preserved visual hierarchy. Makie can render such a
description but cannot infer it reliably. A future separate project may visualize
explicit user-supplied schematic metadata; AmberMakie must not promise automatic
schematic generation from arbitrary circuit topology.

## The flagship daily workflow

### `workbench(result)`

Automatically chooses a domain-specific layout:

- transient: trace area, signal browser, interval measurements, spectrum-on-demand,
  warnings, and provenance;
- small signal: Bode, Nyquist, pole/zero context when a model is available,
  measurement table, and source/output selector;
- spectrum/harmonics: calibrated spectrum, harmonic table, metric cards, selected
  band integration, and source time window;
- network: matrix-element selector, Bode/Smith views, port/reference-impedance
  metadata, and stability quantities;
- PSS: orbit, last-cycle traces, convergence residual, Floquet multipliers, and
  spectrum;
- Monte Carlo: distribution, parameter correlation, failed samples, yield region,
  and replay metadata.

### Linked measurement tools

All workbenches share the same interaction grammar:

- click to place cursor A;
- Shift-click to place cursor B;
- show `Δx`, `Δy`, slope, frequency ratio, decades/octaves, and phase difference;
- drag an interval to measure RMS, mean, peak-to-peak, duty cycle, energy, band
  power, integrated noise, or settling behavior according to the axis semantics;
- hover to inspect exact underlying data rather than decimated display points;
- press `f` to fit selected data, `a` to reset axes, `l` to toggle legend, and
  Escape to cancel the current tool;
- synchronize vertical cursors across all time axes and frequency cursors across
  all frequency axes;
- click a legend item to isolate it; Shift-click to add/remove it from a comparison.

Interactions must be discoverable through a small help button and context toolbar;
keyboard shortcuts cannot be the only route.

### `explore`

Provide an explicit interactive parameter-study API in a later milestone:

```julia
handle = explore(
    circuit_builder,
    SmallSignal(10Hz => 10MHz; source=:Input);
    parameters=(R=(1kΩ, 100kΩ, :log), C=(1pF, 10nF, :log)),
    outputs=[voltage(:output)],
)
```

The control panel displays parameter names, units, current values, and analysis
settings. Changes are debounced; a newer request cancels or supersedes an older
one. Simulations run off the UI task, results are cached by circuit fingerprint and
analysis settings, errors appear in the panel, and the last valid result remains
visible but visibly stale. There is never an unbounded queue of simulations.

The user can pin a result as a comparison trace, restore nominal parameters, copy a
reproducible Julia expression, and export the selected study points.

## Formatting, themes, and accessibility

Implement a single engineering formatter used by ticks, cursors, tables, and
exports:

- SI prefixes from femto through tera;
- stable significant digits;
- units derived from the selected Amber observable;
- Hz rather than rad/s at public boundaries;
- degrees by default in electronics phase plots, while retaining radians in data;
- dB labels that state whether they represent amplitude, power, or a normalized
  quantity.

Ship `theme_amber_light()`, `theme_amber_dark()`, and
`theme_amber_publication()`. Themes define semantic colors—input, output, voltage,
current, power, warning, invalid, nominal, candidate—not fixed series indices.
Every palette must remain distinguishable under common color-vision deficiencies,
and line style/markers must supplement color in comparisons.

## Performance model

- Keep original result arrays as the source of truth.
- For long traces, draw a pixel-aware min/max envelope that preserves spikes and
  switching edges. Never use naive every-Nth-point sampling.
- Recompute decimation when axis limits or pixel width change, with debouncing.
- Use Makie's `datashader` only for genuinely dense ensembles, not ordinary traces.
- Cache derived views by result identity, observable, transform, and interval.
- Avoid creating one plot object per Monte Carlo sample or harmonic when a batched
  primitive is available.
- Benchmark first display, pan/zoom latency, cursor latency, update allocations,
  million-point traces, thousand-sample ensembles, and large S-parameter matrices.

## Export and reproducibility

- `savefigure(path, handle; backend=:current, include_metadata=true)` saves the
  figure and a sidecar TOML/JSON record containing Amber and AmberMakie versions,
  circuit fingerprint, analysis provenance, selected signals, axis limits,
  measurements, and theme.
- `reportfigure(result; template=:frequency|:transient|:noise|:stability)` produces
  a deterministic publication layout without opening an interactive window.
- `copyrecipe(handle)` returns the Julia expression needed to recreate the current
  semantic view.
- Static export must not include interactive-only controls or stale-data overlays.

## Delivery milestones

### M1 — Package foundation and first daily-use workbench

- Create the separate repository, CI, docs, backend-neutral dependency setup,
  semantic adapters, engineering formatter, themes, and typed handles.
- Implement `traceplot`, `bodeplot`, `spectrumplot`, `harmonicplot`, `noiseplot`,
  and `workbench` for transient, small-signal, spectrum, harmonic, and noise
  results.
- Implement linked A/B cursors, interval selection, exact-data inspection, warning
  badges, provenance panel, legends, and Cairo export.
- Acceptance demonstration: inspect an amplifier transient and AC result, measure
  slew/rise time and bandwidth/margin, inspect its distortion/noise, and export a
  report-quality figure without manually constructing axes.

### M2 — Control, PSS, and network/RF

- Add Nyquist, Nichols, pole-zero, root-locus, margin, group-delay, PSS/orbit,
  network matrix, Smith chart, and stability-circle views.
- Link frequency selection between Bode, Nyquist, Smith, and matrix views.
- Add operating-point and diagnostic selection linked to traces.

### M3 — Statistical and interactive studies

- Add sweep, Monte Carlo, yield, correlation, failure, and sample-replay views.
- Implement `explore` with debounced asynchronous simulation, cancellation,
  caching, pinned comparisons, reproducible-expression export, and stale-result
  signaling.

### M4 — Scale, polish, and publication

- Add pixel-aware trace envelopes, dense-ensemble rendering, spectrograms,
  annotations, report templates, accessibility audit, and performance budgets.
- Stabilize the public API only after workflows have been exercised on every Amber
  gallery example.

## Testing and quality gates

1. **Adapter tests:** exact axes, units, labels, complex transforms, warning
   propagation, matrix selection, and failure preservation without loading a
   rendering backend.
2. **Recipe tests:** expected child plots, attributes, axis preferences, update
   propagation, and absence of leaked subscriptions.
3. **Interaction tests:** cursor placement, linked axes, interval measurement,
   trace isolation, keyboard/pointer equivalence, cleanup, and asynchronous study
   cancellation.
4. **Reference images:** a small, intentional CairoMakie gallery with perceptual
   comparison tolerances. Numerical assertions remain primary so rendering changes
   do not create meaningless churn.
5. **Backend matrix:** CairoMakie headless on every CI run; GLMakie smoke tests on a
   supported runner; WGLMakie notebook smoke tests periodically.
6. **Performance gates:** million-point pan/update and large-ensemble benchmarks
   with recorded budgets; no regression accepted without an explicit decision.
7. **Documentation:** every exported symbol appears once in the manual, every
   workbench has a complete example, and gallery builds are part of CI.
8. **Amber compatibility:** test against Amber's supported release and its main
   branch. Because both projects are early-stage, update AmberMakie immediately for
   Amber API changes rather than carrying compatibility branches.

## Decisions for tomorrow's kickoff

- Start a new repository; do not add code or extension metadata to Amber.
- Depend on Makie core and Amber only; CairoMakie belongs in docs/tests.
- Target Makie 0.24+ and its recipe ComputeGraph API.
- Build recipes and the workbench together from M1; neither is postponed.
- Make `workbench(result)` the flagship entry point and explicit semantic plot
  functions the composable API.
- Use Amber's latest API only. No deprecated Amber names, old schema readers, or
  AmberMakie compatibility aliases.
- Keep plotting observational by default; simulation is allowed only through the
  explicit later `explore` workflow.
- Treat cursor measurements, warnings, provenance, units, accessibility, and large
  data behavior as release requirements, not polish.

## Makie references used by this plan

- [Recipes](https://docs.makie.org/stable/explanations/recipes): type conversion,
  full recipes, attributes, preferred axes, and the Makie 0.24+ ComputeGraph.
- [Observables](https://docs.makie.org/stable/explanations/observables): reactive
  values and update behavior.
- [Complex layouts](https://docs.makie.org/stable/tutorials/layout-tutorial):
  GridLayout and Blocks for workbenches.
- [Events](https://docs.makie.org/stable/explanations/events): keyboard, pointer,
  scroll, and priority/consumption behavior.
- [Backends](https://docs.makie.org/stable/explanations/backends/backends): backend
  separation and backend-specific capabilities.
