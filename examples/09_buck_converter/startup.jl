include("circuit.jl")
using Statistics

converter = BuckConverter()
startup = transient(
    converter, 0s => 2ms; initial = :discharged, event_mode = :exact,
    max_step = 100ns, saveat = 1μs, reltol = 1.0e-5
)
output_ripple = peak_to_peak(voltage(:output); window = 1.5ms => 2ms)(startup)
average_output = mean(voltage(startup, :output)[startup.axis .>= 1.5ms])
