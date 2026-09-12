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


## CMOS bias exploration

```julia
using Amber, AmberMakie, CairoMakie
model = ChargeBasedMOSFET(width=8μm, length=2μm,
    channel_length_modulation=0.02)
view = mosfetview(model; vgs=range(0, 1.5; length=101), vds=[0.05, 0.6, 1.2])
h = workbench(view)
selectbias!(h; vgs=0.9, vds=1.2)
savefigure("cmos.png", h)
close(h)
```

The linked panels show transfer current, gm/ID versus current per total width,
intrinsic gain versus gm/ID, and gate capacitance. Bias controls inspect the
stored grid. PMOS grids use positive VSG/VSD (`kind=:pmos`); current curves use
magnitudes. `capacitanceplot` preserves the signs of the full terminal-charge
Jacobian rather than interpreting it as positive pairwise capacitances.

Model parameters, temperature and bias grids are retained in the view and export
metadata. The model is a bounded long-channel approximation; these plots do not
imply foundry calibration or short-channel accuracy.

## Measurement and rendering behavior

Transient signal selection updates the visible trace, cursor samples, interval
statistics and readout units together. Failed sweep samples break plotted lines.
Zero noise uses a linear density axis; log axes omit nonpositive values. Noise
budget floors scale with the physical PSD instead of dimensionless machine
epsilon. Logarithmic spectra require `include_dc=false`.

## API documentation

```@autodocs
Modules = [AmberMakie]
```

## CMOS circuit studies

`inverterview(sweep; output=:output)` extracts a sampled inverter transfer
curve. `inverterplot(fig[1,1], view)` displays the transfer and its derivative,
with the two unity-gain boundaries. Access `view.measurements` for `vil`, `vih`,
`voh`, `vol`, `nml`, `nmh`, and the switching point `vm` (all volts).
Here VOH is Vout(VIL), VOL is Vout(VIH); margins require a complete monotone
transfer with two crossings of gain −1. Failed sweeps remain gaps and invalidate
margins. The monotonicity check permits adjacent increases up to
`monotonic_atol=1e-9` V for solver roundoff. Increase sweep resolution to verify convergence near the transition.

```julia
transfer = inverterview(sweep(circuit, "VG.dc" => range(0, 1.8; length=401));
    output=:output)
inverterplot(fig[1, 1], transfer)

switching = switchingview(; loads=[5e-15, 20e-15, 80e-15], supplies=[1.5, 1.8, 2.1]) do load, vdd
    result = transient(make_inverter(; load, vdd), 0.0 => 210e-9;
        max_step=0.5e-9, method=:bdf2, event_mode=:exact)
    measurements = switchingmetrics(result; input=:input, output=:output,
        supply=:VDD, vdd, window=100e-9 => 200e-9)
    merge(measurements, (result=result,))
end
switchingplot(fig[2, 1], switching)
```

`switchingmetrics` pairs opposite input/output transitions at VDD/2, averaging
valid tPHL and tPLH edge delays. Missing or ambiguous responses make that delay
NaN. Energy integrates **delivered supply power**, including leakage, over the
explicit window. Choose a settled full cycle for energy per cycle; this is not
leakage-subtracted dynamic energy. Inspect individual delays in `phl`/`plh`,
and refine the transient step to verify measurement convergence.
`switchingview` retains callback exceptions in `failures`; missing points appear
as gaps. The callback can retain simulation results as shown above.

```julia
# Each group represents one temperature and geometry, with samples in SI units.
view = mismatchview([
    (temperature=300.0, width=1e-6, length=1e-6, result=mc_at_300),
    (temperature=350.0, width=1e-6, length=1e-6, result=mc_at_350),
]; quantity="Input offset", unit="V")
mismatchplot(fig[3, 1], view)
```

Groups may provide `samples` instead of a Monte Carlo `result`, with `nothing`,
`missing`, or nonfinite values marking failures. The plot shows empirical CDFs,
mean ± sample standard deviation, and valid/total counts for every condition.
Failed samples are excluded from statistics but retained in `view.groups`;
these are statistics conditional on successful samples, not yield estimates.
Additional metadata (seeds, model parameters, simulation records) stays available
in each group's `source`. No mismatch distribution is assumed by the plotting API.

Run `demo/cmos_studies.jl` in an environment containing Amber, AmberMakie and
CairoMakie for all three complete examples. It simulates a charge-based CMOS
inverter and measures input-referred offset of two NMOS devices with ideal
source/drain voltage clamps. The offset is the differential gate voltage needed
to equalize currents at a 1 V gate common mode and 1 V drain bias. Its independent
per-device threshold sigma of 3 mV/√(W·L in μm²) and relative mobility sigma of
1%/√(W·L in μm²) are illustrative assumptions, not calibrated process statistics.
The same random draws are reused across conditions. This fixture measures pair
offset; it does not include a complete amplifier's tail source, loads, or gain.
