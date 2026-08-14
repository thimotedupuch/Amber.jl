using Amber
using AmberMakie
using CairoMakie
using Random
using LinearAlgebra

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

# A broad recipe gallery: these deliberately split the same representative
# analyses into focused views so visual regressions are easy to spot.
function save_demo(name, figure_or_handle)
    figure = hasproperty(figure_or_handle, :figure) ? figure_or_handle.figure : figure_or_handle
    save(joinpath(OUTPUT, name), figure; px_per_unit=1.35)
    hasproperty(figure_or_handle, :figure) && close(figure_or_handle)
end

trace_figure = Figure(size=(1100, 620))
traceplot(trace_figure[1, 1], transient_result; signals=[:input, :output])
save_demo("06_transient_traces.png", trace_figure)

signal_quality = Figure(size=(1200, 620))
eyediagramplot(signal_quality[1, 1], transient_result; signal=:output, period=1ms)
jitterplot(signal_quality[1, 2], transient_result; signal=:output,
    nominal_period=1ms, kind=:histogram)
save_demo("07_eye_and_jitter.png", signal_quality)

jitter_figure = Figure(size=(1200, 620))
jitterplot(jitter_figure[1, 1], transient_result; signal=:output,
    nominal_period=1ms, kind=:tie)
jitterplot(jitter_figure[1, 2], transient_result; signal=:output,
    nominal_period=1ms, kind=:bathtub)
save_demo("08_jitter_trend_bathtub.png", jitter_figure)

spectrogram_figure = Figure(size=(1100, 650))
spectrogramplot(spectrogram_figure[1, 1], transient_result;
    signal=:output, samples=128, overlap=0.75)
save_demo("09_spectrogram.png", spectrogram_figure)

save_demo("10_spectrum_workbench.png", workbench(spectral; fundamental=1kHz))
save_demo("11_harmonic_workbench.png", workbench(harmonics))

frequency_handle = workbench(frequency_result; input=voltage(:input),
    output=voltage(:output), outputs=[voltage(:output), voltage(:input)])
setcursor!(frequency_handle.cursors, :a, 1kHz)
save_demo("12_small_signal_workbench.png", frequency_handle)

control_figure = Figure(size=(1300, 650))
nyquistplot(control_figure[1, 1], frequency_view)
nicholsplot(control_figure[1, 2], frequency_view)
groupdelayplot(control_figure[1, 3], frequency_view)
save_demo("13_control_views.png", control_figure)

network_handle = workbench(network_result)
setcursor!(network_handle.cursors, :a, 1GHz)
save_demo("14_network_workbench.png", network_handle)

network_details = Figure(size=(1300, 650))
impedanceplot(network_details[1, 1], network_result; element=(1, 1),
    quantity=:impedance, view=:magnitude_phase)
stabilitycircleplot(network_details[1, 2], network_result)
save_demo("15_impedance_and_stability.png", network_details)

@circuit DemoBias() begin
    gnd = ground()
    input = node()
    output = node()
    Vbias = voltage_source(input, gnd; dc=1V)
    Rfeed = resistor(input, output; value=1kΩ)
    Rload = resistor(output, gnd; value=2kΩ)
end

op_result = operating_point(DemoBias())
op_handle = workbench(op_result)
selectcomponent!(op_handle, "Rfeed")
save_demo("16_operating_point_workbench.png", op_handle)

diagnostics_figure = Figure(size=(1300, 650))
operatingpointplot(diagnostics_figure[1, 1], op_result)
powerdashboard(diagnostics_figure[1, 2], op_result; output=:Rload)
save_demo("17_operating_point_and_power.png", diagnostics_figure)

noise_result = noise(DemoBias(), 10Hz => 1MHz; output=voltage(:output),
    input=:Vbias, points=180)
noise_handle = workbench(noise_result)
setinterval!(noise_handle.cursors, 100Hz => 100kHz)
save_demo("18_noise_workbench.png", noise_handle)

noise_details = Figure(size=(1300, 650))
noisecontributionplot(noise_details[1, 1], noise_result; group=:component)
noisebudgetplot(noise_details[1, 2], noise_result; group=:component)
save_demo("19_noise_contributions.png", noise_details)

phase_ratio = max.(noise_result.output_psd ./ maximum(noise_result.output_psd), eps()) .* 1e-10
phase_result = Amber.PhaseNoiseResult(noise_result.frequencies, noise_result.output,
    phase_ratio, 10log10.(phase_ratio), 1e-6, noise_result.output_psd,
    noise_result.contributions, zeros(1, length(noise_result.frequencies)),
    1.0 + 0im, noise_result.compiled,
    Dict{Symbol,Any}(:warnings => ["demonstration phase-noise fixture"]))
save_demo("20_phase_noise_workbench.png",
    workbench(phase_result; carrier_frequency=1MHz))

sidebands = [-2, -1, 0, 1, 2]
periodic_result = Amber.PeriodicNoiseResult(noise_result.frequencies,
    noise_result.output, nothing, 1, sidebands, noise_result.output_psd,
    nothing, [noise_result.output_psd .* (1 + abs(k)) for k in sidebands] |>
        rows -> reduce(vcat, permutedims.(rows)),
    noise_result.contributions, noise_result.compiled,
    Dict{Symbol,Any}(:warnings => String[]))
save_demo("21_periodic_noise_workbench.png", workbench(periodic_result))

pss_result = Amber.PSSResult(transient_result, 3ms, 1e-8, 4,
    Matrix{Float64}(I, size(transient_result.values, 1), size(transient_result.values, 1)) .* 0.8,
    fill(0.8 + 0im, size(transient_result.values, 1)), false, nothing,
    Dict{Symbol,Any}(:converged => true, :warnings => String[]))
save_demo("22_pss_workbench.png", workbench(pss_result; signals=[:input, :output]))

sweep_values = collect(range(600.0, 1_400.0; length=41))
sweep_metrics = 1.0 ./ (2π .* sweep_values .* 100e-9)
sweep_result = Amber.SweepResult("R1.value", Any[sweep_values...], Any[sweep_metrics...],
    Any[nothing for _ in sweep_values], trues(length(sweep_values)),
    Amber.SweepFailure[], Amber.OperatingPoint(), Dict{Symbol,Any}())
save_demo("23_sweep_workbench.png", workbench(sweep_result))

reverse_result = Amber.SweepResult("R1.value", Any[reverse(sweep_values)...],
    Any[reverse(sweep_metrics .* 1.015)...], Any[nothing for _ in sweep_values],
    trues(length(sweep_values)), Amber.SweepFailure[], Amber.OperatingPoint(),
    Dict{Symbol,Any}())
statistics_details = Figure(size=(1300, 650))
transfercharacteristicplot(statistics_details[1, 1], sweep_result; reverse=reverse_result)
sensitivityplot(statistics_details[1, 2], Dict(:resistance => -0.91,
    :capacitance => -1.03, :temperature => 0.18, :supply => 0.07))
save_demo("24_transfer_and_sensitivity.png", statistics_details)

monte_handle = workbench(ensemble; predicate=value -> value > 1_450.0)
selectsample!(monte_handle, 42)
save_demo("25_monte_carlo_workbench.png", monte_handle)

yield_figure = Figure(size=(1300, 650))
yieldplot(yield_figure[1, 1], ensemble; limits=1_450.0 => 1_750.0)
parametermatrixplot(yield_figure[1, 2], ensemble)
save_demo("26_yield_and_parameter_matrix.png", yield_figure)

grid_samples = 800
x_parameter = 0.8 .+ 0.4 .* rand(rng, grid_samples)
y_parameter = 0.8 .+ 0.4 .* rand(rng, grid_samples)
grid_metric = x_parameter .* y_parameter
grid_result = MonteCarloResult(OperatingPoint(), Union{Nothing,Float64}[grid_metric...],
    [Dict{Symbol,Float64}(:x => x_parameter[i], :y => y_parameter[i]) for i in 1:grid_samples],
    UInt64.(1:grid_samples), trues(grid_samples), MonteCarloFailure[], Dict{Symbol,Any}())
yield_map_figure = Figure(size=(900, 700))
yieldmapplot(yield_map_figure[1, 1], grid_result; x=:x, y=:y,
    predicate=value -> value >= 0.95, bins=(18, 18))
save_demo("27_yield_map.png", yield_map_figure)

waterfall_figure = Figure(size=(1000, 700))
waterfall_x = collect(range(10.0, 1e5; length=160))
corners = [0.7, 0.85, 1.0, 1.15, 1.3]
waterfall_values = reduce(hcat,
    [20log10.(1 ./ sqrt.(1 .+ (waterfall_x ./ (1e3 * corner)).^2)) for corner in corners])
waterfallplot(waterfall_figure[1, 1], waterfall_x, corners, waterfall_values)
save_demo("28_corner_waterfall.png", waterfall_figure)

comparison_result = transient(DemoLowPass(), 50μs => 2.95ms; saveat=7μs, max_step=7μs)
comparison_figure = Figure(size=(1100, 700))
compareplot(comparison_figure[1, 1], [transient_result, comparison_result];
    signals=:output, alignment=:interpolate, tolerance=(; atol=0.05, rtol=0.02))
save_demo("29_transient_comparison.png", comparison_figure)

report = reportfigure(noise_result)
savefigure(joinpath(OUTPUT, "30_noise_report.png"), report)

png_count = count(name -> endswith(name, ".png"), readdir(OUTPUT))
println("Generated $(png_count) PNG demonstrators in $(OUTPUT)")
