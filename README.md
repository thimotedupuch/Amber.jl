# Amber.jl

Amber is an MIT-licensed, native Julia environment for constructing and simulating analog electronic circuits. Circuits are ordinary Julia objects; Amber takes a compiler-centric approach to analog simulation by translating user-defined circuits into an explicit **Circuit IR**, which is then mapped into a **hierarchical compiled circuit** with a highly optimized, reusable sparse generalized MNA topology.

The solver suite implements operating-point, native BDF1/BDF2 transient, small-signal AC, frequency-domain noise propagation, and **harmonic/spectral analysis** without relying on an external SPICE engine.

```julia
using Amber

@circuit LowPass(; R = 10kΩ, C = 10nF) begin
    gnd = ground()
    vin = node()
    vout = node()
    
    # Typed quantities and intuitive primitives replace SPICE netlists
    voltage_source(vin, gnd; ac = 1V)
    resistor(vin, vout; value = R)
    capacitor(vout, gnd; value = C)
    
    observe(vout)
end

# Analyze directly using Julia code
result = small_signal(LowPass(), 10Hz => 1MHz)
response = voltage(result, :vout)
```

The `@circuit` macro is optional. The same topology can be generated programmatically with `Circuit`, `node!`, `ground!`, and `add!`, including ordinary Julia control flow (`for` loops and `if` statements).

### Key Features & Compiler Architecture

- **Circuit IR & Hierarchical Compilation**: Amber lowers user-defined circuits into an intermediate representation. This allows for rigorous structural linting, parameter validation, and extraction of stable instance paths before the numerical solver runs.
- **Compiled Reusable Topology**: The sparse MNA Jacobian structure is compiled once. Repeated analyses (like Monte Carlo or parameter sweeps) dynamically update values in pre-allocated sparse arrays, yielding massive speedups and minimal memory allocation.
- **Robust Convergence Strategies**: Solvers gracefully handle difficult nonlinear constraints, employing sophisticated strategies like **source stepping** and **temporary gmin continuation** to achieve convergence where simple Newton-Raphson solvers would otherwise diverge.
- **Control Theory Integration**: With small-signal linearization, Amber exposes a genuine AC operating point that acts as a bridge to linear control theory. This makes it simple to extract magnitude, wrapped/unwrapped phase, and compute loop-gain, tracking transfer characteristics of amplifiers and feedback loops.
- **Rich Device Models**: Resistors, capacitors, inductors, independent sources, junction diodes, simple BJTs, analog switches, and behavioral op-amps.
- **Advanced Analog Effects**: Package parasitics, capacitor dielectric-absorption branches, conservative diode junction charge, and behavioral op-amp pole/input limits.
- **Transient & Harmonic Analysis**: BDF integration with exact waveform event insertion. Built-in spectrum and harmonic distortion (THD, SINAD, ENOB) measurements (`harmonic_analysis`, `spectrum`).
- **Reproducible Monte Carlo**: Native statistical analysis with explicit parameter distributions, component tolerances, matched-BJT mismatch, failure capture, and yield rate computation.

Monte Carlo leverages the compiled architecture to run thousands of parameter iterations without re-allocating memory:

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

Components with a numeric `tolerance` parameter are varied uniformly around their nominal value. NPN devices sharing a `MatchedGroup` receive reproducible, correlated saturation-current and beta mismatch.

### Getting Started

Run the test suite with:

```julia
using Pkg
Pkg.test()
```

Executable reference circuits live under `examples/`. Sensitivity/optimization, graphical rendering, and optional package integrations are deliberately deferred; they are not silently emulated by the initial core.

See `initial_design_docs.md` and `frequency_harmonic_and_control_plan.md` for architecture details, and `examples.md` for the full reference circuit gallery.

### End-to-End Example: Active Voltage Limiter

The following example demonstrates building a nonlinear active voltage limiter using a behavioral op-amp and antiparallel feedback diodes. It performs a transient simulation to observe clipping, and uses the built-in spectral analysis to measure the resulting Total Harmonic Distortion (THD).

```julia
using Amber

@circuit ActiveLimiter begin
    gnd  = ground()
    vin  = node()
    vfb  = node()
    vout = node()
    vpos = node()
    vneg = node()

    # Power Rails & Input Excitation (5V Peak, 1kHz Sine Wave)
    voltage_source(vpos, gnd; dc = 12V)
    voltage_source(vneg, gnd; dc = -12V)
    voltage_source(vin, gnd; waveform = Sine(amplitude = 5V, frequency = 1kHz))

    # Input Resistor (R1 = 1 kΩ)
    resistor(vin, vfb; value = 1kΩ)

    # Active Element: Behavioral Op-Amp (Inverting Feedback Loop)
    opamp(gnd, vfb, vout, vpos, vneg; model = BehavioralOpAmp(dc_gain = 100dB))

    # Passive Feedback Elements: Antiparallel Diodes for Symmetrical Clamping
    diode(vout, vfb; model = JunctionDiode(saturation_current = 1nA))
    diode(vfb, vout; model = JunctionDiode(saturation_current = 1nA))

    observe(vout)
end

circuit = ActiveLimiter()

# 1. Transient Analysis (Time-Domain Waveform & Clipping Bounds)
res_tr = transient(circuit, 0.0s => 5ms; max_step=10μs)
v_tr = voltage(res_tr, :vout)

println("Max Output Voltage:  ", round(maximum(v_tr); digits=3), " V")
println("Min Output Voltage:  ", round(minimum(v_tr); digits=3), " V")

# 2. Harmonic & Spectral Analysis (FFT Spectrum & THD Calculation)
harm = harmonic_analysis(res_tr; signal=:vout, fundamental=1000.0)

println("Total Harmonic Dist (THD): ", round(thd(harm) * 100; digits=2), " %")
```
