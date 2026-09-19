# Public documentation lives together so `?Amber.name` and Documenter expose the
# same contract without coupling narrative text to implementation files.

@doc """Reusable structural indexing and sparse-pattern information produced by `compile`.""" CompiledTopology
@doc """
    compile(design) -> CompiledCircuit

A validated circuit with reusable sparse topology and device parameters.
Pass it to analyses just as you would a `CircuitDesign`. Reusing it avoids
repeating structural compilation in parameter studies. Do not edit its internal
arrays; use [`with_parameters`](@ref) to obtain an updated compiled circuit.
`compiled.design` retains the input design, and `compiled.n` is the number of
solver unknowns. Compilation does not solve an operating point.
""" CompiledCircuit
@doc """
    SimulationResult

Result returned by [`operating_point`](@ref), [`transient`](@ref), and
[`small_signal`](@ref). Prefer constructing results through those analyses.

- `axis`: saved times in seconds, frequencies in Hz, or `[0.0]` for DC.
- `stats`: convergence status, warnings, and analysis-specific diagnostics.
- `analysis`: the analysis descriptor and resolved settings.
- `compiled`: the circuit snapshot used for the calculation.

Use `voltage`, `current`, `power`, and `observation` rather than indexing the
internal `values` matrix: its rows include more than node voltages. Accessors
return vectors, including one-element vectors for DC. A returned result is not
necessarily converged; inspect `stats[:converged]` and `report(result)`.
A partial transient contains only the saved portion of the requested interval.
""" SimulationResult

@doc """
    node!(builder::CircuitBuilder, name) -> node_handle

Add a node to a mutable builder. `name` may be a symbol, string, or an indexed
name tuple such as `(:tap, 3)`. Omitting it generates an internal name. The
returned handle belongs to this builder; mixing handles from different builders
is an error. A node is not ground and does not itself provide a DC reference.

```julia
builder = CircuitBuilder(:Example)
input = node!(builder, :input)
reference = ground!(builder)
```

Inside `@circuit`, write `input = node()` instead. See [`ground!`](@ref).
""" node!
@doc """
    ground!(builder::CircuitBuilder, name=:gnd) -> node_handle

Add the unique top-level electrical reference node. Its potential is zero volts.
A second call on the same builder throws an error; reuse the returned handle.
Subcircuits should receive their reference through an explicit port instead of
creating their own ground. See [`ground`](@ref), [`CircuitBuilder`](@ref).
""" ground!
@doc """
    add!(builder::CircuitBuilder, component; name=...) -> device_handle

Attach a primitive draft such as `resistor(a, b; value=1kΩ)` to a builder.
Terminal handles must belong to that builder. Supply a stable name for later
current/power lookup and parameter updates; otherwise a name is generated.
Some modeled components expand into several primitives during this operation.

```julia
builder = CircuitBuilder(:Load)
gnd = ground!(builder)
input = node!(builder, :input)
add!(builder, voltage_source(input, gnd; dc=1V); name=:Source)
add!(builder, resistor(input, gnd; value=1kΩ); name=:R1)
design = finish(builder)
```

Inside `@circuit`, assignment attaches and names the component automatically.
""" add!
@doc """
    observe!(builder, observables...; name=nothing)

Register voltage/current/power or other observables on a builder for later
retrieval. A named observation requires exactly one value and a unique name within
this builder; otherwise an `ArgumentError` is raised before registration. Returns the last supplied observable, or the builder when
no observables are supplied. This adds a measurement definition, not a circuit
load or a new solver unknown.

```julia
observe!(builder, voltage(input); name=:input_voltage)
```

After simulation, use `observation(result, :input_voltage)`. See [`observe`](@ref).
""" observe!
@doc """
    observe(observables...; name=nothing)

Register measurements inside `@circuit` or `@subcircuit`. This DSL form is
rewritten to [`observe!`](@ref); it cannot be called standalone.

```julia
observe(voltage(out); name=:output)
observe(current(R1), power(R1))
```

Measurements do not load the circuit. Give each named measurement its own call and a unique name in its circuit or
subcircuit scope; duplicate names are rejected. Retrieve it with `observation(result, :output)` or `trace(result, :output)`.
Named measurements inside hierarchy can be accessed using qualified names.
""" observe
@doc """
    compile(design::CircuitDesign) -> CompiledCircuit
    compile(compiled::CompiledCircuit) -> CompiledCircuit

Check circuit structure and build reusable solver topology and parameters.
Structural errors throw `CircuitValidationError`; call `check(design)` or
`explain(design)` first when you want diagnostics without starting an analysis.
An already compiled circuit is returned unchanged. No DC/transient solution is
computed by compilation.

```julia
compiled = compile(circuit)
op = operating_point(compiled)
tuned = with_parameters(compiled, "R1.value" => 2kΩ)
```

Parameter-only updates may share topology. Changes to connections or component
counts require rebuilding the design and compiling it again.
""" compile
@doc """
    node()

Create an electrical node inside `@circuit` or `@subcircuit`. Assign it to a
variable, e.g. `out = node()`, to give it a stable lookup name. Nodes require a
physical DC path to the reference for an ordinary operating-point solution;
capacitors and current sources alone do not establish that path.

Outside the DSL use `node!(builder, :out)`. See [`ground`](@ref), [`check`](@ref).
""" node
@doc """
    ground()

Create the electrical reference inside a top-level `@circuit`, typically as
`gnd = ground()`. Its voltage is zero. Create it once and reuse its handle.
For reusable subcircuits, pass the reference as a port instead.

This is a DSL operation, not a standalone node constructor. In builder code use
`ground!(builder)`. See [`node`](@ref), [`ground!`](@ref).
""" ground
@doc """
    @circuit Name(; parameters...) begin
        # nodes, sources, devices, observations
    end

Define a Julia circuit constructor. Calling it returns a `CircuitDesign`;
construction does not run a simulation. Variable assignments give nets and
components stable names for result lookup and parameter updates. Use one
`ground()` for the top-level reference. Ordinary Julia loops and conditionals
can generate circuit structure.

```julia
using Amber
@circuit HelpRC(; R=1kΩ, C=1μF) begin
    gnd = ground(); vin = node(); out = node()
    Source = voltage_source(vin, gnd; dc=1V, ac=1V)
    R1 = resistor(vin, out; value=R)
    C1 = capacitor(out, gnd; value=C)
    observe(voltage(out); name=:output)
end
circuit = HelpRC()
@assert isempty(check(circuit))
op = operating_point(circuit)
@assert isapprox(only(voltage(op, :out)), 1V)
```

Use `@subcircuit` for reusable blocks with explicit ports, or `CircuitBuilder`
for programmatic construction without the macro.
""" :(@circuit)

@doc """
    resistor(p, n; value=1.0, material=nothing, package=nothing, tolerance=...)

Create a resistor draft with resistance `value` in ohms. Assign it inside
`@circuit`, or attach it using `add!`. Positive current flows from `p` to `n`.

```julia
R1 = resistor(vin, out; value=10kΩ)
```

A material such as `ThinFilm` supplies explicitly configured excess-noise
parameters, not manufacturer-specific characteristics. A package may add series
inductance and terminal parallel capacitance. `tolerance` is variation metadata;
it does not randomly perturb a nominal analysis. Thermal noise is evaluated by
noise analyses at their specified temperature. See [`capacitor`](@ref).
""" resistor
@doc """
    capacitor(p, n; value=1.0, esr=..., esl=..., leakage_resistance=...,
              dielectric=nothing, package=nothing, dielectric_absorption=nothing,
              initial_voltage=..., tolerance=...)

Create a capacitor draft with `value` in farads. Voltage and stored charge are
oriented from `p` to `n`. An ideal capacitor is open at DC and cannot bias an
otherwise floating node.

```julia
C1 = capacitor(out, gnd; value=100nF, esr=50mΩ)
initial_voltage(C1, 1V)  # inside the circuit DSL
```

ESR is in ohms, ESL in henries, leakage resistance in ohms, and initial voltage
in volts. Parasitics default to zero and leakage is absent unless supplied.
Component-level ESR/ESL override package values, including explicit zero.
Dielectric loss and `DebyeBranches` absorption can expand into extra elements;
changing just the compiled `value` does not rescale those elements. Rebuild the
design when their calibration must track capacitance. Dielectric labels do not
implement bias derating, aging, or voltage ratings. See [`initial_voltage`](@ref).
""" capacitor
@doc """
    inductor(p, n; value=1.0, winding_resistance=0.0,
             parallel_capacitance=0.0, tolerance=...)

Create an inductor draft with inductance in henries and positive current from
`p` to `n`. Optional winding resistance is in ohms; terminal parallel capacitance
is in farads. `series_resistance` is an alias for winding resistance: do not
specify both. Assign inside `@circuit` or attach with `add!`.

```julia
L1 = inductor(input, out; value=10μH, winding_resistance=100mΩ)
```

At DC an ideal inductor is a short. Ideal-inductor loops may be singular; inspect
`check(circuit)`. There is no `initial_current` keyword or exported setter;
`initial_voltage` applies only to capacitors. See [`transient`](@ref).
""" inductor
@doc """
    conductance(p, n; value=1.0, tolerance=...)

Create a two-terminal conductance in siemens: current from `p` to `n` is
`value * (V(p)-V(n))`. For example, `conductance(out, gnd; value=1mS)` is a
1 kohm shunt. Attach inside `@circuit` or with `add!`.
See [`resistor`](@ref) for resistance-based construction.
""" conductance
@doc """
    voltage_source(p, n; dc=0.0, ac=0.0, waveform=nothing,
                   series_resistance=0.0)

Create an independent voltage source oriented as `V(p)-V(n)`. `dc` sets its
operating-point voltage; `ac` sets small-signal excitation. A transient waveform
replaces (does not add to) `dc`; without a waveform the transient value is `dc`.
All amplitudes are in volts; series resistance is in ohms.

```julia
Source = voltage_source(vin, gnd; dc=0V, ac=1V,
    waveform=Step(low=0V, high=1V, at=100μs, rise=1μs))
```

A source delivering power to a passive load normally has negative
`current(result, :Source)` and `power(result, :Source)`. Contradictory ideal
voltage sources make the circuit invalid. See [`Step`](@ref), [`Sine`](@ref),
[`Pulse`](@ref), [`small_signal`](@ref).
""" voltage_source
@doc """
    current_source(p, n; dc=0.0, ac=0.0, waveform=nothing)

Create an independent source with positive current flowing from `p` to `n`.
Amplitudes are in amperes. `dc` controls the operating point, `ac` controls
small-signal excitation, and a transient `waveform` replaces `dc` when present.
A current source does not establish an absolute DC node voltage; provide a
resistive or other voltage-setting path.

```julia
Bias = current_source(vdd, out; dc=1mA)
```

Assign inside `@circuit` or attach using `add!`. See [`voltage_source`](@ref).
""" current_source
@doc """
    diode(anode, cathode; model=JunctionDiode())

Create a junction-diode draft. Positive voltage is anode minus cathode; positive
current flows anode to cathode. Assign it inside `@circuit` or attach with `add!`.

```julia
D1 = diode(input, out; model=JunctionDiode(saturation_current=2nA,
    ideality=1.7, series_resistance=120mΩ))
```

The model controls conduction, optional charge storage, breakdown, and noise.
Its defaults are illustrative, not a named real diode. Adding capacitance or
transit time changes transient and AC behavior. See [`JunctionDiode`](@ref).
""" diode
@doc """
    npn(collector, base, emitter; model=GummelPoonBJT(), match=nothing)

Create an NPN transistor with the terminal order collector, base, emitter.
`model` specifies transport, charge, resistance, and noise parameters. Optional
`match` associates a `MatchedGroup` for mismatch studies; it does not alter a
nominal bias calculation.

```julia
Q1 = npn(collector, base, emitter; model=GummelPoonBJT(forward_beta=150.0))
```

Use `current(op, :Q1, :collector)` or `:base`/`:emitter` for terminal currents
and `region(op, :Q1)` for a qualitative operating-region check. Model defaults
are illustrative. See [`GummelPoonBJT`](@ref).
""" npn
@doc """
    nmos(drain, gate, source, bulk; model=Level1MOSFET(), width=nothing,
         length=nothing, multiplicity=nothing, drain_area=nothing,
         source_area=nothing, drain_perimeter=nothing, source_perimeter=nothing)

Create an NMOS with explicit drain/gate/source/bulk terminals. Tie bulk to the
appropriate circuit node; it is not implicitly connected to source or ground.
Use `Level1MOSFET` for simple strong-inversion models, or `ChargeBasedMOSFET` for
continuous inversion and conserving terminal charges.

Geometry overrides require `ChargeBasedMOSFET` and create an instance model copy.
Lengths/perimeters are in metres, junction areas in square metres, multiplicity
is dimensionless. W/L does not infer junction areas/perimeters.

```julia
M1 = nmos(out, input, gnd, gnd;
    model=ChargeBasedMOSFET(), width=8μm, length=2μm)
```

Use `mosfet_operating_point(op, :M1)` for device bias information. Neither model
provides foundry-calibrated parameters by default. See [`pmos`](@ref).
""" nmos
@doc """
    pmos(drain, gate, source, bulk; model=Level1MOSFET(), geometry_keywords...)

Create a PMOS with the same terminal order and optional geometry keywords as
[`nmos`](@ref). In a conventional inverter, source and bulk connect to the
positive supply. Model threshold voltage is a positive magnitude; the model
applies PMOS polarity internally. Currents retain terminal-oriented signs.

```julia
PullUp = pmos(output, input, supply, supply;
    model=Level1MOSFET(threshold_voltage=0.7V, transconductance=1mA/V^2))
```

Geometry overrides are accepted only with `ChargeBasedMOSFET`. They do not
turn a Level-1 model into a geometry-based model.
""" pmos
@doc """    opamp(positive_input, negative_input, output, positive_supply, negative_supply;
          model=BehavioralOpAmp())

Construct an op amp with explicit supply terminals. A positive differential
input drives the output positive. Connect negative feedback to `negative_input`;
for a voltage follower, connect both `negative_input` and `output` to the output
net. Model parameters use SI values, with `dc_gain` as a linear voltage ratio.

```julia
Buffer = opamp(input, output, output, vdd, vss;
    model=BehavioralOpAmp(dc_gain=100dB, gain_bandwidth=1MHz))
```

This is a behavioral approximation, not a manufacturer-specific device model.""" opamp
@doc """
    analog_switch(a, b, control_p, control_n; model=VoltageControlledSwitch())

Create a controlled conductive path between `a` and `b`. The control signal is
`V(control_p)-V(control_n)`; its threshold and on/off resistances are set by the
model. This is a bilateral analog switch, not a sampled digital logic gate.

```julia
Switch = analog_switch(input, hold, clock, gnd;
    model=EventSwitch(threshold=1.5V, ron=10Ω, roff=1GΩ))
```

Use `event_mode=:exact` for event-oriented switching and modeled charge injection.
`SmoothSwitch` provides a continuous transition instead. Resolve the control
waveform and output dynamics with the transient timestep.
""" analog_switch
@doc """
    transconductance(control_p, control_n, output_p, output_n; gm=1.0)

Create a voltage-controlled current source. Current from `output_p` to
`output_n` is `gm * (V(control_p)-V(control_n))`; `gm` is in siemens (A/V).
Control terminals come first and do not draw input current.

```julia
G1 = transconductance(input, gnd, out, gnd; gm=1mS)
```

Assign inside `@circuit` or attach with `add!`. This is an ideal linear source,
with no saturation, delay, or supply-current model.
""" transconductance
@doc """
    voltage_controlled_voltage_source(control_p, control_n, output_p, output_n;
                                      gain=1.0)

Create an ideal voltage amplifier imposing
`V(output_p)-V(output_n) = gain * (V(control_p)-V(control_n))`.
The control pair comes first; gain is dimensionless V/V. The input draws no
current and the output is an ideal voltage constraint, with no supply rails or
saturation.

```julia
E1 = voltage_controlled_voltage_source(input, gnd, out, gnd; gain=10.0)
```

Use [`opamp`](@ref) for a behavioral amplifier with finite bandwidth and rails.
Conflicting ideal output constraints are structural errors.
""" voltage_controlled_voltage_source
@doc """
    current_controlled_current_source(control, output_p, output_n; gain=1.0)

Create a source whose current from `output_p` to `output_n` equals `gain` times
the controlling branch current. Gain is dimensionless A/A. `control` is a device
handle or local device name with a branch-current unknown; an arbitrary
resistor is not a valid controlling branch. A zero-volt series source is a
convenient current sensor.

```julia
Sense = voltage_source(input, sensed; dc=0V)
F1 = current_controlled_current_source(Sense, out, gnd; gain=2.0)
```

The controlling current's sign follows the sensing device's terminal order.
See [`current_controlled_voltage_source`](@ref).
""" current_controlled_current_source
@doc """
    current_controlled_voltage_source(control, output_p, output_n;
                                      transresistance=1.0)

Create an ideal voltage source imposing `V(output_p)-V(output_n)` equal to
`transresistance` times the controlling branch current. Transresistance is in
ohms (V/A). The control handle/name must refer to a primitive with a branch-current
unknown, such as an independent voltage source.

```julia
Sense = voltage_source(input, sensed; dc=0V)
H1 = current_controlled_voltage_source(Sense, out, gnd; transresistance=1kΩ)
```

Use a zero-volt series source to sense current without adding a voltage drop.
The control sign follows its terminal order; this ideal output has no saturation
or output-current limit.
""" current_controlled_voltage_source

@doc """    Step(; low=0.0, high=1.0, at=0.0, rise=0.0)

Transition from `low` to `high` starting at time `at` (seconds), linearly over
`rise` seconds. A zero rise is instantaneous. Amplitudes use the source's units
(V for voltage sources, A for current sources). Use `event_mode=:exact` in
`transient` and a `max_step` smaller than a finite rise time to resolve the edge.""" Step
@doc """
    Sine(; amplitude=1.0, frequency=1.0, phase=0.0, offset=0.0)

Callable waveform `offset + amplitude*sin(2π*frequency*t + phase)`.
`amplitude` is peak amplitude, not peak-to-peak or RMS. Frequency is in Hz,
phase in radians, and evaluation time in seconds. Amplitude and offset use the
units of the attached source (V or A). There is no delay keyword.

```julia
wave = Sine(amplitude=2V, frequency=1kHz, offset=1V)
@assert wave(0s) == 1V
```

Use `waveform=wave` on a source. Its operating-point and AC excitations remain
controlled by that source's separate `dc` and `ac` keywords.
""" Sine
@doc """
    Pulse(; low=0.0, high=1.0, frequency=1.0, duty_cycle=0.5,
          rise=0.0, fall=0.0, delay=0.0)

Callable periodic waveform with linear edges. Times are in seconds, frequency
in Hz, and `duty_cycle` is a fraction in `[0, 1]`. Levels use the attached
source's units. Before `delay`, the output is `low`. Each cycle rises at its
start and begins falling at `duty_cycle/frequency`; the rise is part of the
specified on interval. Choose edges that fit the intended on/off intervals.

```julia
clock = Pulse(low=0V, high=3.3V, frequency=100kHz,
    duty_cycle=0.4, rise=10ns, fall=10ns, delay=1μs)
```

Zero rise/fall times give discontinuities. Use `event_mode=:exact` in transient
analysis and enough internal steps to resolve finite edges. See [`Step`](@ref).
""" Pulse
@doc """Thin-film resistor metadata including explicit power-law excess-noise parameters.""" ThinFilm
@doc """0603 (imperial) passive package. Explicit resistor series_inductance/parallel_capacitance or capacitor esr/esl; all default to zero.""" SMD0603
@doc """C0G/NP0 dielectric. Nonzero loss_tangent requires reference_frequency (Hz); elaborates to constant series R = tan(delta)/(2pi*f*C), added to ESR. No bias or temperature dependence.""" C0G
@doc """A sum of Debye relaxation branches used to model dielectric absorption.""" DebyeBranches
@doc """
    JunctionDiode(; saturation_current=1e-12, ideality=1.2,
        series_resistance=0.0, junction_capacitance=0.0, junction_potential=0.7,
        grading_coefficient=0.5, transit_time=0.0, breakdown_voltage=Inf, ...)

Immutable junction-diode model. Current parameters use amperes, resistance
uses ohms, capacitance uses farads, potentials use volts, and transit time uses
seconds. Ideality and grading coefficient are dimensionless. The default zero
junction capacitance and transit time omit stored-charge effects; infinite
breakdown voltage disables breakdown. Noise includes shot noise and explicitly
configured flicker parameters, whose coefficient defaults to zero.

```julia
model = JunctionDiode(saturation_current=2nA, ideality=1.7,
    junction_capacitance=15pF, transit_time=2μs)
```

Inspect `model_parameters(model)` for the full parameter set. Pass the model to
`diode(...; model)`. Defaults are illustrative, not a manufacturer model.
""" JunctionDiode
@doc """
    GummelPoonBJT(; saturation_current=1e-14, forward_beta=100.0,
        reverse_beta=1.0, early_voltage=100.0, base_resistance=0.0,
        cbe_zero_bias=0.0, cbc_zero_bias=0.0, transit_time=0.0, ...)

Immutable NPN compact model used by [`npn`](@ref). Saturation current is in A,
Early voltage in V, base resistance in ohms, junction capacitances in F, and
transit time in s. Betas are dimensionless. Default capacitances/transit time
are zero, so explicitly supply charge parameters when dynamic behavior matters.
Flicker-noise coefficient defaults to zero.

```julia
model = GummelPoonBJT(forward_beta=150.0, early_voltage=80V,
    cbe_zero_bias=10pF, cbc_zero_bias=3pF)
```

Inspect `model_parameters(model)` for all supported parameters. The parameter
set is an engineering approximation, not a promise of SPICE model-card
compatibility or manufacturer accuracy.
""" GummelPoonBJT
@doc """
    Level1MOSFET(; threshold_voltage=0.7, transconductance=1e-3,
        channel_length_modulation=0.0, body_effect=0.0, surface_potential=0.6,
        gate_source_capacitance=0.0, gate_drain_capacitance=0.0,
        gate_bulk_capacitance=0.0, ...)

Simple strong-inversion MOS model for `nmos` and `pmos`. Threshold is a positive
magnitude in V, transconductance parameter is in A/V^2, channel-length modulation
in 1/V, body effect in sqrt(V), and gate capacitances in F. The transconductance
parameter is not the bias-dependent small-signal `gm`.

```julia
model = Level1MOSFET(threshold_voltage=0.7V,
    transconductance=2mA/V^2, channel_length_modulation=0.03/V)
```

Default capacitances are zero. This model does not accept per-instance W/L
geometry overrides. Use `ChargeBasedMOSFET` for continuous weak-to-strong
inversion and conserving terminal charges. Inspect `model_parameters(model)`
for optional noise coefficients; defaults are not foundry parameters.
""" Level1MOSFET
@doc """    BehavioralOpAmp(; dc_gain=1e5, gain_bandwidth=1e6, slew_rate=Inf,
        output_resistance=10.0, output_current_limit=Inf, input_offset=0.0, ...)

Behavioral op-amp model. Gain is a linear V/V ratio, bandwidth is in Hz,
slew rate in V/s, output resistance in ohms, current limit in A, and offset in V.
Defaults include zero input bias current, input capacitance, saturation recovery,
and noise densities; they do not describe a particular real part.

Noise keywords include `input_voltage_noise_density` (V/sqrt(Hz)),
`positive_input_current_noise_density` and `negative_input_current_noise_density`
(A/sqrt(Hz)), plus `input_voltage_flicker_corner` and
`input_current_flicker_corner` (Hz). Noise densities and flicker corners default
to zero. Use `model_parameters(model)` to inspect all parameters.
See also [`opamp`](@ref).""" BehavioralOpAmp
@doc """Voltage-controlled switch parameters including resistance, threshold, and parasitics.""" VoltageControlledSwitch
@doc """Smooth continuously differentiable switch transition mode.""" SmoothSwitch
@doc """Event-oriented switch transition mode.""" EventSwitch
@doc """Ideal resistor model marker.""" IdealResistor
@doc """Ideal capacitor model marker.""" IdealCapacitor
@doc """Return a model's local differential capacitance at the supplied bias.""" differential_capacitance

@doc """
    voltage(node)
    voltage(positive, negative)
    voltage(result::SimulationResult, name)
    voltage(result::SimulationResult, positive, negative)

Without a result, construct an `Observable` for measurements, plots, or analysis
keywords. With a result, return a vector in volts, referenced to ground or as
`V(positive)-V(negative)`. Small-signal voltages are complex phasors.

```julia
vout = only(voltage(op, :out))        # one-element DC trace
vbridge = voltage(tr, :sense, :ref)  # differential transient trace
```

Lookup accepts symbols or strings, including full paths such as `"First.out"`.
Named voltage observations are also accepted. The observable form accepts node
handles during construction; the result form uses names. For transfer functions
pass `output=voltage(:out)`, not `output=:out`. See [`observation`](@ref).
""" voltage
@doc """
    current(device, branch=nothing)
    current(result::SimulationResult, name, branch=nothing)

Construct a current observable, or return a vector in amperes when given a
result. For two-terminal devices positive current flows from the first terminal
to the second; a voltage source feeding a load normally has negative current.
Results are complex in small-signal analysis and length one at DC.

For BJTs, the default is collector current; request `:base` or `:emitter` as the
third argument. For MOSFETs, the default is drain current; `:gate`, `:source`,
and `:bulk` select other terminals. Use hierarchy-qualified device names when
needed. Composite models may expose internal primitives: inspect `devices`.

```julia
idelivered = -only(current(op, :Source))
iR = current(tr, :R1)
```

Dynamic currents may be reconstructed from saved charge traces when internal
steps were not saved. Use a fine enough `saveat` to measure current peaks.
""" current
@doc """
    power(device)
    power(result::SimulationResult, name)

Construct a power observable, or return a vector of signed absorbed power in
watts. Positive values mean absorption and negative values mean delivery.
The DC result is a one-element vector; a transient result is instantaneous
power at each saved time. BJT/MOS power sums their terminal contributions.

```julia
supply_W = -only(power(op, :Source))
```

For small-signal results this accessor multiplies phasor traces algebraically;
it is not average real AC power (no conjugation or RMS normalization). Compute
that quantity explicitly from the intended voltage/current convention.
""" power
@doc """
    charge(device)
    charge(result::SimulationResult, name)

Construct a stored-charge observable, or return a vector in coulombs. The result
accessor supports capacitors and junction diodes; unsupported devices throw an
error. Capacitor charge is `C*(V(p)-V(n))`, using its primitive capacitance.

```julia
q = charge(tr, :C1)
```

For MOS terminal charges use [`terminal_charges`](@ref). Composite capacitors
with absorption contain additional charge-storage elements; a single primitive
trace does not sum them automatically.
""" charge
@doc """
    state(device, state_name)
    state(result::SimulationResult, device_name, state_name::Symbol)

Construct an internal-state observable, or retrieve its saved vector. State
names and units depend on the device contract. For example, a behavioral op amp
exposes `:dominant_pole`, a voltage-like state:

```julia
internal = state(tr, :A1, :dominant_pole)
```

This is not a generic device-parameter accessor. Unknown device/state names
raise an error; use device/model documentation to choose a supported state.
""" state
@doc """
    initial_voltage(capacitor_handle, value)

Set a capacitor's initial `V(p)-V(n)` in volts inside `@circuit` or `@subcircuit`.
This is a DSL setter, not a result getter. It returns the capacitor handle.
An equivalent construction keyword is `capacitor(...; initial_voltage=value)`.

```julia
C1 = capacitor(out, gnd; value=1μF)
initial_voltage(C1, 2V)
```

Transient initialization applies these constraints after the default operating
point or `initial=:discharged`. An explicit `initial` state vector is used as
provided instead. Inconsistent ideal-source/precharge constraints are rejected.
Only capacitors are supported; no corresponding `initial_current` setter exists.
""" initial_voltage

@doc """
    OperatingPoint(; solver=SolverOptions(), temperature=300.0)

Describe a DC analysis without running it. Pass the descriptor to `simulate`,
`sweep`, or `monte_carlo`. Temperature is in kelvin; configure nonlinear
convergence through `solver`.

```julia
op = simulate(circuit, OperatingPoint(temperature=300K))
```

See [`operating_point`](@ref) for bias behavior and status checks.
""" OperatingPoint
@doc """
    Transient(start => stop; saveat=nothing, max_step=nothing, method=:bdf2,
              adaptive=nothing, initial=nothing, event_mode=nothing,
              temperature=300.0, solver=SolverOptions(),
              integration=IntegrationOptions(), failure_policy=:return_partial,
              overrides=nothing)

Store transient-analysis settings for `simulate`, sweeps, or Monte Carlo. Times
are in seconds. This descriptor does not run a simulation. Use `solver` for
Newton tolerances and `integration` for adaptive integration tolerances;
`reltol` is not a direct keyword on this descriptor.

```julia
analysis = Transient(0s => 5ms; max_step=1μs, saveat=10μs)
tr = simulate(circuit, analysis)
```

`overrides` supplies numerical parameter path/value updates for this run.
See [`transient`](@ref) for output-grid, initialization, and partial-result rules.
""" Transient
@doc """
    SmallSignal(low => high; points=100, scale=:log, source=nothing,
                temperature=300.0, solver=SolverOptions())
    SmallSignal(frequencies::AbstractVector; source=nothing, ...)

Store a small-signal analysis for `simulate`, sweeps, or Monte Carlo. Frequency
values are in Hz and temperature in kelvin. Range construction expands the
frequency grid immediately; it does not solve the circuit.

```julia
analysis = SmallSignal([1kHz]; source=:Source)
ac = simulate(circuit, analysis)
```

Set a nonzero `ac` on the chosen independent source. See [`small_signal`](@ref)
for source selection, bias requirements, and returned phasor traces.
""" SmallSignal
@doc """
    operating_point(circuit; temperature=300.0, solver=SolverOptions(),
                    reltol=nothing, abstol=nothing, maxiters=nothing, ...)

Solve the nonlinear DC bias of a design or compiled circuit and return a
`SimulationResult`. Temperature is in kelvin. Independent sources use `dc`,
capacitors are open, and ideal inductors impose a DC short. Source waveforms and
`ac` values do not define this bias point.

`solver` supplies nonlinear tolerances and iteration limits. Supplied `reltol`,
`abstol`, and `maxiters` override its corresponding settings. Failed convergence
can return a result rather than throw; always inspect its status before using
values. Structural validation errors throw during compilation.

```julia
op = operating_point(circuit; temperature=300K)
@assert op.stats[:converged]
vout = only(voltage(op, :out))
println(report(op))
```

Use `explain_failure(op)` for solver diagnostics. A converged bias is required
for small-signal and stationary noise analyses.
""" operating_point
@doc """    transient(circuit, start => stop; saveat=nothing, max_step=nothing,
        method=:bdf2, adaptive=nothing, initial=nothing, event_mode=nothing, ...)

Integrate a circuit in seconds using implicit `:bdf1` or `:bdf2` methods.
`saveat` specifies output spacing independently of internal integration steps;
the start and stop are always included. If the span is not divisible by `saveat`,
the last output interval is shorter. Without `saveat`, retain internal steps.
`max_step` bounds integration steps; resolve finite source edges with several
steps even when using `event_mode=:exact` to land on corners and switch events.

By default, supplying `saveat` or `max_step` selects fixed stepping. Set
`adaptive=true` explicitly to use error-controlled stepping with a saved grid.
`initial=nothing` starts from a converged operating point; `:discharged` starts
from zero before applying capacitor initial voltages. A state vector is also
accepted. `reltol`/`abstol` control the nonlinear solver; `integration` controls
adaptive integration error. Inspect `result.stats[:converged]` and
`validity_report(result)` before trusting the result. Partial runs may end early;
use `failure_policy=:throw` to throw instead of returning a partial result.""" transient
@doc """
    small_signal(circuit, low => high; points=100, scale=:log,
                 source=nothing, temperature=300.0, solver=SolverOptions(), ...)
    small_signal(circuit, frequencies::AbstractVector; source=nothing, ...)

Solve the linearized AC response about a converged DC operating point. Frequency
values are in Hz; vectors must be nonempty, nonnegative, and strictly increasing.
A logarithmic range requires a positive lower bound. Equal range endpoints give
a single frequency. `scale=:linear` selects linear spacing.

Set `ac` on an independent source and identify it using `source=:Source` or a
qualified string path. With no explicit selection, multiple active AC sources
are rejected; a missing/zero excitation produces a warning and zero response.
AC excitation does not replace the source's DC bias. Temperature is in kelvin;
additional operating-point keywords are forwarded to the bias solve.

```julia
ac = small_signal(circuit, 10Hz => 1MHz; source=:Source, points=301)
H = transfer(ac; input=voltage(:vin), output=voltage(:out))
```

Returns a `SimulationResult` with complex phasor traces and a Hz axis. An
unconverged bias or singular AC system fails explicitly. See [`noise`](@ref).
""" small_signal
@doc """
    simulate(circuit, analysis)

Execute an analysis descriptor on a `CircuitDesign` or `CompiledCircuit`.
For example, `simulate(circuit, OperatingPoint())` is the descriptor form of
`operating_point(circuit)`. Return types and convergence behavior depend on the
analysis; settings belong to the descriptor rather than this function.

```julia
tr = simulate(circuit, Transient(0s => 1ms; max_step=1μs))
@assert tr.stats[:converged]
```

See [`OperatingPoint`](@ref), [`Transient`](@ref), [`SmallSignal`](@ref).
""" simulate
@doc """
    Amber.run(circuit, analyses::AbstractVector)

Run a vector of Amber analysis descriptors in order and return a vector of
results. Each descriptor is simulated independently; a preceding DC result is
not implicitly passed as the next transient's initial state. Exceptions stop
the sequence, while returned nonconverged results still require status checks.

```julia
results = Amber.run(circuit, [OperatingPoint(), SmallSignal([1kHz]; source=:Source)])
```

Qualify `Amber.run` to distinguish it from Julia's external-command `Base.run`.
See [`simulate`](@ref).
""" run
@doc """
    sweep(circuit, parameter_path => values; analysis=OperatingPoint(),
          metric=identity) -> SweepResult

Evaluate an analysis after each numerical parameter update, reusing compiled
topology. Paths are symbols or strings such as `"R1.value"` or
`"First.R1.value"`. A bare component name implies its `value` field. The input
circuit is not modified. Topology-changing updates require rebuilding instead.

```julia
study = sweep(compile(circuit), "R1.value" => [1kΩ, 2kΩ];
    analysis=SmallSignal([1kHz]; source=:Source),
    metric=r -> abs(only(voltage(r, :out))))
@assert failure_rate(study) == 0
```

`metrics` preserves input order, with `nothing` at failed points. `simulations`
retains individual results when available; `converged` and `failures` identify
analysis or metric-callback failures. `successful(study)` omits failures: report
`failure_rate(study)` as well. See [`with_parameters`](@ref), [`monte_carlo`](@ref).
""" sweep
@doc """    noise(circuit, frequencies; output, input=nothing, points=100, scale=:log,
          temperature=300.0, contributions=true, bias=nothing, ...)

Compute stationary small-signal noise about a converged operating point.
`frequencies` is a positive Hz vector or a `low => high` range. `output` is an
observable such as `voltage(:out)`; `input` is an independent-source name such
as `:Source`, enabling input referral. Temperature is in kelvin.

```julia
n = noise(circuit, 10Hz => 1MHz; output=voltage(:out), input=:Source)
density = noise_density(n)                  # V/sqrt(Hz) for voltage output
rms = integrated_noise(n, 20Hz => 20kHz)     # V RMS
```

`noise_psd` returns squared output units per Hz. The default `contributions=true`
retains individual source budgets. Inspect `report(n)` and `validity_report(n)`;
zero noise may mean the selected device models have no configured noise.""" noise
@doc """Frequency-indexed stationary noise result containing PSDs and physical-source contributions.""" NoiseResult
@doc """Run seeded fixed-grid stochastic backward-Euler noise simulation.""" transient_noise
@doc """Descriptor retained by a fixed-grid stochastic transient result.""" TransientNoise
@doc """Propagate periodically time-varying noise through a converged PSS orbit.""" periodic_noise
@doc """Sideband-folded periodically time-varying noise result.""" PeriodicNoiseResult
@doc """Compute autonomous-oscillator single-sideband phase noise.""" phase_noise
@doc """Autonomous-oscillator phase and amplitude noise result.""" PhaseNoiseResult

@doc """
    frequencies(result)

Return the result's frequency vector in Hz for supported frequency-domain
results, including small-signal, noise, and network results. The values are in
the same order as their associated traces. For a transient use `result.axis`
instead. Treat returned arrays as read-only.

```julia
f_Hz = frequencies(ac)
```
""" frequencies
@doc """
    trace(result, observable)
    trace(result, name)

Evaluate an `Observable` or a named design observation and return its vector.
A name that is not a registered observation falls back to node-voltage lookup.
Use symbols or hierarchy-qualified strings for names. Units depend on the
observable; even a DC trace is a one-element vector.

```julia
y = trace(tr, voltage(:out))
y_named = trace(tr, :output)  # registered with observe(...; name=:output)
```

Use [`observation`](@ref) if you want to require a registered observation rather
than allow fallback to a node name.
""" trace
@doc """
    transfer(result::SimulationResult; input, output)

Return the elementwise ratio of the output trace to the input trace. Both
keywords require `Observable` objects, e.g. `voltage(:vin)`, not bare symbols.
For small-signal results this is a complex transfer function sampled at
`frequencies(result)`. Units follow the chosen ratio (V/V, V/A, etc.).

```julia
H = transfer(ac; input=voltage(:vin), output=voltage(:out))
gain_dB = db20(H)
```

No zero-denominator guard or normalization is applied. A zero/missing source
excitation may produce `NaN` or `Inf`; inspect the analysis warnings first.
""" transfer
@doc """Convert an amplitude-like value or array to decibels using `20log10(abs(x))`.""" db20
@doc """Convert a power-like value or array to decibels using `10log10(abs(x))`.""" db10
@doc """Compute group delay from an unwrapped complex frequency response.""" group_delay
@doc """Compute phase delay from a complex frequency response.""" phase_delay
@doc """Find interpolated level crossings on a frequency grid.""" crossings
@doc """
    cutoff_frequencies(result; input, output, reference=..., level_db=-3.0)
    cutoff_frequencies(frequencies, response; reference=first(abs.(response)),
                       level_db=-3.0)

Return a vector of Hz crossings of `db20(reference) + level_db`. The default
reference is the magnitude of the first sampled response, not its maximum or a
separately computed DC gain. All crossings in the sampled band are returned;
there may be none or several. Crossings interpolate between neighboring samples,
in log frequency when both endpoints are positive.

```julia
corners = cutoff_frequencies(ac; input=voltage(:vin), output=voltage(:out))
```

For a simple low-pass, start sufficiently below its pole; for band-pass or
peaking responses, choose `reference` explicitly. Refine the frequency grid to
check the reported crossings before applying `only(corners)`.
""" cutoff_frequencies
@doc """A contiguous frequency interval satisfying a response threshold.""" FrequencyBand
@doc """Find threshold-qualified passbands in a frequency response.""" passbands
@doc """Return the width of a frequency band or selected response passband.""" bandwidth
@doc """A sampled local maximum in a frequency response.""" Resonance
@doc """Find local maxima in a sampled frequency response.""" resonances
@doc """Estimate resonance Q from interpolated half-power crossings.""" quality_factor
@doc """Return maximum response gain above a reference, in decibels.""" peaking
@doc """Return the deepest response attenuation below a reference, in decibels.""" notch_depth
@doc """    integrated_noise(result::NoiseResult, low => high; referred=:output,
        interpolate_edges=true, quantity=:rms, contributions=false)

Integrate PSD over a band in Hz within the simulated frequency range. The default
returns RMS noise (V for a voltage output); `quantity=:variance` returns squared
units. `referred=:input` requires a noise analysis with an input source.
Band edges are interpolated by default; set `interpolate_edges=false` to require
sampled edges. With `contributions=true`, return a named tuple containing `total`
and a `contributions` dictionary keyed by source. For uncorrelated sources, individual RMS contributions
combine in quadrature, not by direct addition.

```julia
rms_V = integrated_noise(n, 20Hz => 20kHz)
budget = integrated_noise(n, 20Hz => 20kHz; contributions=true)
```""" integrated_noise

@doc """An oriented small-signal port with current positive into its positive terminal.""" Port
@doc """Frequency-indexed multiport impedance data and port metadata.""" NetworkResult
@doc """Excite oriented ports and compute a bias-linearized network response.""" port_response
@doc """Return Z, Y, S, hybrid, or ABCD matrices from a network result.""" network_parameters
@doc """Return the impedance matrix of a network result.""" impedance
@doc """Return the admittance matrix of a network result.""" admittance
@doc """Return a network result with new positive real reference impedances.""" renormalize

@doc """Calibrated one-sided FFT, RMS-amplitude, and power-spectral-density data.""" SpectrumResult
@doc """A measured harmonic with order, frequency, RMS amplitude, phase, and bin.""" HarmonicComponent
@doc """Fundamental, harmonic table, and standard distortion metrics.""" HarmonicResult
@doc """Compute a calibrated spectrum from a transient result.""" spectrum
@doc """Measure a fundamental, harmonics, distortion, noise, and dynamic range.""" harmonic_analysis
@doc """Return total harmonic distortion.""" thd
@doc """Return total harmonic distortion plus noise.""" thdn
@doc """Return signal-to-noise ratio in decibels.""" snr
@doc """Return signal-to-noise-and-distortion ratio in decibels.""" sinad
@doc """Return spurious-free dynamic range in decibels.""" sfdr
@doc """Estimate effective number of bits from SINAD.""" enob
@doc """Return waveform peak divided by RMS value.""" crest_factor
@doc """Integrate a spectrum PSD over a frequency band.""" band_power

@doc """Native descriptor-system linearization of an Amber circuit.""" LinearizedModel
@doc """MIMO frequency response of a native descriptor model.""" LinearFrequencyResponse
@doc """MIMO time response of a native descriptor model.""" TimeResponse
@doc """Linearize a circuit into `E*x' = A*x + B*u`, `y = C*x + D*u`.""" linearize
@doc """Evaluate a descriptor model on a frequency grid.""" frequency_response
@doc """Return the descriptor model's DC gain matrix.""" dcgain
@doc """Return finite generalized poles, optionally including infinite modes.""" poles
@doc """Return SISO transmission zeros from the Rosenbrock pencil.""" transmission_zeros
@doc """Return natural frequencies of finite descriptor poles.""" natural_frequencies
@doc """Return damping ratios of finite descriptor poles.""" damping_ratios
@doc """Test whether every finite descriptor pole lies in the open left half-plane.""" isstable
@doc """Find unity-gain crossover frequencies.""" gain_crossovers
@doc """Find negative-180-degree phase crossover frequencies.""" phase_crossovers
@doc """SISO gain margin, phase margin, and associated crossover frequencies.""" StabilityMargins
@doc """Compute classical SISO stability margins.""" stability_margins
@doc """Return the classical gain margin.""" gain_margin
@doc """Return the classical phase margin.""" phase_margin
@doc """Compute `1/(1+L)` from loop-gain values.""" sensitivity
@doc """Compute `L/(1+L)` from loop-gain values.""" complementary_sensitivity
@doc """Compute a BDF step response of a descriptor model.""" step_response
@doc """Compute a BDF impulse response of a descriptor model.""" impulse_response
@doc """Measure fractional-level rise time.""" rise_time
@doc """Measure final-value settling time.""" settling_time
@doc """Return the sampled response peak time.""" peak_time
@doc """Return target minus final response value.""" steady_state_error
@doc """Compute closed-loop generalized poles over a gain vector.""" root_locus

@doc """Abstract zero-DC feedback injection specification.""" AbstractLoopProbe
@doc """Two-injection loop probe: a zero-volt series wire and endpoint voltage relative to the loop reference.""" VoltageLoopProbe
@doc """Two-injection loop probe: a zero-DC shunt current source and current through a zero-volt series sensing source.""" CurrentLoopProbe
@doc """Loop-gain samples, margins, probe, and bias-preservation metadata.""" LoopGainResult
@doc """Compute the Tian two-injection return ratio with return difference 1 + L; the probed wire must intersect all return paths under study.""" loop_gain
@doc """Return sensitivity from a loop-gain result.""" loop_sensitivity
@doc """Return complementary sensitivity from a loop-gain result.""" closed_loop_response

@doc """Fixed-period shooting-analysis descriptor.""" PeriodicSteadyState
@doc """Converged periodic orbit, shooting residual, monodromy, and Floquet data.""" PSSResult
@doc """Solve driven or autonomous periodic steady state with variational Floquet data.""" periodic_steady_state
@doc """Return the Floquet multipliers of a periodic steady-state result.""" floquet_multipliers
@doc """Return the magnitude of a complex result trace.""" magnitude
@doc """Return the phase of a complex result trace in radians.""" phase
@doc """Classify the operating region of a supported nonlinear device.""" region
@doc """BJT forward-active operating-region marker.""" ForwardActive
@doc """BJT saturation operating-region marker.""" Saturation
@doc """BJT cutoff operating-region marker.""" Cutoff
@doc """MOSFET linear/triode operating-region marker.""" Triode
@doc """
    provenance(result) -> Dict

Return reproducibility metadata for the supplied result. Simulation metadata
includes Amber version, circuit/topology/parameter fingerprints, parameter
snapshots, analysis kind, SI unit convention, and solver statistics/warnings.
Study results provide analysis-specific metadata such as seeds and failures.

```julia
metadata = provenance(op)
```

This is metadata, not a complete executable environment or serialized waveform.
Keep the Julia circuit source and project/manifest files as well. See
[`report`](@ref), [`save_circuit`](@ref), [`save_monte_carlo`](@ref).
""" provenance
@doc """    report(result::SimulationResult; detailed=false, window=nothing)

Return a structured summary with analysis type, sampled interval, sample count,
solver statistics, device findings, and combined solver/model-validity warnings.
By default, omit per-iteration and per-step histories from the statistics. Use
`detailed=true` for all statistics, or inspect `result.stats` directly.
Reports display as readable engineering summaries, including warnings and units:
`println(report(result))`. Key-based access remains available, e.g.
`report(result)[:warnings]`; use `Dict(report(result))` for a plain dictionary.

For transient results, `window=start => stop` selects the saved samples used
for device metrics (inclusive bounds, in seconds). The default covers the full
saved record, including startup. Bounds must be finite, ordered, inside the
saved record, and contain at least one saved sample. No boundary interpolation
is performed. `:device_window` records requested and actual bounds, sample
count, scope, units and RMS method; `:interval` and `:samples` still describe
the whole simulation. RMS current is the square root of a trapezoidal integral
of squared current divided by elapsed time; a single sample uses its magnitude.
The caller chooses the window; no settling detection is performed.
Other result types provide analysis-specific summaries.""" report
@doc """
    validity_report(result; window=nothing) -> Dict

Return model-domain findings and warnings, distinct from numerical convergence.
For simulation results, keys include `:devices` and `:warnings`; other analyses
provide their own findings. For example, capacitor ripple current can be
reported while its thermal validity remains unevaluated because no rating was
supplied. Findings may require reconstructing device traces. Simulation results
also include `:device_window`; transient `window` selection and RMS conventions
match [`report`](@ref). Solver warnings always describe the whole run.

```julia
findings = validity_report(tr)
println(findings[:warnings])
```

An empty warning list is not proof of hardware safety or a calibrated physical
model. Use `result.stats[:converged]` or [`explain_failure`](@ref) for numerical
status. See [`report`](@ref).
""" validity_report
@doc """
    available_observables(device)

Return the observable kinds declared by a device's equation contract. Pass a
device record from `devices(circuit)`, not a simulation result. This describes
supported device quantities, not the named measurements registered by `observe`.

```julia
kinds = available_observables(first(devices(circuit)))
```

Use [`observations`](@ref) for named measurements and `voltage`/`current`/`power`
with a simulation result to obtain actual traces.
""" available_observables
@doc """
    compare(reference::SimulationResult, candidate::SimulationResult; observable)

Compare one signal on identical saved axes. Returns a `Comparison` with `axis`,
`reference`, `candidate`, and `error` vectors; error is candidate minus reference.
`observable` can be an observable object or a node name. Different axes raise
`ArgumentError`; this helper does not interpolate or align records.

```julia
difference = compare(coarse, fine; observable=voltage(:out))
```

Use the same `saveat` and interval when comparing timestep-refinement runs.
Agreement between runs is evidence of numerical consistency, not by itself a
validation of the physical model.
""" compare
@doc """
    peak_to_peak(observable; window=nothing) -> callable_metric

Build a measurement callable on a `SimulationResult`. It returns the maximum
minus minimum real part of the observable over the saved samples within the
inclusive window. Units follow the observable. With no window, use the whole
record; a window with no samples raises `ArgumentError`.

```julia
ripple_V = peak_to_peak(voltage(:out); window=2ms => 5ms)(tr)
```

This constructs a metric first and then applies it. It does not interpolate
unsaved extrema. Use a settled window and sufficiently fine output sampling
for ripple or overshoot measurements.
""" peak_to_peak
@doc """Compute acquisition and hold errors for sampled waveforms.""" sampling_metrics
@doc """Measure threshold-crossing delay between two waveforms.""" propagation_delay
@doc """Measure excursion beyond a specified final or reference value.""" overshoot
@doc """
    noise_psd(result::NoiseResult)

Return the one-sided output power spectral density vector, aligned with
`frequencies(result)`. For a voltage output the units are V^2/Hz; for current,
A^2/Hz. It is not an RMS amplitude or a per-bin power. Treat the returned array
as read-only. See [`noise_density`](@ref), [`integrated_noise`](@ref).
""" noise_psd
@doc """
    noise_density(result::NoiseResult)

Return the square root of the one-sided output PSD, aligned with the frequency
axis. Units are V/sqrt(Hz) for voltage or A/sqrt(Hz) for current. Integrate the
PSD, not this density directly, to obtain mean-square noise; use
`integrated_noise(result, low => high)` for RMS noise over a band.
""" noise_density
@doc """
    input_referred_noise_psd(result::NoiseResult)

Return input-referred one-sided PSD, or `nothing` if `noise` was called without
an `input` source. Units are the input source's squared units per Hz. Frequencies
with zero transfer can have nonfinite referral; check the circuit's gain and
analysis warnings. See [`noise`](@ref), [`input_referred_noise_density`](@ref).
""" input_referred_noise_psd
@doc """
    input_referred_noise_density(result::NoiseResult)

Return the square root of input-referred PSD, or `nothing` when input referral
was not requested. Units follow the input source: V/sqrt(Hz) for voltage
excitation or A/sqrt(Hz) for current excitation. Use
`integrated_noise(result, band; referred=:input)` for band-integrated RMS noise.
""" input_referred_noise_density
@doc """
    noise_contributions(result::NoiseResult; component=nothing, mechanism=nothing)

Return physical-source contribution records, optionally filtered by component
name and/or noise mechanism (such as `:thermal`). Each record includes source
and component identifiers, mechanism, and frequency-aligned PSD vectors.

```julia
thermal = noise_contributions(n; mechanism=:thermal)
```

These are spectra, not band-integrated RMS values. Use
`integrated_noise(n, band; contributions=true)` for an integrated budget. Request
`contributions=true` (the default) when running `noise` to retain these records.
""" noise_contributions
@doc """Return linear noise factor relative to a thermal source resistance.""" noise_figure
@doc """A differential small-signal excitation or observation specification.""" Differential

@doc """
    Gaussian(mean, sigma)

Independent normal distribution for an absolute parameter value. `sigma` is a
nonnegative standard deviation in the same units as the parameter; it is not a
percentage or a worst-case tolerance. Both arguments must be finite.

```julia
variation = Gaussian(10kΩ, 100Ω)  # 1% standard deviation, not ±1% limits
```

Normal draws are unbounded and may create invalid negative device values.
Such samples remain failures in `monte_carlo`; use `LogNormal` or
`UniformVariation` when their distributions match the intended experiment.
""" Gaussian
@doc """
    LogNormal(logmean, logsigma)

Positive log-normal variation: `log(value)` is normally distributed with mean
`logmean` and nonnegative standard deviation `logsigma`. These are log-space
parameters, not the arithmetic mean and standard deviation of the component.
Use SI-scaled numeric values before taking the logarithm.

```julia
variation = LogNormal(log(47nF), 0.03)  # median 47 nF
```

The arithmetic mean is `exp(logmean + logsigma^2/2)`. Arguments must be finite.
See [`monte_carlo`](@ref), [`Gaussian`](@ref).
""" LogNormal
@doc """
    UniformVariation(low, high)

Uniform absolute parameter variation between finite bounds with `low <= high`.
Both bounds use the parameter's units. Equal bounds give a constant value.

```julia
variation = UniformVariation(9.9kΩ, 10.1kΩ)
```

Unlike `Gaussian(10kΩ, 100Ω)`, this distribution bounds all resistance draws
within ±1%. Choose distributions from the intended tolerance/process model.
See [`monte_carlo`](@ref).
""" UniformVariation
@doc """
    ProcessVariation(variations::AbstractDict)
    ProcessVariation(; parameter_path=distribution, ...)

Group parameter distributions to pass as `process` to `monte_carlo`. Values are
absolute parameter distributions, as in its `variations` keyword. This container
does not by itself correlate different parameter paths: use `CorrelatedVariation`
for a covariance-defined relationship. Do not repeat paths across variation
specifications.

```julia
process = ProcessVariation(Dict(Symbol("R1.value") => Gaussian(1kΩ, 10Ω)))
```

See [`monte_carlo`](@ref), [`sample_parameters`](@ref).
""" ProcessVariation
@doc """A multivariate normal parameter variation defined by means and covariance.""" CorrelatedVariation
@doc """Definition of components sharing process variation with local mismatch.""" MatchedGroup
@doc """Construct a `MatchedGroup` for statistically matched components.""" matched_group
@doc """Captured failure information for one Monte Carlo sample.""" MonteCarloFailure
@doc """Complete reproducible Monte Carlo artifact containing draws, metrics, failures, seed, and provenance.""" MonteCarloResult
@doc """
    monte_carlo(circuit; analysis=OperatingPoint(), samples=1000, seed=0,
                variations=nothing, metric=identity, metrics=nothing,
                parallel=false, store_parameters=true, ...)

Run reproducible parameter-variation trials and return a `MonteCarloResult`.
`variations` maps parameter paths to distributions of absolute values, not
implicit percentages. `metric(result)` extracts each sample's measurement;
`metrics` accepts a named tuple, dictionary, or vector of measurement functions
instead. `process` supplies another set of distributions; `correlated` defines
covariance-linked draws. Component tolerance/match metadata can also generate
draws; explicitly supplied paths take precedence for those parameters.

```julia
mc = monte_carlo(circuit; samples=100, seed=42,
    variations=Dict(Symbol("R1.value") => Gaussian(1kΩ, 10Ω)),
    metric=r -> only(voltage(r, :out)))
println(report(mc))
```

Results retain sample values, success flags, failure records, and per-sample
seeds. Parameter draws are retained unless `store_parameters=false`.
`parallel=true` uses Julia threads; callbacks must be safe for concurrent use.
The input circuit is unchanged. Keep failures in yield accounting and report
sample count and seed. Failed analyses/metrics do not abort the whole study;
interrupts do. See [`replay_sample`](@ref), [`yield_rate`](@ref).
""" monte_carlo
@doc """
    replay_sample(result::MonteCarloResult, circuit, index; metric=identity)

Rerun a successful sample using its stored parameter draws and original analysis.
`circuit` must match the original base circuit fingerprint, and the study must
have retained parameters (`store_parameters=true`, the default). Indices are
one-based; failed samples cannot be replayed through this helper.

Return the simulation result by default, or `metric(simulation)` if supplied.
The original metric callback is not stored: pass it again when needed.

```julia
replayed = replay_sample(mc, circuit, 1; metric=r -> only(voltage(r, :out)))
```

Inspect `mc.failures` to investigate failed samples instead.
""" replay_sample
@doc """
    sample_values(result::MonteCarloResult)

Return the stored metric-value vector in sample order, with `nothing` for failed
samples. These are measurements, not the random parameter draws. With the default
identity metric, successful entries are simulation results. Index the returned
vector to select one sample; treat it as read-only.

```julia
first_measurement = sample_values(mc)[1]
```

Use `result.converged` to distinguish failures from a metric that itself returns
`nothing`. See [`sample_parameters`](@ref), [`successful`](@ref).
""" sample_values
@doc """
    sample_parameters(result::MonteCarloResult)

Return the vector of per-sample parameter-draw dictionaries, keyed by parameter
path symbols. These contain sampled overrides, not every nominal circuit
parameter. Index the vector to select one sample; treat returned dictionaries as
read-only so that replay and provenance remain trustworthy.

```julia
first_draws = sample_parameters(mc)[1]
```

When `store_parameters=false`, these dictionaries are empty and replay is
unavailable. Draws may also be empty when no parameter was varied. Failed samples
may retain partial draws; inspect `result.failures` and `result.converged`.
""" sample_parameters
@doc """
    successful(result::Union{SweepResult,MonteCarloResult})

Return measurement values for successful points only, preserving their original
order. With the default identity metric these may be simulation results.
Failed points are omitted rather than replaced; use `result.converged` and
`result.failures` when correlating values with the original point indices.
Always report [`failure_rate`](@ref) alongside a successful-only summary.
""" successful
@doc """
    failure_rate(result::Union{SweepResult,MonteCarloResult}) -> Float64

Return the fraction of attempted points/samples that failed, including analysis
and metric-callback failures. The result lies in `[0, 1]`; an empty study returns
`0.0`. It is not the fraction that missed an engineering specification: use
[`yield_rate`](@ref) for that. See `result.failures` for recorded reasons.
""" failure_rate
@doc """
    yield_rate(result::MonteCarloResult, predicate) -> Float64

Return the number of successful samples whose measurement satisfies `predicate`,
divided by the total number of samples. Failed samples count against yield;
they are not silently removed from the denominator. Empty studies return `NaN`.

```julia
yield_fraction = yield_rate(mc, output_V -> 0.9V <= output_V <= 1.1V)
```

The predicate receives the stored metric value, not necessarily a simulation
result. Report the sample count, failure rate, and a `yield_confidence_interval`
with any statistical yield claim.
""" yield_rate
@doc """Compute a confidence interval for a numeric Monte Carlo metric.""" confidence_interval
@doc """Compute a binomial confidence interval for estimated yield.""" yield_confidence_interval

@doc """
    check(design::CircuitDesign) -> Vector{Diagnostic}

Check structural validity and return diagnostics with `severity` and `message`
fields. An empty vector means no structural issues were detected; it does not
establish numerical convergence or physical model accuracy. Checks include
missing references, floating DC islands, and conflicting ideal constraints.

```julia
issues = check(circuit)
isempty(issues) || error(explain(circuit))
```

Use `check(compiled.design)` for a compiled circuit. This routine performs
structural compilation internally but does not solve a bias point. Analyses
also validate during compilation and throw `CircuitValidationError` on
structural errors. See [`explain`](@ref), [`compile`](@ref).
""" check
@doc """
    describe(design::CircuitDesign; depth=2, limit=100) -> String

Return a human-readable overview of a design, including hierarchy and primitive
counts. `depth=0` omits the instance list; positive depth includes it, with
`limit` bounding the number of listed instances. It does not run an analysis. Print the
returned string to inspect the topology and names before selecting results or
parameter paths.

```julia
println(describe(circuit))
```

Use `describe(compiled.design)` for a compiled circuit. For a structural
validation explanation use [`explain`](@ref); for programmatic inspection use
`summary`, `nets`, `devices`, and `resolve`.
""" describe
@doc """
    explain(design::CircuitDesign) -> String

Return a short structural overview followed by `check(design)` findings and
severity labels. The output suggests corrections such as adding a DC bias path.
It reports structural readiness, not successful simulation or physical validity.

```julia
println(explain(circuit))
```

For a failed simulation or exception, use [`explain_failure`](@ref) instead.
""" explain
@doc """
    explain_failure(result) -> String
    explain_failure(error::Exception) -> String

Explain solver completion or failure using the result's diagnostic statistics.
For a partial transient, include saved coverage, requested stop, recorded
warnings, and relevant next steps. When available, name the equation/node with
the dominant residual. For a converged result, report convergence instead.

```julia
println(explain_failure(tr))
```

The exception overload formats its error message. Study failures are stored in
`sweep_result.failures` or `mc.failures`; inspect those records directly.
This function does not retry the solve. See [`validity_report`](@ref) for model
limitations, which are separate from numerical failure.
""" explain_failure
@doc """Invalid circuit structure or parameter error.""" CircuitValidationError
@doc """Invalid analysis configuration error.""" AnalysisValidationError
@doc """Nonlinear solver convergence failure with diagnostic context.""" ConvergenceError
@doc """Sparse or dense linear-system solution failure.""" LinearSolveError
@doc """Circuit or result serialization format error.""" CircuitSerializationError

@doc """Return the deterministic, serializable snapshot representation of a circuit.""" circuit_snapshot
@doc """Serialize a supported circuit to versioned TOML text.""" serialize_circuit
@doc """Deserialize versioned TOML text into a circuit.""" deserialize_circuit
@doc """Save a supported circuit to a TOML file.""" save_circuit
@doc """Load a circuit from an Amber TOML file.""" load_circuit
@doc """Serialize a `MonteCarloResult` to versioned TOML text.""" serialize_monte_carlo
@doc """Deserialize a `MonteCarloResult` from versioned TOML text.""" deserialize_monte_carlo
@doc """Save a `MonteCarloResult` to a TOML file.""" save_monte_carlo
@doc """Load a `MonteCarloResult` from an Amber TOML file.""" load_monte_carlo


@doc """
    finish(builder::CircuitBuilder) -> CircuitDesign

Freeze the accumulated builder into a design and invalidate its mutable handles.
Finishing is a one-time operation: further additions or another `finish` call
raise an error. It does not solve the circuit or guarantee valid topology;
run `check(design)` before simulation.

```julia
design = finish(builder)
```

See [`CircuitBuilder`](@ref), [`compile`](@ref).
""" finish

@doc """
    @subcircuit Name(port1, port2, ...; parameters...) begin
        # local devices and nets
    end

Define a reusable template with explicit terminal ports. Include a reference
port when needed; do not call `ground()` inside the block. Instantiating the
template inside `@circuit` retains hierarchy and stable local component names.

```julia
@subcircuit HelpSection(input, output, reference; R=1kΩ, C=1μF) begin
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, reference; value=C)
end
@circuit HelpCascade begin
    gnd = ground(); vin = node(); out = node()
    Source = voltage_source(vin, gnd; dc=1V, ac=1V)
    First = HelpSection(vin, out, gnd; R=2kΩ)
end
```

The template alone is not a grounded top-level circuit. In `HelpCascade()`, use
`"First.R1"` for device lookup and `"First.R1.value"` for parameter updates.
See [`@circuit`](@ref), [`with_parameters`](@ref).
""" :(@subcircuit)

const _documented_unit_families=(
    (:Ω,"ohm"),(:V,"volt"),(:A,"ampere"),(:F,"farad"),(:H,"henry"),
    (:C,"coulomb"),(:s,"second"),(:Hz,"hertz"),(:S,"siemens"),(:K,"kelvin"),
)
const _documented_prefixes=((:f,"femto"),(:p,"pico"),(:n,"nano"),(:μ,"micro"),
    (:m,"milli"),(:k,"kilo"),(:M,"mega"),(:G,"giga"),(:T,"tera"))
const _documented_units=Pair{Symbol,String}[]
for (unit,description) in _documented_unit_families
    push!(_documented_units,unit=>description)
    for (prefix,prefix_description) in _documented_prefixes
        push!(_documented_units,Symbol(prefix,unit)=>(prefix_description*description))
    end
end
push!(_documented_units,:m=>"metre")
for (prefix,prefix_description) in _documented_prefixes
    prefix===:m&&continue
    push!(_documented_units,Symbol(prefix,:m)=>(prefix_description*"metre"))
end
push!(_documented_units,:mm=>"millimetre")
append!(_documented_units,[:dB=>"decibel amplitude conversion",:percent=>"percent scale factor",:°=>"degree-to-radian conversion"])

for (name, description) in _documented_units
    @eval @doc $("Numeric SI scale factor for one " * description * ".") $name
end

@doc """
    ChargeBasedMOSFET(; threshold_voltage=0.7, slope_factor=1.3, mobility=0.04,
                       oxide_capacitance=5e-3, width=1e-6, length=1e-6, kw...)

Native quasi-static long-channel model with continuous inversion, symmetric
transport, geometry scaling, Ward–Dutton terminal charge partition, optional
junctions/overlaps, and explicit temperature laws. Defaults are illustrative.
Geometry is in SI units and may also be supplied to `nmos`/`pmos`.
Use `mosfet_operating_point` for sizing quantities and `terminal_charges` for
charge data. This is not a full EKV, SPICE Level 2, or foundry model. See the
manual's Charge-based MOSFET page for equations, parameters and physical limits.
""" ChargeBasedMOSFET

for name in _RESISTOR_MATERIAL_NAMES
    name===:ThinFilm && continue
    @eval @doc $("$(name) resistor technology. Explicit excess_noise_coefficient, excess_current_exponent (2), excess_frequency_exponent (1), and excess_reference_frequency (1 Hz). Noise coefficient defaults to zero; temperature/voltage coefficients are unsupported. See design_specs/passive_model_catalog.md.") $(name)
end
for name in _PASSIVE_PACKAGE_NAMES
    name===:SMD0603 && continue
    @eval @doc $("$(name) passive package. Explicit resistor series_inductance/parallel_capacitance or capacitor esr/esl; all default to zero. SMD names use imperial size codes. No geometry-derived defaults. See design_specs/passive_model_catalog.md.") $(name)
end
for name in _CAPACITOR_DIELECTRIC_NAMES
    name===:C0G && continue
    @eval @doc $("$(name) capacitor technology. Nonzero loss_tangent requires reference_frequency (Hz); elaborates to constant series R = tan(delta)/(2pi*f*C), added to ESR. Loss defaults to zero. No bias, temperature, aging, or polarity behavior. See design_specs/passive_model_catalog.md.") $(name)
end
