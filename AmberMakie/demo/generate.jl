using Amber
using AmberMakie
using CairoMakie
using Random

CairoMakie.activate!()
set_theme!(theme_amber_light())

const OUTPUT = joinpath(@__DIR__, "generated")
mkpath(OUTPUT)

@circuit DemoLowPass() begin
    gnd = ground()
    input = node()
    output = node()
    V1 = voltage_source(input, gnd; dc=0V, ac=1V,
        waveform=Pulse(low=0V, high=1V, delay=100μs, rise=20μs,
            fall=20μs, frequency=1kHz, duty_cycle=0.35))
    R1 = resistor(input, output; value=1kΩ)
    C1 = capacitor(output, gnd; value=100nF)
end

transient_result = transient(DemoLowPass(), 0s => 3ms; saveat=5μs, max_step=5μs)
transient_handle = workbench(transient_result; signals=[:input, :output])
setcursor!(transient_handle.cursors, :a, 100μs)
setcursor!(transient_handle.cursors, :b, 320μs)
setinterval!(transient_handle.cursors, 100μs => 1.1ms)
save(joinpath(OUTPUT, "01_transient_workbench.png"), transient_handle.figure; px_per_unit=1.5)
close(transient_handle)

frequency_result = small_signal(DemoLowPass(), 10Hz => 1MHz; source=:V1, points=240)
frequency_figure = Figure(size=(1200, 650))
bodeplot(frequency_figure[1, 1], frequency_result;
    input=voltage(:input), output=voltage(:output), color="#0072B2")
frequency_view = frequencyview(frequency_result;
    input=voltage(:input), output=voltage(:output))
nyquistplot(frequency_figure[1, 2], frequency_view; color="#D55E00")
Label(frequency_figure[0, :], "RC low-pass: linked frequency-domain views"; fontsize=22)
save(joinpath(OUTPUT, "02_frequency_response.png"), frequency_figure; px_per_unit=1.5)

spectral = spectrum(transient_result; signal=:output, window=:hann)
harmonics = harmonic_analysis(transient_result; signal=:output, fundamental=1kHz, harmonics=12)
spectrum_figure = Figure(size=(1200, 600))
spectrumplot(spectrum_figure[1, 1], spectral; frequency_scale=:log, color="#0072B2")
harmonicplot(spectrum_figure[1, 2], harmonics)
Label(spectrum_figure[0, :], "Transient-derived spectrum and harmonic content"; fontsize=22)
save(joinpath(OUTPUT, "03_spectrum_harmonics.png"), spectrum_figure; px_per_unit=1.5)

@circuit DemoTwoPort() begin
    gnd = ground()
    port1 = node()
    intermediate = node()
    port2 = node()
    Rloss = resistor(port1, intermediate; value=8Ω)
    Lseries = inductor(intermediate, port2; value=20nH)
    Cshunt = capacitor(port2, gnd; value=2pF)
    Rin = resistor(port1, gnd; value=500Ω)
    Rout = resistor(port2, gnd; value=500Ω)
end

network_result = port_response(DemoTwoPort(), 1MHz => 10GHz; points=320,
    ports=[Port(:port1, :gnd; name=:input), Port(:port2, :gnd; name=:output)])
network_figure = Figure(size=(1200, 650))
networkplot(network_figure[1, 1], network_result; parameter=:s, element=(2, 1), color="#0072B2")
smithplot(network_figure[1, 2], network_result; element=(1, 1), color="#D55E00")
Label(network_figure[0, :], "Two-port transmission and input reflection"; fontsize=22)
save(joinpath(OUTPUT, "04_network_smith.png"), network_figure; px_per_unit=1.5)

rng = MersenneTwister(42)
samples = 500
resistance = 1_000 .+ 50 .* randn(rng, samples)
bandwidth = 1 ./ (2π .* resistance .* 100nF)
failures = rand(rng, samples) .< 0.025
values = Union{Nothing,Float64}[failures[index] ? nothing : bandwidth[index] for index in 1:samples]
parameters = [Dict{Symbol,Float64}(:resistance => resistance[index]) for index in 1:samples]
converged = .!failures
failure_records = [MonteCarloFailure(index, UInt64(index), :ConvergenceError, "synthetic corner failure")
    for index in findall(failures)]
ensemble = MonteCarloResult(OperatingPoint(), values, parameters,
    UInt64.(1:samples), BitVector(converged), failure_records,
    Dict{Symbol,Any}(:seed => 42, :samples => samples))

statistics_figure = Figure(size=(1200, 560))
ensembleplot(statistics_figure[1, 1], ensemble; metric=:bandwidth, bins=32, color="#0072B2")
correlationplot(statistics_figure[1, 2], ensemble;
    parameter=:resistance, metric=:bandwidth, color=(:black, 0.35), markersize=6)
Label(statistics_figure[0, :], "Monte Carlo bandwidth and parameter correlation"; fontsize=22)
save(joinpath(OUTPUT, "05_monte_carlo.png"), statistics_figure; px_per_unit=1.5)

println("Generated demonstrators in $(OUTPUT)")
