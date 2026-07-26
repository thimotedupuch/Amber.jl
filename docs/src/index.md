# Amber.jl

Amber lets you describe an analog circuit in Julia, run the analyses that
answer practical design questions, and inspect the results with ordinary Julia
code. Use it to explore a circuit, automate a parameter study, teach how a
model behaves, or keep a simulation next to the code and data that depend on
it. Circuits are reusable Julia objects, so the same definition can serve an
operating-point check, a frequency response, a transient simulation, and a
larger reproducible experiment.

```@example home
using Amber

@circuit LowPass(; R=10kΩ, C=10nF) begin
    gnd = ground()
    input = node()
    output = node()
    Source = voltage_source(
        input,
        gnd;
        dc=0V,
        ac=1V,
        waveform=Step(low=0V, high=1V, at=100μs),
    )
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, gnd; value=C)
    observe(voltage(output))
end

circuit = LowPass(R=4.7kΩ, C=22nF)
check(circuit)
bias = operating_point(circuit)
ac = small_signal(circuit, 10Hz => 1MHz; source=:Source, points=100)
startup = transient(circuit, 0s => 1ms; saveat=10μs)
(
    voltage(bias, :output)[1],
    magnitude(voltage(ac, :output))[1],
    voltage(startup, :output)[end],
)
```

Amber currently provides operating-point, adaptive or fixed-grid BDF
transient, small-signal AC, stationary and stochastic noise, periodic noise,
and oscillator phase-noise analyses. Its component library
includes passive devices, controlled sources, junction diodes, an Ebers--Moll
BJT, behavioral op-amps, and smooth or event switches. The emphasis is on a
small coherent core whose equations, Jacobians, convergence order, and
conservation properties are checked against native mathematical references.

## Choose a path

- New to Amber: start with [Installation](@ref), [Your first circuit](@ref),
  and [Reading results](@ref).
- Building programmable experiments: see [Circuit construction](@ref),
  [hierarchical composition](@ref "Hierarchy and reusable subcircuits"),
  [parameter sweeps](@ref "Parameter sweeps"), and [Monte Carlo analysis](@ref).
- Evaluating numerical behavior: read [Nonlinear solving](@ref),
  [Transient integration](@ref), and [Verification strategy](@ref).
- Contributing devices or solvers: begin with [Architecture](@ref) and
  [Device contract](@ref).

## Scope

Amber is at an early stage. It deliberately does not pretend to implement the
full device catalog or every physical effect of mature circuit simulators.
Each model's included effects and limitations are stated in
[Physical model scope](@ref). Numerical failures are exposed through result status,
warnings, structured exceptions, and [`explain_failure`](@ref).
