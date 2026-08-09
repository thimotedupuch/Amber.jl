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

## Control and RF

M2 adds Bode views for Amber linear responses and loop-gain results, plus
`nyquistplot`, `nicholsplot`, `polezeroplot`, `rootlocusplot`, `marginplot`, and
`groupdelayplot`. Periodic and RF workflows use `pssplot`, `orbitplot`,
`networkplot`, `smithplot`, `stabilitycircleplot`, and `mixedmodeplot`.

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
