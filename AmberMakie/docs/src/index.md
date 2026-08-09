# AmberMakie

AmberMakie provides backend-neutral, electronics-oriented Makie plots for Amber.

## Composable plots

The public API covers transient, frequency, spectrum, noise, control, PSS,
network/RF, sweep, and Monte Carlo results. Every plot returns a typed
`PlotHandle`; `workbench` returns a `WorkbenchHandle` that owns its cursors,
measurements, warnings, provenance, and callback cleanup.

## Interactive studies

`explore` creates parameter controls without running a hidden simulation. Press
the displayed run button or call `runstudy!`. Results are cached and newer
parameter requests supersede older requests through one bounded worker task.
