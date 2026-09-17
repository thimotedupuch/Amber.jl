---
name: simulate-with-amber
description: Model, simulate, analyze, validate, extend, and visualize analog circuits and continuous-time dynamical systems with the unregistered Amber.jl package and optional AmberMakie. Use for circuit construction or debugging; DC, transient, AC, noise, periodic, RF/network, control, sweep, Monte Carlo, spectral, timing, or CMOS characterization; plots and reproducible reports; and missing components or behavioral physical models implemented in Julia.
---

# Simulate with Amber

Turn a circuit question into a reproducible Julia program, numerical evidence, and a concise engineering report. Treat simulation as an experiment: state assumptions, validate the topology, inspect convergence, check the answer independently, and preserve enough information to rerun it.

## Follow this workflow

1. Translate the request into topology, component values and models, sources, initial conditions, requested analyses, measured quantities, ranges, accuracy, and deliverables.
2. Ask only for missing information that would materially change the circuit. Make ordinary engineering assumptions when safe and report them. Never invent foundry model parameters, hidden connectivity, safety limits, or measurement data.
3. Select or create a dedicated Julia project. Preserve existing `Project.toml`, `Manifest.toml`, `pixi.toml`, and user changes.
4. Install or activate Amber as described below. Add AmberMakie only when plots or an interactive workbench add value.
5. Write ordinary `.jl` files for the circuit and simulation. Keep the input model separate from disposable outputs when the task is substantial.
6. Run `check(circuit)` before expensive analyses. Resolve structural errors rather than suppressing them.
7. Run the smallest analysis that answers the question, inspect solver status and warnings, then add sensitivity or convergence runs proportional to the risk.
8. Compare against an analytic estimate, conservation law, limiting case, or a refined timestep/frequency grid.
9. Deliver the code, assumptions, numerical results with units, convergence evidence, checks, and model limitations. Include plots only as supporting evidence.

## Set up the environment safely

Amber and AmberMakie are not registered Julia packages. Install them from `https://github.com/thimotedupuch/Amber.jl`; Amber is the root package and AmberMakie is the optional `AmberMakie` subpackage. Amber is always required: it constructs and simulates circuits and owns the result types. AmberMakie only visualizes results produced by Amber; it is neither a standalone simulator nor an alternative to Amber. Always install Amber first, and install AmberMakie only when the task needs graphs or an interactive workbench.

### Choose the launcher

Inspect, in order:

```sh
command -v pixi
command -v julia
```

- If Pixi exists, prefer it even if Julia also exists. Use the project-local Juliaup setup below and verify the created runtime with `pixi run julia --version`; if Pixi cannot create or execute a Julia environment after ordinary troubleshooting, treat it as unavailable, preserve the diagnostic, and use an existing system Julia.
- If Pixi is absent but Julia exists, use Julia directly.
- If neither exists, do not download Julia, Pixi, an installer, or an arbitrary binary. Stop and ask the user to install Pixi, then resume after they confirm it is available.
- If a dependency command fails because network access is restricted, request the appropriate execution/network permission. Do not bypass the restriction.

### Preferred Pixi setup

Keep the runtime, Julia packages, and caches inside the simulation directory so users can remove the installation by deleting that directory. Work from that directory and set Pixi's cache location before running Pixi commands (repeat this export in each new shell):

```sh
export PIXI_CACHE_DIR="$PWD/.pixi-cache"
```

Reuse an existing `pixi.toml`, merging the dependency and tasks without overwriting unrelated settings. For a new Linux x86-64 workspace, create this `pixi.toml` (adapt `platforms` for another supported host):

```toml
[workspace]
channels = ["conda-forge"]
platforms = ["linux-64"]

[dependencies]
juliaup = "*"

[tasks.juliaup]
cmd = "juliaup"
env = { JULIAUP_DEPOT_PATH = "$PIXI_PROJECT_ROOT/.pixi/juliaup" }

[tasks.julia]
cmd = "julia"
env = { JULIAUP_DEPOT_PATH = "$PIXI_PROJECT_ROOT/.pixi/juliaup", JULIA_DEPOT_PATH = "$PIXI_PROJECT_ROOT/.pixi/julia-depot" }
```

Install Julia through the `juliaup` task; do not use `pixi add julia`. Use the `release` channel to install the latest stable Julia version:

```sh
pixi install
pixi run juliaup add release
pixi run juliaup default release
pixi run julia --version
```

Always invoke Julia and Juliaup through these tasks so their depots stay under `.pixi/`, including when installing packages or changing channels. The Juliaup default is local to this workspace's depot. Exclude `.pixi/` and `.pixi-cache/` from version control. A read-only global Pixi cache does not make Pixi unavailable: use the writable local cache above. If dependency resolution needs restricted network access, request permission before abandoning Pixi. When a local Amber checkout and a working system Julia already provide a fully offline path, the Julia/local-path fallback is acceptable.

Add Amber to the active Julia project:

```sh
pixi run julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/thimotedupuch/Amber.jl"); Pkg.instantiate()'
```

Only after Amber has been added, add AmberMakie when graphs are requested. Add CairoMakie as the rendering backend for headless or file-based plots:

```sh
pixi run julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/thimotedupuch/Amber.jl", subdir="AmberMakie"); Pkg.add("CairoMakie"); Pkg.instantiate()'
```

Run scripts as `pixi run julia --project=. simulate.jl`. Preserve `pixi.toml`, `pixi.lock`, `Project.toml`, and `Manifest.toml` with the result when reproducibility matters. Juliaup downloads Julia separately from Pixi's lockfile: record `pixi run julia --version` and use an exact Julia version instead of the `release` channel when an exact runtime is required.

To uninstall, delete the simulation directory after saving any wanted scripts and results. This removes its Pixi environment/cache, Juliaup runtime, and Julia package depot; the existing Pixi executable remains available for other projects.

### Julia-only fallback

Use the same active-project convention and a local package depot. From the simulation directory, set this in each new shell before running any Julia command:

```sh
export JULIA_DEPOT_PATH="$PWD/.pixi/julia-depot"
```

The existing system Julia runtime remains outside the directory, but Amber and its Julia dependencies are installed locally:

```sh
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/thimotedupuch/Amber.jl"); Pkg.instantiate()'
julia --project=. simulate.jl
```

Add plotting only when needed and only after the preceding Amber installation:

```sh
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/thimotedupuch/Amber.jl", subdir="AmberMakie"); Pkg.add("CairoMakie"); Pkg.instantiate()'
```

For a long-lived result, pin a known repository revision with `Pkg.add(url=URL, rev="commit-or-tag")`. If already working in an Amber checkout, do not fetch another copy: use `julia --project=.` for Amber itself, or develop the local paths into a separate simulation environment with `Pkg.develop(path="/path/to/Amber.jl")` and `Pkg.develop(path="/path/to/Amber.jl/AmberMakie")`.

## Understand Amber's model

Amber is an equation-oriented analog and multiphysics simulator written in Julia. A circuit definition elaborates into an immutable hierarchical `CircuitDesign`; `compile` lowers it to typed device batches, sparse residual/Jacobian structure, and reusable numerical workspaces. Analyses operate on that compiled representation and return structured results with provenance and diagnostics.

Use SI suffixes such as `10kΩ`, `47nF`, `3.3V`, `1MHz`, and `300K`. They are readable `Float64` scale multipliers, not dimension-checking quantities. Keep dimensional reasoning explicit and label reported values.

Amber provides:

- passive `resistor`, `conductance`, `capacitor`, and `inductor` elements;
- independent voltage/current sources with DC, AC, `Step`, `Sine`, or `Pulse` excitation;
- voltage- and current-controlled sources;
- junction diode, Gummel-Poon BJT, Level-1 and charge-based MOSFET, behavioral op-amp, and analog switch models;
- reusable resistor materials, passive packages, calibrated capacitor dielectrics, and Debye absorption branches (see below);
- analytic behavioral current and voltage sources;
- hierarchy, arrays, retained instance paths, named observations, fast parameter updates, tolerance metadata, deterministic persistence, and diagnostics;
- operating point, implicit BDF transient, small-signal, noise and transient-noise, periodic steady state/noise, phase noise, ports and network parameters, control/loop gain, sweeps, Monte Carlo, spectra, harmonics, timing, and frequency-domain metrics.

These models are useful engineering abstractions, not a promise of SPICE-deck compatibility or foundry-grade semiconductor accuracy. State which abstraction was used and its limits.

## Choose devices and CMOS models

Check the built-in catalog before writing a custom behavioral law. Available
constructors include `zener`, `schottky`, `led`, `photodiode`, `solar_cell`,
`njfet`, `pjfet`, `analog_multiplier`, `voltage_limiter`, `comparator`,
`voltage_controlled_resistor`, `varistor`, `thermistor`, `potentiometer`,
`ideal_transformer`, `bridge_rectifier`, `crystal`, and `transmission_line`.
Read `src/Devices/Catalog.jl` in the Amber checkout for signatures and terminal
order; `examples/18_device_catalog/circuit.jl` demonstrates their composition.

Catalog models have specific limits: comparators have no delay or hysteresis;
JFETs omit gate junctions and noise; thermistors evaluate a fixed supplied
temperature without self-heating. Transmission-line R/L/G/C values are totals,
split across lumped pi sections. Refine `sections` for the bandwidth of interest.
Catalog composites elaborate into named internal primitives; inspect `devices`
and `resolve` before choosing parameter-update paths or interpreting a wrapper's
current. Built-in catalog laws support serialization; arbitrary user closures do
not gain that support automatically.

Use `Level1MOSFET` for simple strong-inversion experiments. Choose
`ChargeBasedMOSFET` for continuous weak-to-strong inversion, geometry studies,
conserving terminal charges, and optional body junctions. Both work with
`nmos(drain, gate, source, bulk; model=...)` and `pmos(...)`.

```julia
model = ChargeBasedMOSFET(width=8μm, length=2μm,
    channel_length_modulation=0.02/V)
point = mosfet_operating_point(model, :nmos, 1.2V, 1V, 0V, 0V;
    temperature=300K)  # absolute drain, gate, source, bulk voltages
point.gm_over_id
point.intrinsic_gain
point.capacitance_matrix
```

For a solved circuit, use `mosfet_operating_point(op, :M1)` and
`terminal_charges(op, :M1)`. Geometry keywords on `nmos`/`pmos` create immutable
instance model copies; `with_parameters(compiled, "M1.width" => 12μm)` reuses
topology. Use `mosfet_operating_point` for continuous inversion characterization
instead of relying on categorical `region` labels.

The capacitance matrix is signed ∂Qᵢ/∂Vⱼ in drain/gate/source/bulk order, not
positive pairwise capacitors. `id` is channel current, whereas `currents.drain`
includes the body junction. Supply junction areas/perimeters explicitly; W/L
does not infer them. Defaults do not describe a fabrication process. The model
omits short-channel effects, self-heating, non-quasi-static transport, and
junction shot noise. Read `src/Devices/ChargeBasedMOSFET.jl` and
`test/Devices/charge_based_mosfet.jl` for equations, temperature laws, and
conservation checks. Refine the timestep when measuring nonlinear charge transfer;
BDF integrates terminal voltages rather than finite differences of charge.

## Choose passive materials and packages

Attach these models with `resistor(...; material=..., package=...)` or
`capacitor(...; dielectric=..., package=..., dielectric_absorption=...)`:

| Option | Available models |
| --- | --- |
| Resistor `material` | `ThinFilm`, `ThickFilm`, `MetalFilm`, `CarbonFilm`, `CarbonComposition`, `MetalFoil`, `Wirewound` |
| Passive `package` | `SMD0201`, `SMD0402`, `SMD0603`, `SMD0805`, `SMD1206`, `SMD1210`, `SMD2010`, `SMD2512`, `Axial`, `Radial`, `PassivePackage` |
| Capacitor `dielectric` | `C0G`, `X7R`, `X5R`, `Polypropylene`, `Polyester`, `PPS`, `Mica`, `AluminumElectrolytic`, `Tantalum` |
| Capacitor `dielectric_absorption` | `DebyeBranches` |

Choose explicit coefficients from the user's part data or state illustrative
assumptions. These names do not supply manufacturer-specific defaults; noise
coefficients, loss tangent, and package parasitics default to zero. SMD names
use imperial size codes. Equal parameter values give equal electrical behavior
across family names.

- Resistor packages use `series_inductance` and terminal
  `parallel_capacitance`; capacitor packages use series `esr` and `esl`.
  Fields for the other component kind are unused. Component-level capacitor
  `esr`/`esl` override package values, including explicit zero. `Wirewound`
  needs an explicit package inductance when that effect matters.
- Resistor materials provide excess current-noise PSD
  `coefficient * abs(I)^current_exponent * (reference_frequency/f)^frequency_exponent`
  in addition to thermal noise. Keywords are `excess_noise_coefficient`,
  `excess_current_exponent` (default 2), `excess_frequency_exponent` (1), and
  `excess_reference_frequency` (1 Hz). Nonzero `tc1`,
  `temperature_coefficient`, and `voltage_coefficient` are rejected.
- Nonzero dielectric `loss_tangent` requires a positive `reference_frequency`
  in Hz. It adds constant series `Rloss = loss_tangent/(2π*fref*Cnominal)` to
  ESR. Report this as a single-frequency calibration; it does not preserve
  loss tangent over a frequency sweep. If datasheet ESR already includes
  dielectric loss, use ESR alone to avoid double counting. The loss resistor
  participates in transient and thermal-noise analyses.
- Dielectric labels do not implement capacitor bias derating, temperature
  curves, aging, polarization, or voltage limits. Specify leakage through
  `leakage_resistance`. For absorption, `DebyeBranches(time_constants=[...],
  fractions=[...])` adds series RC branches with `Ci=Cnominal*fraction[i]`
  and `Ri=time_constant[i]/Ci`. Fractions are finite and nonnegative; time
  constants are finite and positive. Zero fractions add no branch.

All these model types support `model_parameters`, `with_model_parameter`,
serialization, and result provenance. Use `with_model_parameter` to create a
standalone model copy, then rebuild the circuit. `with_parameters` rejects
package/dielectric/absorption replacement. Changing only a compiled capacitor's
`value` leaves expanded loss and absorption elements fixed; rebuild to retain
the specified loss calibration or absorption fractions.

For examples and the full inventory, read the checkout's
[README passive-model reference](../../README.md#resistor-materials-passive-packages-and-capacitor-dielectrics).
For model-extension priorities and physical limits, read
[the material and package catalog](../../design_specs/passive_model_catalog.md).
When using an installed Amber package, find these files relative to its root
with `dirname(dirname(pathof(Amber)))`.

## Construct circuits correctly

Use `@circuit` for a reusable top-level design. Assign every important net and component to a Julia variable: the left-hand name becomes its stable lookup name.

```julia
using Amber

@circuit Divider(; supply=5V, top=2kΩ, bottom=1kΩ) begin
    gnd = ground()
    vin = node()
    out = node()
    Source = voltage_source(vin, gnd; dc=supply)
    Rtop = resistor(vin, out; value=top)
    Rbottom = resistor(out, gnd; value=bottom)
    observe(voltage(out); name=:output)
end

circuit = Divider()
issues = check(circuit)
isempty(issues) || error(join(string.(issues), "\n"))
println(describe(circuit))
```

A top-level circuit must contain exactly the intended electrical reference through `ground()`. Capacitors and current sources do not establish a DC path. A floating island, contradictory ideal voltage constraints, or an ideal-inductor loop can make the operating point singular; use `check`, `explain`, and solver diagnostics to find these problems.

Use `@subcircuit` for reusable hierarchy. Give it explicit ports, including a reference port, and instantiate it inside `@circuit`; do not call `ground()` inside the subcircuit. Use ordinary Julia parameters, loops, conditionals, helper functions, and collections in circuit definitions. For highly dynamic construction or libraries, prefer `CircuitBuilder`, `node!`, `ground!`, `add!`, `observe!`, `node_array!`, `instances!`, and `finish`.

Terminal order defines sign. For a two-terminal device created as `(p, n)`, voltage is `V(p)-V(n)`, positive current flows from the first terminal to the second, and positive power is absorbed under the passive sign convention. Confirm the convention before comparing a source-delivered power value.

Consequently, an independent voltage source supplying a passive load normally has negative `current(result, :Source)` and negative `power(result, :Source)`. Report Amber's signed value and, when useful, report the positive delivered quantity as its negation.

Inspect hierarchy and names with `describe`, `summary`, `devices`, `nets`, and `resolve`. Use full instance paths such as `"First.R1"` when a local name is ambiguous.

## Select and run analyses

### Operating point

Use the DC solution for bias, quiescent power, and nonlinear linearization:

```julia
op = operating_point(circuit)
@assert get(op.stats, :converged, false)
vout = only(voltage(op, :out))
isource = only(current(op, :Source))
psource = only(power(op, :Source))
println(report(op))
```

An operating-point call can return a result carrying nonconvergence information. Always inspect `result.stats[:converged]`, warnings, `validity_report(result)`, or `explain_failure(result)` before trusting values. Small-signal and noise analyses require a converged bias and normally fail explicitly if it is unavailable.

### Transient

Use implicit `:bdf1` or `:bdf2` integration. Resolve the fastest edge, pole, or switching interval with `max_step`; use `event_mode=:exact` for `Step`, `Pulse`, and switch discontinuities. Specify `saveat` when a uniform output grid is needed for spectra or comparison.

`saveat` controls output spacing independently of internal steps. The final
time is always included, so choose an interval divisible by `saveat` for a
uniform grid. Supplying `saveat` or `max_step` selects fixed stepping by default;
set `adaptive=true` explicitly for adaptive integration. Solver `reltol`/`abstol`
control Newton convergence; `IntegrationOptions` controls adaptive time error.

```julia
tr = transient(circuit, 0s => 5ms;
    initial=:discharged,
    method=:bdf2,
    max_step=1μs,
    saveat=1μs,
    event_mode=:exact,
    reltol=1e-6,
    abstol=1e-9)
@assert tr.stats[:converged]
t = tr.axis
y = voltage(tr, :out)
```

Use `initial_voltage(capacitor, value)` in the design for known capacitor precharge. There is no exported `initial_current` helper; inspect the installed transient API before prescribing other initial states. Avoid `initial=:discharged` when real bias or precharge matters. Repeat a key measurement with a smaller `max_step` or tighter tolerances.

### Small signal and control

Set an AC amplitude on an independent source and identify it with `source`:

```julia
ac = small_signal(circuit, 10Hz => 10MHz;
    source=:Source, points=301, scale=:log)
H = transfer(ac; input=voltage(:vin), output=voltage(:out))
fc = cutoff_frequencies(ac; input=voltage(:vin), output=voltage(:out))
```

The transfer endpoints are `Observable` objects such as `voltage(:vin)`, `voltage(:out)`, or `current(:R1)`, not bare symbols. Use `linearize` for a state-space/control representation and `loop_gain` for feedback stability when the topology and break point are meaningful.

### Noise, periodic, RF, and statistical analyses

- Use `noise(circuit, range; output=voltage(:out), input=:Source)` for device-source contributions, integrated noise, input referral, and noise figure.
- Use `transient_noise` when sampled nonlinear/noisy behavior matters.
- Use `periodic_steady_state` and `periodic_noise` for driven periodic systems. Oscillator `phase_noise` requires converged autonomous PSS (`autonomous=true`, `method=:bdf1`) with an isolated neutral Floquet mode; prescribed event timing is unsupported in autonomous PSS. Check settling and refine orbit sampling and sidebands.
- Define `Port` objects and use `port_response` for S, Y, Z, ABCD, or hybrid H network data (ABCD/H require two ports). Do not model a port as an accidental extra ideal clamp.
- Use `sweep` for deterministic parameter studies and `monte_carlo` for seeded Gaussian, log-normal, uniform, correlated, process, tolerance, or mismatch variation.
- Use `spectrum`, `harmonic_analysis`, and timing/frequency metrics only on a sufficiently settled, sampled, and resolved interval.

Compile once when only numerical parameters change:

```julia
compiled = compile(circuit)
tuned = with_parameters(compiled, Symbol("Rtop.value") => 2.2kΩ)
study = sweep(compiled, Symbol("Rtop.value") => range(1kΩ, 4kΩ; length=31);
    analysis=OperatingPoint(), metric=r -> only(voltage(r, :out)))
```

Topology-changing parameters require rebuilding. Each sweep point retains either its result or structured failure; report `successful(study)` and `failure_rate(study)` rather than silently dropping failures.

Use explicit seeds and preserve failures in Monte Carlo:

```julia
using Statistics

mc = monte_carlo(circuit;
    analysis=OperatingPoint(), samples=1000, seed=2026, parallel=true,
    variations=Dict(
        Symbol("Rtop.value") => Gaussian(2kΩ, 20Ω),
        Symbol("Rbottom.value") => Gaussian(1kΩ, 10Ω)),
    metric=r -> only(voltage(r, :out)))
println((mean=mean(mc), std=std(mc), failures=failure_rate(mc)))
```

Use `replay_sample` to reproduce an outlier and `save_monte_carlo` for a versioned record.

## Read results as data

Use `voltage`, `current`, `power`, `charge`, `state`, and `observation`. `result.axis` is the primary time/frequency axis; `frequencies(result)` is explicit for frequency results. The accessors return vectors, including one-element vectors for operating points.

Use `result_table(result)` for dependency-free rows, `provenance(result)` for inputs and solver metadata, `report(result)` for a concise summary, and `validity_report(result)` for model-domain warnings. Store important raw numbers in CSV/TOML or a Julia data artifact; a screenshot is not a result.

For operating-point, transient, and small-signal results, `report(result)` includes
solver and model-validity warnings; `report(result; detailed=true)` also includes
iteration/step histories. Select and label table columns with a named tuple:

```julia
rows = result_table(tr; signals=(output_V=voltage(:out), source_A=current(:Source)))
open("transient.csv", "w") do io
    println(io, join(string.(keys(first(rows))), ','))
    for row in rows
        println(io, join(values(row), ','))
    end
end
```

This simple numeric CSV recipe uses caller-chosen column labels without commas.
Named observations can also be selected, e.g. `signals=(output_V=:output,)`.

Validate every important answer with at least one of:

- a hand estimate such as divider ratio, RC corner, time constant, gain, or thermal-noise density;
- KCL, energy, or power balance under Amber's sign convention;
- a limiting case or symmetry check;
- timestep, tolerance, frequency-grid, or sample-count refinement;
- comparison with a datasheet, measured trace, or trusted reference model supplied by the user.

## Use AmberMakie for visualization

AmberMakie is Amber's optional visualization companion. Do all circuit construction and simulation with Amber first, then pass Amber result objects to AmberMakie recipes. Do not install or invoke AmberMakie for a simulation that does not need graphs. Use CairoMakie for deterministic PNG/SVG/PDF output in headless agent environments:

```julia
using Amber, AmberMakie, CairoMakie

CairoMakie.activate!()
set_theme!(theme_amber_light())

fig = Figure(size=(1000, 550))
traceplot(fig[1, 1], tr; signals=[voltage(:vin), voltage(:out), current(:R1)])
save("transient.png", fig)

bode = Figure(size=(1000, 600))
bodeplot(bode[1, 1], ac; input=voltage(:vin), output=voltage(:out))
save("bode.png", bode)
```

Use `spectrumplot`, `harmonicplot`, `noiseplot`, `integratednoiseplot`, `noisebudgetplot`, `networkplot`, `smithplot`, `operatingpointplot`, `diagnosticplot`, `sweepplot`, `ensembleplot`, `pssplot`, and `phasenoiseplot` for their corresponding result types. Use `workbench(result; ...)` for interactive exploration only when a display is available. Retain its handle and call `close(handle)` when finished. `savefigure(path, handle)` also writes reproducibility metadata where supported.

Do not infer exact values from pixels. Compute metrics from result arrays and use plots to communicate behavior.

### CMOS dashboards and circuit studies

Use `mosfetview` to evaluate a charge-based model on a bias grid, then
`mosfetplot`, `gmidplot`, `capacitanceplot`, or `workbench(view)` to inspect it:

```julia
view = mosfetview(model; vgs=range(0V, 1.5V; length=101),
    vds=[0.05V, 0.6V, 1.2V], temperature=300K)
handle = workbench(view)
selectbias!(handle; vgs=0.9V, vds=1.2V)
savefigure("mosfet.png", handle)
close(handle)
```

For `kind=:pmos`, grid biases mean positive VSG/VSD, while stored currents
remain signed. `gmidplot` uses |ID|/(width × multiplicity) in A/m. A dense gate
grid gives transfer curves; a dense drain grid gives output curves.

Use circuit simulations for circuit performance:

- `inverterview(sweep_result; output=:output)` and `inverterplot` extract DC
  transfer, differential gain, switching threshold, and unity-gain noise margins.
  Inspect warnings when the sweep does not resolve the required crossings.
- `switchingmetrics(tr; input=:input, output=:output, supply=:VDD, vdd=1.8V,
  window=100ns => 200ns)` measures 50% propagation delays and delivered supply
  energy. The result overload negates Amber's absorbed source power. Energy
  includes leakage over the entire window; select a settled full cycle for
  energy/cycle. Missing or ambiguous output crossings produce `NaN` delays.
- `switchingview(measure; loads, supplies)` calls a supplied simulation/metric
  function on a load/supply grid and retains exceptions in `failures`;
  `switchingplot` shows the measurements.
- `mismatchview(groups)` / `mismatchplot` summarize caller-supplied offset or
  mismatch samples by temperature and geometry. Retain seeds, failed samples,
  and simulation records; these helpers do not invent a process distribution.

Read `AmberMakie/demo/cmos_studies.jl` for complete inverter and seeded pair
studies, and `AmberMakie/README.md` for plotting signatures and interpretation.

### Interactive measurements and reproducible exports

With an interactive backend, result workbenches link A/B data cursors and
interval readouts. Use `setcursor!`, `setinterval!`, and `selectsignal!` for
scripted selection. Noise views provide integration bands and ranked source
budgets; network views provide matrix-element selection and Smith readouts.
Monte Carlo workbenches accept `circuit` and `metric` for `selectsample!` and
`replay_sample!`. `explore` / `runstudy!` support parameter controls, cached
runs, and `pin!` comparisons; close study handles when finished.

Use `eyediagramplot` and `jitterplot` for sampled eye masks, TIE, period jitter,
and cycle-to-cycle jitter. Compute these from adequately resolved records.
`reportfigure` builds publication reports, `savefigure` exports figures with
TOML measurement/provenance sidecars, and `copyrecipe` reconstructs supported
view settings. CairoMakie supports headless rendering; mouse-driven controls
need an interactive backend.

## Easy complete example: RC step and bandwidth

Save this as `simulate.jl` and run it through the selected launcher:

```julia
using Amber

@circuit RCLowPass(; R=10kΩ, C=10nF) begin
    gnd = ground()
    vin = node()
    out = node()
    Source = voltage_source(vin, gnd; dc=0V, ac=1V,
        waveform=Step(low=0V, high=1V, at=100μs, rise=1μs))
    R1 = resistor(vin, out; value=R)
    C1 = capacitor(out, gnd; value=C)
    observe(voltage(out); name=:output)
end

R, C = 10kΩ, 10nF
circuit = RCLowPass(; R, C)
isempty(check(circuit)) || error(explain(circuit))

ac = small_signal(circuit, 10Hz => 1MHz; source=:Source, points=301)
# Resolve the 1 us source rise with ten internal steps; save every 2 us.
tr = transient(circuit, 0s => 700μs; max_step=0.1μs, saveat=2μs,
    event_mode=:exact)
@assert ac.stats[:converged] && tr.stats[:converged]

expected_fc = 1 / (2π * R * C)
measured_fc = only(cutoff_frequencies(ac;
    input=voltage(:vin), output=voltage(:out)))
@assert isapprox(measured_fc, expected_fc; rtol=0.03)

# Exact response after a linear ramp, including its finite rise time.
τ, rise, start = R * C, 1μs, 100μs
after_rise = tr.axis .>= start + rise
expected = 1 .- (τ / rise) * (-expm1(-rise / τ)) .*
    exp.(-(tr.axis[after_rise] .- start .- rise) ./ τ)
@assert maximum(abs.(voltage(tr, :out)[after_rise] .- expected)) < 0.2mV

println((expected_corner_Hz=expected_fc,
    simulated_corner_Hz=measured_fc,
    final_output_V=observation(tr, :output)[end]))
```

## Advanced example: reusable hierarchy and yield

Prefer hierarchy to copied component blocks. A subcircuit's reference is an explicit port:

```julia
using Amber, Statistics

@subcircuit RCSection(input, output, reference; R=1kΩ, C=100nF) begin
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, reference; value=C)
end

@circuit TwoPole begin
    gnd = ground(); input = node(); middle = node(); output = node()
    Source = voltage_source(input, gnd; dc=0V, ac=1V)
    First = RCSection(input, middle, gnd; R=1kΩ, C=100nF)
    Second = RCSection(middle, output, gnd; R=2kΩ, C=47nF)
end

circuit = TwoPole()
isempty(check(circuit)) || error(explain(circuit))
ac = small_signal(circuit, 10Hz => 1MHz; source=:Source, points=501)

mc = monte_carlo(circuit; samples=2000, seed=42,
    analysis=SmallSignal([1kHz]; source=:Source),
    variations=Dict(
        Symbol("First.R1.value") => Gaussian(1kΩ, 10Ω),
        Symbol("Second.C1.value") => LogNormal(log(47nF), 0.03)),
    metric=r -> abs(only(transfer(r;
        input=voltage(:input), output=voltage(:output)))))

gain = transfer(ac; input=voltage(:input), output=voltage(:output))
at_1kHz = argmin(abs.(frequencies(ac) .- 1kHz))
println((nominal_gain_at_1kHz=abs(gain[at_1kHz]),
    yield=yield_rate(mc, gain -> gain >= 0.1),
    failures=failure_rate(mc)))
```

Increase the sample count for a final yield claim and report a confidence interval. Verify that each distribution represents the intended absolute, relative, process, or mismatch variation.

## Electrical engineering recipes

Use these standalone blocks for bridge sensitivity, rectifier ripple, and CMOS
inverter transfer tasks.
Run them through the selected launcher; adapt component values and models to
the requested circuit. Each includes numerical checks and explicit units.

### Strain-gauge bridge: DC sensitivity

A quarter-bridge uses one active 350 Ω strain gauge and three fixed resistors.
With gauge factor 2 and 500 microstrain, its fractional resistance change is
0.001. The differential output is negative for the terminal order below:
about −1.25 mV with 5 V excitation. This ideal example omits lead resistance,
resistor mismatch, self-heating, and amplifier loading.

```julia
using Amber

@circuit StrainBridge(; strain=500e-6, gauge_factor=2.0, R=350Ω) begin
    gnd = ground(); excitation = node(); sense = node(); reference = node()
    Supply = voltage_source(excitation, gnd; dc=5V)
    Gauge = resistor(excitation, sense; value=R * (1 + gauge_factor * strain))
    R2 = resistor(sense, gnd; value=R)
    R3 = resistor(excitation, reference; value=R)
    R4 = resistor(reference, gnd; value=R)
end

bridge = StrainBridge()
@assert isempty(check(bridge))
bias = operating_point(bridge)
@assert bias.stats[:converged]
vbridge = only(voltage(bias, :sense, :reference))
expected = 5V * (1 / (2 + 2.0 * 500e-6) - 1 / 2)
@assert isapprox(vbridge, expected; atol=1e-9)

# Change only the gauge resistance; retain the compiled topology.
strains = range(-1000e-6, 1000e-6; length=21)
study = sweep(compile(bridge), "Gauge.value" => 350Ω .* (1 .+ 2.0 .* strains);
    analysis=OperatingPoint(),
    metric=r -> only(voltage(r, :sense, :reference)))
@assert failure_rate(study) == 0
println((bridge_output_V=vbridge, strains=strains,
    bridge_outputs_V=study.metrics, failures=failure_rate(study)))
```

### Rectifier: startup and smoothing-capacitor ripple

This half-wave rectifier converts a 10 V peak, 50 Hz sine into a DC output.
Measure the last two cycles after startup, then compare the ripple with the
small-ripple estimate ΔV ≈ Iload / (f C). Half-wave rectification recharges
once per input cycle; a full-wave bridge would use twice the input frequency.

```julia
using Amber, Statistics

@circuit SmoothingRectifier(; C=470μF, R=1kΩ) begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd;
        waveform=Sine(amplitude=10V, frequency=50Hz))
    D1 = diode(input, output;
        model=JunctionDiode(saturation_current=2nA, ideality=1.7,
            series_resistance=120mΩ))
    C1 = capacitor(output, gnd; value=C, esr=180mΩ)
    Load = resistor(output, gnd; value=R)
end

rectifier = SmoothingRectifier()
@assert isempty(check(rectifier))
tr = transient(rectifier, 0s => 300ms; initial=:discharged,
    max_step=50μs, saveat=50μs, reltol=1e-6)
@assert tr.stats[:converged]
settled = (tr.axis .>= 260ms) .& (tr.axis .< 300ms)
vdc = mean(voltage(tr, :output)[settled])
ripple = peak_to_peak(voltage(:output); window=260ms => 300ms)(tr)
ripple_estimate = (vdc / 1kΩ) / (50Hz * 470μF)
@assert 0V < vdc < 10V
println((dc_output_V=vdc, ripple_Vpp=ripple,
    estimated_ripple_Vpp=ripple_estimate))
```

The estimate ignores diode conduction time and ESR, so it is a sanity check,
not an exact equality. Reduce `max_step` and compare successive late cycles
before relying on a ripple measurement. Increase `C` to explore the tradeoff
between ripple and charging-current peaks, using `current(tr, :D1)`.

### CMOS inverter: DC transfer characteristic

Sweep the input of a complementary MOS inverter from ground to its 5 V supply.
The NMOS bulk connects to ground and the PMOS bulk to the supply; transistor
terminals are ordered drain, gate, source, bulk. These illustrative Level-1
parameters describe an educational model, not a specific fabrication process.

```julia
using Amber

@circuit LogicInverter begin
    gnd = ground(); supply = node(); input = node(); output = node()
    VDD = voltage_source(supply, gnd; dc=5V)
    Input = voltage_source(input, gnd; dc=0V)
    PullDown = nmos(output, input, gnd, gnd;
        model=Level1MOSFET(threshold_voltage=0.7V,
            transconductance=2mA/V^2, channel_length_modulation=0.03/V))
    PullUp = pmos(output, input, supply, supply;
        model=Level1MOSFET(threshold_voltage=0.7V,
            transconductance=1mA/V^2, channel_length_modulation=0.03/V))
    Load = capacitor(output, gnd; value=20pF)
end

inverter = LogicInverter()
@assert isempty(check(inverter))
inputs = range(0V, 5V; length=101)
vtc = sweep(compile(inverter), "Input.dc" => inputs;
    analysis=OperatingPoint(), metric=r -> only(voltage(r, :output)))
@assert failure_rate(vtc) == 0
outputs = Float64.(vtc.metrics)
@assert outputs[1] > 4.9V       # low input gives high output
@assert outputs[end] < 0.1V     # high input gives low output
# Approximate switching point: the sampled point nearest Vout = Vin.
k = argmin(abs.(outputs .- inputs))
println((input_V=collect(inputs), output_V=outputs,
    switching_input_V=inputs[k], failures=failure_rate(vtc)))
```

Refine the input grid near the transition for a more precise switching point.
The capacitor is open at DC; switching delay requires a transient analysis
with a pulse input and resolved rise/fall times. Use `ChargeBasedMOSFET` when
continuous weak-inversion behavior and conserving terminal charges matter.

For bridge offset and tolerance studies, use
`examples/11_precision_bridge/monte_carlo.jl`; for a rectifier with diode charge,
leakage, and dielectric absorption, use `examples/02_diode_rectifier/circuit.jl`
in an Amber checkout. See `examples/12_cmos_inverter/analyses.jl` for
pulse-driven CMOS switching and propagation-delay measurements.

## Write arbitrary Julia around Amber

Amber circuit files are Julia programs, not a restricted netlist language. Define helper functions and structs; generate component arrays with loops; read user-supplied data; perform linear algebra and statistics; optimize parameters; calculate custom metrics; and write CSV/TOML summaries. Add Julia packages with `Pkg.add` only when they are genuinely needed and preserve the environment files.

A useful layout is:

```text
simulation/
├── pixi.toml and pixi.lock
├── Project.toml and Manifest.toml
├── circuit.jl        # parameters, models, topology
├── simulate.jl       # analyses, assertions, numeric export
├── plot.jl           # optional AmberMakie rendering
└── results/           # generated tables, reports, figures
```

Use `include("circuit.jl")` from the drivers. Keep analytical checks as `@assert` or tests. Inspect the installed version with `pathof(Amber)` and read its source/docstrings if an API differs; Amber is evolving, so do not guess an unverified method signature.

## Extend Amber when a component is missing

Choose the least invasive faithful representation.

### 1. Compose a subcircuit

First assemble the missing device from existing primitives: add ESR, leakage, package parasitics, controlled sources, switches, or several model sections. Expose physical parameters through an `@subcircuit`. This retains every standard solver, result accessor, sparse compilation, serialization, and diagnostic facility.

### 2. Use an analytic behavioral source

Use `behavioral_current_source` or `behavioral_voltage_source` for a constitutive relation controlled by up to four differential voltages. Supply both the value and its analytic voltage gradient; the gradient is part of Newton's Jacobian and directly affects convergence.

```julia
behavioral_current_source(((ctrlp, ctrln),), outp, outn;
    current=(v, t) -> tanh(v[1] / 25e-3),
    gradient=(v, t) -> (sech(v[1] / 25e-3)^2 / 25e-3, 0.0, 0.0, 0.0))
```

The current flows from `outp` to `outn`; the voltage source imposes `V(outp)-V(outn)`. Return a four-entry gradient tuple, padding unused controls with zeros. Derive and finite-difference-check the gradient over the operating domain. Smooth discontinuities when physically reasonable; a mathematically abrupt law can destabilize Newton iteration.

Map an arbitrary first-order ODE `x' = f(x,t)` into a circuit by representing each state `xᵢ` as the voltage on a 1 F capacitor to ground and driving it with current `-fᵢ(x,t)` from the state node to ground. Add a very large leakage resistor only to establish a DC reference, and initialize the capacitor. For example, `x'=-x` is:

```julia
@circuit Decay(; x0=1.0) begin
    gnd = ground(); x = node()
    Cx = capacitor(x, gnd; value=1.0)
    resistor(x, gnd; value=1e15)
    behavioral_current_source(((x, gnd),), x, gnd;
        current=(v, t) -> v[1],
        gradient=(v, t) -> (1.0, 0.0, 0.0, 0.0))
    initial_voltage(Cx, x0)
end
```

This pattern supports coupled thermal, mechanical, biological, and control states within the four-controls-per-source limit. Check scaling: ill-conditioned state magnitudes harm circuit solvers just as they harm generic ODE solvers.

Behavioral closures may not be portable through deterministic circuit serialization. Preserve their Julia source as the authoritative model.

### 3. Add a native primitive only when justified

Modify Amber's core only if the user requested a reusable package feature or composition/behavioral sources cannot express the required branches, dynamic states, noise, or observables. Develop a local clone; never edit an opaque package-cache copy.

Implement the device through the complete compiler contract:

1. Add the public constructor/model in `src/Devices/` and export/include it from `src/Amber.jl`.
2. Register the primitive for hierarchy elaboration in `src/Core/Hierarchy.jl`.
3. Define its `DeviceContract` in `src/Core/EquationGraph.jl`: terminal count, branch unknowns, dynamic states, DC paths, noise sources, and observables.
4. Add its residual/Jacobian sparsity shape and stamp-position emission in `src/Core/CompilerIR.jl`.
5. Implement its typed batch assembly and `_inplace_batch_supported`/`_linear_batch` traits in `src/Core/Workspace.jl`, using precomputed slots. Stamp residuals, exact Jacobians, and dynamic terms with consistent signs.
6. Extend result reconstruction for device current, power, charge, or state; model parameter replacement; noise inventory; diagnostics; and serialization wherever the device participates.
7. Test terminal orientation, DC I-V behavior, analytic Jacobians against finite differences, transient state evolution, AC linearization, noise, KCL/power conservation, hierarchy paths, parameter updates, persistence, and relevant physical references.
8. Run `julia --project=. -e 'using Pkg; Pkg.test()'` and targeted tests. Document model equations, parameter domains, temperature behavior, and limitations.

Read adjacent implementations before changing internals. Amber's performance comes from explicit device contracts, static sparse stamp shapes, batched assembly, and workspace reuse; bypassing one layer can produce plausible but wrong answers or silently disable an analysis.

## Report the outcome

End with:

- the interpreted circuit and every consequential assumption;
- the retained Julia files and exact run command;
- Amber/Julia revision or environment lock information;
- analysis ranges, timestep/grid, tolerances, initial conditions, temperature, random seed, and sample count;
- requested measurements with units and sign conventions;
- convergence, diagnostic, refinement, and independent-check results;
- failed sweep/Monte Carlo points rather than only successful samples;
- limitations of device models and any behavioral or custom extension;
- paths to tables and plots.

Never claim hardware safety, regulatory compliance, or silicon accuracy from simulation alone. Distinguish a solver-converged result from a validated physical model.
