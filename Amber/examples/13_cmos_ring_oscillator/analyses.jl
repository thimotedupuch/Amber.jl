include("circuit.jl")

oscillator = CMOSRingOscillator()
startup = transient(oscillator, 0s => 1μs; max_step = 1ns, saveat = 1ns)

# Measure the settled oscillation rather than the deliberately perturbed startup.
metrics = harmonic_analysis(startup; signal = voltage(:stage5), interval = 0.5μs => 1μs)
average_supply_current = sum(current(startup, :VDD)[startup.axis .>= 0.5μs]) /
    count(>=(0.5μs), startup.axis)
