# Amber.jl

Amber is an MIT-licensed, native Julia environment for constructing and
simulating analog electronic circuits. Circuits are ordinary Julia objects;
the initial solver implements operating-point, native BDF transient,
small-signal AC, and noise analysis without an external SPICE engine.

```julia
using Amber

@circuit LowPass(; R = 10kΩ, C = 10nF) begin
    gnd = ground()
    vin = node()
    vout = node()
    source(vin, gnd; ac = 1V)
    resistor(vin, vout; value = R)
    capacitor(vout, gnd; value = C)
    observe(vout)
end

result = small_signal(LowPass(), 10Hz => 1MHz)
response = voltage(result, :vout)
```

The macro is optional. The same topology can be generated with `Circuit`,
`node!`, `ground!`, and `add!`, including ordinary loops and functions.

The initial implementation currently includes:

- hierarchical circuit composition with stable instance paths;
- sparse generalized MNA assembly and reusable compiled topology;
- resistors, capacitors, inductors, independent sources, junction diodes,
  simple BJTs, analog switches, and behavioral op-amps;
- package parasitics, capacitor dielectric-absorption branches, conservative
  diode junction charge, and behavioral op-amp pole/input effects;
- source stepping, temporary gmin continuation, BDF1/BDF2 integration, and
  exact insertion of waveform events;
- structural diagnostics, parameter sweeps, experiment overrides,
  provenance, device observables, and common waveform measurements.
- reproducible Monte Carlo analysis with explicit parameter distributions,
  component tolerances, matched-BJT mismatch, failure capture, and statistical
  result helpers.

Monte Carlo runs retain each sampled parameter set and seed, while the `metric`
controls memory use:

```julia
using Amber, Statistics

mc = monte_carlo(
    LowPass();
    analysis = OperatingPoint(),
    samples = 1_000,
    seed = 42,
    variations = Dict(Symbol("R1.value") => Gaussian(10kΩ, 500Ω)),
    metric = result -> voltage(result, :vout)[1],
)

mean(mc)
quantile(mc, 0.95)
yield_rate(mc, value -> value > 0.9V)
failure_rate(mc)
```

Components with a numeric `tolerance` parameter are varied uniformly around
their nominal value. NPN devices sharing a `MatchedGroup` receive reproducible,
correlated saturation-current and beta mismatch.

Run the test suite with:

```julia
using Pkg
Pkg.test()
```

Executable reference circuits live under `examples/`. Sensitivity/optimization,
graphical rendering, and optional package
integrations are deliberately deferred; they are not silently emulated by
the initial core.

See `initial_design_docs.md` for the architecture and `examples.md` for the
full reference circuit gallery.
