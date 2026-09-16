# Amber.jl

Amber is a native Julia circuit and dynamical-system simulator. It combines a
Julia-native circuit language with retained hierarchy, a typed compiler IR,
sparse generalized modified nodal analysis (MNA), nonlinear and time-domain
solvers, noise analysis, control theory, statistical studies, and
reproducible result metadata.

There is no external SPICE process behind Amber. A circuit is an ordinary Julia
object, compilation produces an inspectable sparse numerical representation,
and analyses return Julia data that can be measured, transformed, serialized,
or passed directly to the rest of the Julia ecosystem.

Amber is currently an early-stage `0.1` package. It is useful for inspectable
analog simulation, research, education, model development, and workflows that
benefit from programmatic circuit generation. Read [Scope and model
boundaries](#scope-and-model-boundaries) before using it for sign-off work.

## What is in Amber?

| Area | Capabilities |
| --- | --- |
| Circuit construction | `@circuit`, reusable `@subcircuit` templates, programmatic `CircuitBuilder`, arrays, loops, conditionals, retained instance paths, named observations |
| Devices | R, G, C, L, independent and controlled sources, diodes, NPN BJTs, NMOS/PMOS, switches, behavioral op-amps, nonlinear behavioral sources |
| Extended devices | Zener, Schottky, LED, photodiode, solar cell, N/P JFET, thermistor, varistor, controlled resistor, potentiometer, multiplier, limiter, comparator, ideal transformer, diode bridge, crystal, lumped RLGC line |
| Physical details | resistor excess noise and material families, passive package parasitics, calibrated capacitor loss and dielectric absorption, diode depletion/diffusion charge, BJT charge, MOS gate capacitances, matched devices |
| Core analyses | operating point, BDF1/BDF2 transient, small-signal AC, parameter sweeps, periodic steady state |
| Noise | stationary frequency-domain noise, input-referred noise, contribution budgets, integrated noise, stochastic transient noise, cyclostationary periodic noise, oscillator phase noise |
| RF and control | multiport Z/Y/S/ABCD/H parameters, descriptor-system linearization, poles, zeros, stability, root locus, step/impulse response, bias-preserving loop gain and margins |
| Measurements | voltage/current/power/charge/state traces, transfer functions, bandwidth, delay, resonances, FFT spectra, THD, THD+N, SNR, SINAD, SFDR, ENOB, sampling and propagation metrics |
| Visualization (optional AmberMakie) | linked result workbenches, RF/control plots, eye and jitter views, CMOS bias dashboards, inverter noise margins, switching energy/delay, mismatch studies, figures with metadata |
| Studies and reproducibility | copy-on-write parameter overrides, Monte Carlo with independent/correlated/process/matched variation, sample replay, failure retention, provenance, stable TOML serialization |
| Diagnostics | structural validation, floating-net and ideal-constraint detection, hierarchy-aware lookup errors, dominant residual reporting, validity warnings |

## Installation

Amber requires Julia 1.10 or later. Until it is registered, install it directly
from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/thimotedupuch/Amber.jl")
```

For development, clone the repository and instantiate it:

```sh
git clone https://github.com/thimotedupuch/Amber.jl
cd Amber.jl
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## A five-minute tour

The `@circuit` form turns a function-like definition into a reusable,
immutable `CircuitDesign`. Names on the left-hand side become stable net and
device names.

```julia
using Amber

@circuit LowPass(; R=10kΩ, C=10nF) begin
    gnd  = ground()
    vin  = node()
    vout = node()

    Source = voltage_source(
        vin, gnd;
        dc=1V,
        ac=1V,
        waveform=Step(low=0V, high=1V, at=100μs, rise=1μs),
    )
    R1 = resistor(vin, vout; value=R)
    C1 = capacitor(vout, gnd; value=C)

    observe(voltage(vout); name=:output)
end

filter = LowPass()
```

Values such as `10kΩ`, `1V`, and `100μs` are plain SI-scaled Julia numbers.
The suffixes make circuit code readable without imposing a runtime units
dependency.

Validate before a long run, then choose an analysis:

```julia
isempty(check(filter))             # true: no structural errors
println(explain(filter))            # compact design and validation summary

op = operating_point(filter)
@assert voltage(op, :vout)[1] ≈ 1V

ac = small_signal(filter, 10Hz => 10MHz; source=:Source, points=301)
gain = transfer(ac; input=voltage(:vin), output=voltage(:vout))
corner = only(cutoff_frequencies(
    ac;
    input=voltage(:vin),
    output=voltage(:vout),
))

tran = transient(
    filter,
    0s => 1ms;
    initial=:discharged,
    max_step=2μs,
    event_mode=:exact,
)
vout = observation(tran, :output)   # the named observation
iin  = current(tran, :Source)
```

All result data is directly accessible. `result.axis` is time for transient
results and `frequencies(result)` is the AC grid. Traces are vectors; no
plotting package is required.

```julia
rows = result_table(tran)           # dependency-free Vector{NamedTuple}
meta = provenance(tran)             # circuit, parameters, analysis, warnings
summary = report(tran)               # concise analysis report
```

Use [AmberMakie](AmberMakie/) when interactive Makie workbenches, Bode plots,
Smith charts, spectra, noise budgets, or publication figures are wanted. It is
a separate package so the simulation core does not depend on a graphics stack.

## Electrical engineering examples

Each example below is self-contained. Save a block as `simulate.jl` and run
`julia --project=. simulate.jl` in an environment containing Amber.

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

For more detailed models, see the [precision bridge](examples/11_precision_bridge/circuit.jl),
[rectifier startup](examples/02_diode_rectifier/startup.jl), and
[CMOS inverter switching](examples/12_cmos_inverter/analyses.jl) examples.

## Building circuits

### The circuit DSL

`@circuit` supports ordinary Julia expressions, including loops and
conditionals. Assigning a primitive gives it a name; an unassigned primitive is
still part of the circuit but receives an automatic name.

```julia
@circuit ParallelBank(; branches=8, r=10kΩ) begin
    gnd = ground()
    input = node()
    output = node()

    Source = voltage_source(input, gnd; dc=1V)
    if branches > 0
        for _ in 1:branches
            resistor(input, output; value=r)
        end
    end

    Load = resistor(output, gnd; value=r)
    observe(voltage(output); name=:output)
end
```

Top-level circuit arguments are parameters: `LowPass(R=47kΩ)` builds the same
structure with a different value. Structural choices can be ordinary Julia
arguments too, as in `ParallelBank(branches=12)`.

### Reusable hierarchy

`@subcircuit` defines explicit ports and parameters. A subcircuit has no hidden
global ground; reference and supply connections are explicit.

```julia
@subcircuit RCSection(input, output, reference; R=1kΩ, C=1nF) begin
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, reference; value=C)
    observe(voltage(output); name=:output)
end

@circuit TwoPoleFilter(; R=1kΩ, C=100nF) begin
    gnd = ground()
    input = node()
    middle = node()
    output = node()

    Source = voltage_source(input, gnd; dc=1V, ac=1V)
    First  = RCSection(input, middle, gnd; R=R, C=C)
    Second = RCSection(middle, output, gnd; R=R, C=C)
end

circuit = TwoPoleFilter()
describe(circuit)
resolve(circuit, "Second.R1")

result = small_signal(circuit, 10Hz => 100kHz; source=:Source)
voltage(result, "First.output")     # hierarchy-qualified port/net lookup
current(result, "Second.R1")
```

Hierarchy is retained in the design and elaboration index. It provides stable
paths for inspection, parameter updates, observations, reports, and errors,
while the solver works on one globally assembled sparse system.

### Programmatic generation

For generated topologies, use `CircuitBuilder`. Builder handles are ownership
checked, and `finish` closes the mutable construction phase by producing an
immutable design.

```julia
function rc_ladder(stages; R=1kΩ, C=10nF)
    builder = CircuitBuilder(:RCLadder)
    gnd = ground!(builder, :gnd)
    x = node_array!(builder, :x, 0:stages)

    add!(builder, voltage_source(x[0], gnd; dc=1V); name=:Source)
    for k in 1:stages
        add!(builder, resistor(x[k-1], x[k]; value=R); name=(:R, k))
        add!(builder, capacitor(x[k], gnd; value=C); name=(:C, k))
    end
    observe!(builder, voltage(x[stages]); name=:output)
    finish(builder)
end

ladder = rc_ladder(200)
summary(ladder)
devices(ladder; kind=:resistor, limit=5)
nets(ladder; limit=5)
```

`instances!` provides the same pattern for arrays of subcircuits with generated
names, connections, and parameter sets.

## Analyses and measurements

### DC operating point and nonlinear convergence

```julia
bias = operating_point(circuit; temperature=300K)
voltage(bias, :output)
current(bias, "Second.R1")
power(bias, "Second.R1")
```

Newton iterations use variable and row scaling, a backtracking line search, and
typed voltage/current/state tolerances. Operating-point solving starts with
source and temporary-`gmin` continuation and falls back to a pseudo-transient
path when necessary. Solver behavior is configurable:

```julia
options = SolverOptions(
    reltol=1e-8,
    voltage_abstol=1e-10,
    current_abstol=1e-13,
    max_newton_iterations=100,
    linear_solver=SuiteSparseLU(ordering=:amd, pivot_tolerance=0.1),
)

bias = operating_point(circuit; solver=options)
println(explain_failure(bias))
```

Nonconverged results retain statistics and dominant residual information rather
than erasing the attempted run.

### Transient and event-aware simulation

Amber implements native BDF1 and variable-step-coefficient BDF2 integration of
stored charge and flux. Nonlinear device charge history participates directly
in the discrete equations, preserving the BDF charge balance.
It supports fixed or adaptive stepping, operating-point or discharged initial
states, capacitor initial voltage, and exact insertion of `Step`/`Pulse`
waveform boundaries.

```julia
result = transient(
    circuit,
    0s => 5ms;
    method=:bdf2,
    max_step=1μs,
    event_mode=:exact,
)

peak_to_peak(voltage(:output); window=4ms => 5ms)(result)
overshoot(result, :output)
```

The built-in `Step`, `Sine`, and `Pulse` waveforms are callable Julia objects.
Exact-event mode also enables modeled switch charge injection at supported
prescribed control transitions.

### Small-signal, frequency metrics, and networks

Small-signal analysis finds the nonlinear bias point, evaluates the analytic
Jacobian and dynamic matrix there, and solves the complex descriptor system at
each frequency.

```julia
response = small_signal(circuit, 1Hz => 10MHz; source=:Source, points=501)
H = transfer(response; input=voltage(:input), output=voltage(:output))

db20(H)
phase(H; unwrap=true)
group_delay(frequencies(response), H)
passbands(frequencies(response), H)
resonances(frequencies(response), H)
```

Ports turn the same linearized machinery into multiport network data. A network
characterization circuit normally omits independent sources at its ports:

```julia
@circuit RCNetwork begin
    gnd = ground()
    input = node()
    output = node()
    R1 = resistor(input, output; value=1kΩ)
    C1 = capacitor(output, gnd; value=100nF)
    R2 = resistor(output, gnd; value=10kΩ)
end

network = port_response(
    RCNetwork(),
    10Hz => 1MHz;
    ports=[
        Port(:input, :gnd; reference_impedance=50Ω, name=:in),
        Port(:output, :gnd; reference_impedance=50Ω, name=:out),
    ],
)

Z = impedance(network)
Y = admittance(network)
Sparams = network_parameters(network, :s)
ABCD = network_parameters(network, :abcd)
renormalized = renormalize(network, 75Ω)
```

Z, Y, and S are available for any port count. ABCD and hybrid H conversion are
available for two-port networks.

### Descriptor-system control analysis

Amber can expose a linearized circuit as the descriptor system

```text
E x' = A x + B u
    y = C x + D u
```

This retains algebraic MNA constraints instead of forcing the circuit into an
ordinary state-space form.

```julia
model = linearize(circuit; inputs=:Source, outputs=voltage(:output))

dcgain(model)
poles(model)
transmission_zeros(model)
natural_frequencies(model)
damping_ratios(model)
isstable(model)

frequency = frequency_response(model, 10Hz => 1MHz; points=400)
margins = stability_margins(frequency)

step = step_response(model, 0s => 10ms; saveat=10μs)
rise_time(step)
settling_time(step)
root_locus(model, 0.0:0.1:2.0)
```

For a single-ended feedback loop, insert an ideal zero-volt voltage source
in series with the loop wire. `loop_gain` uses Tian's two-injection method,
including loading and reverse transmission. The wire must intersect all return
paths being studied. The returned convention is `1 + L` for return difference;
`loop_sensitivity` and `closed_loop_response` are the normalized quantities
`1/(1+L)` and `L/(1+L)`, not arbitrary circuit input/output transfers.

```julia
loop = loop_gain(
    circuit,
    10Hz => 10MHz;
    probe=VoltageLoopProbe(:Probe, voltage(:feedback_node)), # either endpoint, relative to ground
)

gain_margin(loop)
phase_margin(loop)
loop_sensitivity(loop)
closed_loop_response(loop)
```

Use `voltage(:endpoint, :reference)` for a separate reference node. A current
probe requires both a zero-DC current source from a wire endpoint to reference
and a zero-volt series sensing source:
`CurrentLoopProbe(:Injection, current(:Sense))`. A driven open-loop amplifier
transfer should be measured with `linearize` / `frequency_response`.

### Stationary and time-domain noise

Noise analysis uses adjoint propagation through the small-signal system. It
tracks each physical source, including correlations, so totals can be grouped
by component or mechanism.

```julia
noise_result = noise(
    circuit,
    10Hz => 1MHz;
    output=voltage(:output),
    input=:Source,
    points=301,
    temperature=300K,
)

output_density = noise_density(noise_result)          # V/√Hz here
input_density = input_referred_noise_density(noise_result)
rms_noise = integrated_noise(noise_result, 20Hz => 20kHz)
budget = noise_contributions(noise_result; mechanism=:thermal)
```

Available modeled mechanisms depend on the device: resistor/conductance thermal
noise, resistor excess noise, diode shot and flicker noise, BJT shot/base/
collector/flicker noise, MOS channel/gate/flicker noise with gate-channel
correlation, and behavioral op-amp input voltage/current noise.

For sampled stochastic trajectories, use a fixed grid and an explicit seed:

```julia
noisy = transient_noise(
    circuit,
    0s => 1ms;
    timestep=100ns,
    saveat=1μs,
    seed=0xA83E,
    low_frequency_cutoff=10Hz,
)
```

The same seed and configuration reproduce the same trajectory.

### Periodic steady state and oscillator noise

Shooting-based periodic steady state finds a circuit orbit and computes its
variational monodromy and Floquet multipliers.

```julia
pss = periodic_steady_state(
    driven_circuit;
    period=1ms,
    saveat=5μs,
    max_step=5μs,
)

orbit = pss.orbit
multipliers = floquet_multipliers(pss)

pn = periodic_noise(
    pss,
    10Hz => 100kHz;
    output=voltage(:output),
    sidebands=-5:5,
)
```

`periodic_noise` solves a harmonic-lifted cyclostationary system and reports
sideband and source contributions. For a converged autonomous oscillator PSS,
`phase_noise(pss, offsets; output=...)` additionally computes the adjoint phase
sensitivity, neutral Floquet mode, phase-diffusion coefficient, and single-
sideband phase noise in dBc/Hz.

### Spectral and time-domain measurements

Uniform transient records can be transformed and characterized without another
DSP package:

```julia
spectral = spectrum(result; signal=voltage(:output), window=:blackman_harris)
harmonics = harmonic_analysis(
    result;
    signal=voltage(:output),
    fundamental=:auto,
    harmonics=10,
    window=:hann,
)

thd(harmonics)
thdn(harmonics)
snr(harmonics)
sinad(harmonics)
sfdr(harmonics)
enob(harmonics)
crest_factor(spectral)
```

Nonuniform records are resampled and the operation is recorded in result
warnings. Other helpers include `sampling_metrics`, `propagation_delay`,
`compare`, `band_power`, `quality_factor`, and `notch_depth`.

## Charge-based CMOS characterization

`ChargeBasedMOSFET` adds continuous weak-to-strong inversion, explicit W/L and
multiplicity, conserving terminal charges, optional junctions, and temperature
laws. It is a bounded native long-channel model, not a foundry model.

```julia
mos = ChargeBasedMOSFET(width=8μm, length=2μm)
point = mosfet_operating_point(mos, :nmos, 1.2V, 1V, 0V, 0V)
point.gm_over_id
point.capacitance_matrix           # signed dQi/dVj: drain, gate, source, bulk
```

The same model works with `nmos`/`pmos`, compiled parameter updates, AC,
transient and noise. See the [model implementation](src/Devices/ChargeBasedMOSFET.jl) and
[verification tests](test/Devices/charge_based_mosfet.jl) for equations,
characterization sweeps, and conservation checks.

Instance geometry can be set at construction or updated on a compiled circuit:

```julia
@circuit MOSBias begin
    gnd = ground(); drain = node(); gate = node()
    VD = voltage_source(drain, gnd; dc=1.2V)
    VG = voltage_source(gate, gnd; dc=1V, ac=1V)
    M1 = nmos(drain, gate, gnd, gnd;
        model=ChargeBasedMOSFET(channel_length_modulation=0.02/V),
        width=8μm, length=2μm)
end

compiled_mos = compile(MOSBias())
wider = with_parameters(compiled_mos, "M1.width" => 12μm)
bias = operating_point(wider; temperature=320K)
characterization = mosfet_operating_point(bias, :M1)
charges = terminal_charges(bias, :M1)
```

Characterization includes signed `gm`, `gds`, `gmb`, terminal currents and
charges, inversion charges, `gm_over_id`, and intrinsic gain. `id` is channel
current; `currents.drain` includes the optional body junction. AC terminal
charges are phasors linearized at the DC bias. Junction areas and perimeters
must be supplied explicitly; they are not inferred from W/L.

## Visualization and CMOS studies with AmberMakie

Install the companion and a rendering backend into an environment that already
contains Amber:

```julia
using Pkg
Pkg.add(url="https://github.com/thimotedupuch/Amber.jl", subdir="AmberMakie")
Pkg.add("CairoMakie")
```

A transistor bias grid can be explored without constructing a circuit:

```julia
using Amber, AmberMakie, CairoMakie
CairoMakie.activate!()

view = mosfetview(ChargeBasedMOSFET(width=8μm, length=2μm,
    channel_length_modulation=0.02/V);
    vgs=range(0V, 1.5V; length=101), vds=[0.05V, 0.6V, 1.2V])
handle = workbench(view)
selectbias!(handle; vgs=0.9V, vds=1.2V)
savefigure("mosfet.png", handle)     # figure plus a TOML metadata sidecar
close(handle)
```

The dashboard links drain current, gm/ID, intrinsic gain, and gate capacitance.
`mosfetplot`, `gmidplot`, and `capacitanceplot` also compose into ordinary Makie
figures. For `kind=:pmos`, grid values are polarity-normalized VSG/VSD;
underlying operating points retain signed currents.

Circuit-level helpers cover:

| Workflow | API and measurements |
| --- | --- |
| Inverter DC transfer | `inverterview` / `inverterplot`: transfer curve, differential gain, switching threshold, unity-gain noise margins from a sweep or raw samples |
| Switching versus load and supply | `switchingmetrics`, `switchingview` / `switchingplot`: 50% propagation delays and delivered supply energy integrated over an explicit window |
| Offset and mismatch | `mismatchview` / `mismatchplot`: empirical distributions and mean ± standard deviation grouped by temperature and geometry, retaining failures, seeds, and supplied simulation records |

Switching energy includes leakage over the selected window; use a settled full
cycle when reporting energy per cycle. See the runnable
[CMOS studies demo](AmberMakie/demo/cmos_studies.jl) for inverter and seeded
transistor-pair simulations. Variation parameters in that demo are illustrative.

Other workbenches provide linked data cursors, noise integration bands, network
matrix selection and Smith readouts, Floquet participation, and Monte Carlo
sample browsing/replay. Eye diagrams and jitter views operate on transient
records. `explore` runs parameter studies with caching and pinned results;
`reportfigure`, `savefigure`, and `copyrecipe` support reproducible reporting.
Use an interactive Makie backend for mouse-driven exploration and CairoMakie
for headless exports. See the [AmberMakie guide](AmberMakie/README.md) for usage.

## Fast parameter studies

### Compile once, update values without changing topology

```julia
compiled = compile(circuit)
tuned = with_parameters(
    compiled,
    "First.R1.value" => 1.2kΩ,
    "Second.C1.value" => 82nF,
)

@assert tuned.topology === compiled.topology
```

Numerical overrides copy only affected parameter batches. The elaboration
index, sparse pattern, stamp locations, and unaffected batches are shared.
Parameters that change circuit structure—such as a package parasitic that adds
an internal element—are rejected and require rebuilding the design. This includes
BJT base resistance, switch clock feedthrough, and op-amp input capacitance and
bias current, even when changed by replacing the entire model. Capacitor value
changes also require rebuilding when dielectric loss or absorption derives
additional elements from that value.

Use this mechanism directly, or through a failure-aware sweep:

```julia
study = sweep(
    compiled,
    Symbol("First.R1.value") => range(500Ω, 2kΩ; length=31);
    analysis=SmallSignal([1kHz]),
    metric=r -> abs(voltage(r, :output)[1]),
)

successful(study)
failure_rate(study)
```

Every point retains its simulation or structured failure.

### Reproducible Monte Carlo

```julia
using Statistics

mc = monte_carlo(
    circuit;
    analysis=SmallSignal([1kHz]; source=:Source),
    samples=10_000,
    seed=2026,
    parallel=true,
    variations=Dict(
        Symbol("First.R1.value") => Gaussian(1kΩ, 10Ω),
        Symbol("Second.C1.value") => LogNormal(log(100nF), 0.03),
    ),
    metric=r -> abs(voltage(r, :output)[1]),
)

mean(mc)
std(mc)
quantile(mc, 0.99)
confidence_interval(mc)
yield_rate(mc, value -> value > 0.2)
yield_confidence_interval(mc, value -> value > 0.2)
failure_rate(mc)
```

Monte Carlo supports Gaussian, log-normal, and uniform variations; process
variation; covariance-based `CorrelatedVariation`; automatic numeric
`tolerance` parameters; and correlated mismatch for BJT `MatchedGroup`s. It
stores per-sample seeds, draws, outputs, and failures, making any sample
replayable:

```julia
replayed = replay_sample(mc, circuit, 17; metric=r -> abs(voltage(r, :output)[1]))
@assert replayed == sample_values(mc)[17]
```

## Results, observables, and persistence

Amber observables are explicit values:

```julia
voltage(:out)                  # node voltage
voltage(:outp, :outn)         # differential voltage
current(:Q1, :collector)      # device/terminal current
power(:Q1)                    # absorbed device power
charge(:D1)                   # stored device charge
state(:A1, :dominant_pole)    # internal dynamic state
```

The same observable can be declared in a circuit, evaluated from a result, used
as a transfer-function endpoint, or passed to a measurement. Hierarchical names
use strings such as `"FrontEnd.Q1"`; array paths use names such as
`"stage[4].R1"`.

Designs have deterministic, schema-versioned TOML serialization that preserves
their hierarchy:

```julia
save_circuit("filter.toml", circuit)
restored = load_circuit("filter.toml")
@assert compile(restored).fingerprint == compile(circuit).fingerprint

save_monte_carlo("offset-study.toml", mc)
restored_mc = load_monte_carlo("offset-study.toml")
```

Snapshots and results carry structural, parameter, and compiled fingerprints.
`provenance`, `report`, and `validity_report` expose these together with solver
statistics and warnings.

Serialization intentionally rejects arbitrary Julia functions. Circuits using
behavioral source closures should be reconstructed from code instead of treated
as portable data.

## Device and model reference

The core constructors are:

- Passive: `resistor`, `conductance`, `capacitor`, `inductor`.
- Sources: `voltage_source`, `current_source`, `transconductance`,
  `voltage_controlled_voltage_source`, `current_controlled_current_source`, and
  `current_controlled_voltage_source`.
- Semiconductor: `diode` with `JunctionDiode`, `npn` with `GummelPoonBJT`, and
  `nmos`/`pmos` with `Level1MOSFET` or `ChargeBasedMOSFET`.
- Behavioral: `opamp` with `BehavioralOpAmp`, `analog_switch` with smooth or
  event switch models, and nonlinear `behavioral_current_source` /
  `behavioral_voltage_source` with user-supplied constitutive laws and analytic
  gradients.

The extended catalog adds these constructors, using existing primitives and
analytic behavioral laws:

| Family | Constructors |
| --- | --- |
| Junctions and light sensors | `zener`, `schottky`, `led`, `photodiode`, `solar_cell` |
| JFETs | `njfet`, `pjfet` |
| Signal conditioning | `analog_multiplier`, `voltage_limiter`, `comparator`, `voltage_controlled_resistor` |
| Nonlinear and adjustable resistance | `varistor`, `thermistor`, `potentiometer` |
| Composite networks | `ideal_transformer`, `bridge_rectifier`, `crystal`, `transmission_line` |

Catalog defaults are illustrative: the comparator is smooth and memoryless
(no delay or hysteresis), the thermistor uses a fixed supplied temperature, and
the LED models an electrical junction without optical output. The transmission
line is a lumped pi-section RLGC approximation whose R/L/G/C parameters are total
line values. See the [catalog example](examples/18_device_catalog/circuit.jl)
and [constructor docstrings](src/Devices/Catalog.jl) for terminal order and limits.

### Resistor materials, passive packages, and capacitor dielectrics

Use `material=`, `package=`, and `dielectric=` to attach reusable physical models
to ordinary `resistor` and `capacitor` constructors. The catalog now includes
24 additional types alongside `ThinFilm`, `SMD0603`, `C0G`, and `DebyeBranches`:

| Family | Available models | Supported behavior |
| --- | --- | --- |
| Resistor materials | `ThinFilm`, `ThickFilm`, `MetalFilm`, `CarbonFilm`, `CarbonComposition`, `MetalFoil`, `Wirewound` | Configurable power-law excess current noise, added to resistor thermal noise |
| Surface-mount packages | `SMD0201`, `SMD0402`, `SMD0603`, `SMD0805`, `SMD1206`, `SMD1210`, `SMD2010`, `SMD2512` | Explicit resistor or capacitor parasitics; names use imperial size codes |
| Leaded and generic packages | `Axial`, `Radial`, `PassivePackage` | The same lumped parasitic parameters, for leaded parts or custom configurations |
| Ceramic dielectrics | `C0G`, `X7R`, `X5R` | Loss calibrated at an explicit reference frequency |
| Film and mica dielectrics | `Polypropylene`, `Polyester`, `PPS`, `Mica` | The same calibrated loss model |
| Bulk capacitor technologies | `AluminumElectrolytic`, `Tantalum` | The same calibrated loss model; specify leakage and absorption separately |
| Dielectric absorption | `DebyeBranches` | Additional series RC relaxation branches in parallel with the main capacitor |

The additions were prioritized as packages first, resistor materials second, and
capacitor dielectrics third, so they reuse the existing simulation kernels.
The [complete inventory and roadmap](design_specs/passive_model_catalog.md)
includes other device models and the next priorities: resistor temperature and
voltage dependence, capacitor bias/temperature/aging curves, magnetic cores,
electrothermal packages, and broadband loss models.

Technology names identify families, not manufacturer parts. Noise coefficients,
loss tangent, and package parasitics default to zero; supply measured or
datasheet values for the intended part. Equal parameters produce equal electrical
behavior across family names. The following values are illustrative.

#### Package parasitics and resistor noise

Component constructors reject unsupported keywords, including misplaced model
parameters: use `diode(a, b; model=JunctionDiode(ideality=2.))`, for example.
Inductor `winding_resistance` and `series_resistance` are aliases; specify only one.
See [the component keyword audit](design_specs/component_keyword_audit.md) for
where parameters enter each analysis and which effects require rebuilding.

Every package accepts four finite, nonnegative parameters:

- Resistors use `series_inductance` in series with the resistance and
  `parallel_capacitance` across the external terminals.
- Capacitors use `esr` and `esl` in series. Component-level `esr` and `esl`
  override their package values, including an explicit zero.

Nonzero fields for the other component kind are rejected when adding the component. A package name does not infer
mounting geometry or thermal properties. Model wirewound inductance explicitly
through the package; `Wirewound()` alone adds no inductance.

All resistor materials accept `excess_noise_coefficient` (default zero),
`excess_current_exponent` (2), `excess_frequency_exponent` (1), and
`excess_reference_frequency` (1 Hz). Their excess current-noise PSD is
`coefficient * abs(I)^current_exponent * (reference_frequency/f)^frequency_exponent`.
The coefficient's units depend on the current exponent. Resistor `tc1`,
`temperature_coefficient`, and `voltage_coefficient` still reject nonzero values.

```julia
R2 = resistor(a, b; value=4.7kΩ,
    material=ThickFilm(excess_noise_coefficient=1e-12),
    package=SMD0402(series_inductance=0.4nH, parallel_capacitance=20fF),
)

C2 = capacitor(a, b; value=1μF,
    dielectric=Polypropylene(loss_tangent=0.001, reference_frequency=1kHz),
    package=Radial(esr=0.2Ω, esl=5nH),
    leakage_resistance=1GΩ,
)
```

#### Capacitor loss and dielectric absorption

A nonzero `loss_tangent` requires an explicit positive `reference_frequency` in
Hz. Amber adds a constant series resistance
`Rloss = loss_tangent / (2π * reference_frequency * nominal_capacitance)` to the
component/package ESR. This supports AC, transient, and thermal-noise analyses
with the same RC model. The calibration describes the nominal capacitor alone;
other parasitics change the terminal loss. If a supplied ESR already includes
dielectric loss, use that ESR alone to avoid counting the loss twice.

Dielectric names do not model DC-bias derating, temperature curves, aging,
polarization, or voltage limits. Leakage and dielectric absorption are separate
supported effects, configured with `leakage_resistance` and
`dielectric_absorption=DebyeBranches(...)`.
Debye branches add `Ci = C * fraction[i]` and `Ri = time_constant[i] / Ci`;
fractions must be finite and nonnegative, and time constants finite and positive.
Zero fractions add no branch. The main capacitance remains the nominal value.

Example physical models include:

```julia
R1 = resistor(a, b; value=10kΩ,
    material=ThinFilm(
        excess_noise_coefficient=1e-18,
    ),
    package=SMD0603(series_inductance=0.6nH, parallel_capacitance=40fF),
)

C1 = capacitor(a, b; value=10nF,
    dielectric=C0G(loss_tangent=1e-4, reference_frequency=1kHz),
    dielectric_absorption=DebyeBranches(
        time_constants=[1μs, 1ms],
        fractions=[0.002, 0.001],
    ),
    package=SMD0603(esr=30mΩ, esl=500pH),
)
```

These options elaborate into explicit internal primitives before sparse
compilation, so parasitic current and stored state participate in the same
equations as the ideal element. Capacitor loss tangent produces a constant series
resistance calibrated at the explicit reference frequency; it does not imply
constant loss tangent across frequency.

#### Reuse, persistence, and parameter changes

All named material, package, and dielectric models support `model_parameters`,
`with_model_parameter`, circuit serialization, and result provenance:

```julia
base_package = SMD0805(esr=30mΩ, esl=500pH)
custom_package = with_model_parameter(base_package, :esr, 50mΩ)
model_parameters(custom_package)  # base_package is unchanged
```

Rebuild a circuit after changing its package, dielectric, or absorption model;
`with_parameters` rejects replacement of these structural options. Updating a
compiled capacitor's `value` changes only its main capacitance: the expanded
loss resistor and absorption branches stay fixed. Rebuild to preserve the loss
tangent calibration or absorption fractions when changing nominal capacitance.

## Technical architecture

Amber uses a compiler pipeline rather than assembling an opaque matrix afresh
for each solve:

```text
Julia DSL / CircuitBuilder
          │
          ▼
immutable CircuitDesign + reusable SubcircuitTemplate IR
          │  validation, hierarchy elaboration, parameter evaluation
          ▼
HierarchicalCompiledTopology  +  ParameterStore
          │                        │
          ├─ typed unknown/equation layouts
          ├─ global sparse CSC pattern
          ├─ precomputed residual/Jacobian slots
          └─ structure-of-arrays device batches
                         │
                         ▼
              reusable SimulationWorkspace
                         │
                         ▼
             DC / transient / AC / noise / PSS
```

### Typed generalized MNA

Compilation classifies unknowns as node voltages, branch currents, device
states, or partition interfaces. Equations are separately classified as KCL,
voltage constraints, dynamic states, or device auxiliaries. Voltage sources and
inductors receive branch-current unknowns; dynamic compact models can own state
unknowns. This metadata connects a failed numerical row back to a named device
or state.

Amber evaluates residuals in the descriptor form

```text
F(x, x', t) = 0
```

and separately assembles stored charge/flux `q(x)` and its Jacobian through
`storage_jacobian!`. Transient integration uses `d(q(x))/dt + f(x,t) = 0`;
frequency analyses assemble the static and dynamic matrices independently.
The continuous residual API retains its derivatives at nonzero `x'`.
The same device
kernels therefore serve Newton DC, implicit BDF integration, AC linearization,
descriptor control analysis, PSS variational analysis, and noise propagation.

### Sparse compilation and reuse

Hierarchy elaboration computes global solver-net identities without discarding
instance paths. Device contracts declare terminal, branch, state, and stamp
shapes. The compiler then:

1. counts unknowns and equations;
2. builds one sorted sparse CSC pattern;
3. records the exact `nzval` slot for every device derivative;
4. batches like devices into typed structure-of-arrays kernels; and
5. separates topology from numerical parameters.

`SimulationWorkspace` owns reusable residual, derivative, scaled-Jacobian,
factorization, and Newton buffers. Linear circuits reuse numeric factorizations
when the parameter fingerprint and integration coefficient allow it; other
solves reuse the symbolic sparse structure. `residual!`, `jacobian!`, and
`residual_jacobian!` expose the in-place assembly layer for advanced users and
model verification.

### Structural and numerical diagnostics

Before numerical solving, `check` detects missing ground, floating DC networks,
unsupported terminal contracts, ideal voltage-constraint loops, and conflicting
ideal voltages. Lookups rank nearby names and suggest corrections. During a
failure, solver statistics retain iteration history, rejected continuation or
time steps, convergence strategy, warnings, and the dominant typed residual.

### Reproducibility by construction

Immutable designs and compiled snapshots prevent old results from changing when
parameters are updated. Structural and parameter fingerprints identify exactly
what was solved. Monte Carlo derives a seed per sample before optional threaded
execution, so scheduling does not change the experiment. Stable serialization
uses bounded, schema-versioned TOML readers rather than Julia object
deserialization.

## Scope and model boundaries

Amber is intentionally transparent about what it does not yet model:

- Semiconductor models are compact engineering models, not foundry-qualified
  BSIM libraries. The level-1 MOSFET omits subthreshold behavior, a body diode,
  short-channel effects, and substrate networks. `ChargeBasedMOSFET` adds
  continuous inversion and optional junctions but omits short-channel and
  non-quasi-static effects; its noise model omits junction shot noise.
- Temperature dependence is partial; there is no electrothermal or self-heating
  solution.
- Behavioral op-amp parameters are richer than the currently enforced device
  equations; verify slew/current-limit behavior needed by a particular study.
- Stochastic transient noise uses a fixed grid. Power-law noise requires finite
  frequency limits.
- Periodic and phase-noise accuracy depends on PSS convergence, orbit sampling,
  and sideband truncation. Convergence should be checked as those are refined.
- Multiple equilibria, ideal constraints, stiff dynamics, and extreme scale
  separation can require realistic parasitics, informed initial conditions, and
  numerical refinement.
- There is currently no SPICE netlist importer/exporter or foundry model-card
  parser.
- SI suffixes such as `kΩ`, `nF`, and `MHz` are readable scale factors, not a
  dimensional type system. Internally, Amber uses SI-valued `Float64` and
  `ComplexF64` data.

Treat model validity and numerical convergence as separate questions. Inspect
`result.stats`, `provenance(result)`, and `validity_report(result)`; refine time
steps, frequency grids, PSS samples, and sideband counts; and compare critical
results against theory or an independent implementation.

## Examples

The [example gallery](examples/) is executable and covers:

- a practical RC filter with package and material effects;
- diode rectification and startup;
- common-emitter and differential amplifiers;
- a Wien oscillator and a CMOS ring oscillator;
- sample-and-hold switching with exact events;
- a generated 200-section RLGC transmission line;
- a switched buck converter;
- hierarchical active filters;
- correlated Monte Carlo on a precision bridge;
- CMOS transfer and propagation delay;
- conductance-crossbar matrix multiplication;
- a [light detector and transformer divider](examples/18_device_catalog/circuit.jl)
  using the extended device catalog;
- difficult nonlinear convergence and regenerative circuits; and
- [systems beyond electronics](examples/17_beyond_electronics/), including
  thermal, SIR epidemic, Hodgkin-Huxley, Josephson-junction, and acoustic
  waveguide models built from behavioral constitutive laws.

Run an example from the repository root:

```sh
julia --project=. examples/03_common_emitter/noise.jl
julia --project=. examples/07_rlgc_line/step_response.jl
julia --project=. examples/11_precision_bridge/monte_carlo.jl
```

## Development

Run the complete test suite with:

```julia
using Pkg
Pkg.test()
```

The tests include analytic identities, conservation laws, Jacobian checks,
convergence-order tests, metamorphic tests, external reference values, result
snapshot checks, and the on-disk example gallery. Benchmarks live in
[`benchmark/`](benchmark/).

Amber is licensed under the [MIT License](LICENSE).
