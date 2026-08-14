using Amber
using AmberMakie
using CairoMakie
using Statistics

CairoMakie.activate!()
set_theme!(theme_amber_light())

@circuit DocsMakieRCStep() begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd;
        waveform=Step(low=0V, high=1V, at=100μs, rise=2μs))
    R1 = resistor(input, output; value=10kΩ)
    C1 = capacitor(output, gnd; value=10nF)
end

step_result = transient(DocsMakieRCStep(), 0s => 700μs;
    saveat=2μs, max_step=2μs)
step_figure = Figure(size=(900, 520))
traceplot(step_figure[1, 1], step_result; signals=[:input, :output])
step_view = traceview(step_result, :output)
@assert cursor_readout(step_view.axis, step_view.values, 200μs, 500μs).delta_x > 0

@circuit DocsMakieLowPass(; R=10kΩ, C=10nF) begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd; dc=0V, ac=1V)
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, gnd; value=C)
end

frequency_result = small_signal(DocsMakieLowPass(), 10Hz => 1MHz;
    source=:Source, points=301, scale=:log)
frequency_view = frequencyview(frequency_result;
    input=voltage(:input), output=voltage(:output))
frequency_figure = Figure(size=(1100, 600))
bodeplot(frequency_figure[1, 1], frequency_result;
    input=voltage(:input), output=voltage(:output))
nyquistplot(frequency_figure[1, 2], frequency_view)

@circuit DocsMakiePulseFilter() begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd;
        waveform=Pulse(low=0V, high=1V, frequency=10kHz,
            duty_cycle=0.35, rise=1μs, fall=1μs))
    R1 = resistor(input, output; value=1kΩ)
    C1 = capacitor(output, gnd; value=10nF)
end

pulse_result = transient(DocsMakiePulseFilter(), 0s => 2ms;
    saveat=0.5μs, max_step=0.5μs)
settled_interval = 500μs => 2ms
spectral_result = spectrum(pulse_result;
    signal=:output, window=:hann, interval=settled_interval)
harmonic_result = harmonic_analysis(pulse_result;
    signal=:output, fundamental=10kHz, harmonics=10,
    interval=settled_interval)
spectrum_figure = Figure(size=(1100, 540))
spectrumplot(spectrum_figure[1, 1], spectral_result;
    frequency_scale=:log, include_dc=false, fundamental=10kHz)
harmonicplot(spectrum_figure[1, 2], harmonic_result)

@circuit DocsMakieNoisyDivider() begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd; dc=1V, ac=1V)
    Rsource = resistor(input, output; value=10kΩ)
    Rload = resistor(output, gnd; value=10kΩ)
    Cload = capacitor(output, gnd; value=10nF)
end

noise_result = noise(DocsMakieNoisyDivider(), 10Hz => 1MHz;
    output=voltage(:output), input=:Source, points=241)
noise_figure = Figure(size=(1150, 560))
noiseplot(noise_figure[1, 1], noise_result; referred=:output)
integratednoiseplot(noise_figure[1, 2], noise_result; referred=:output)
budget_figure = Figure(size=(900, 520))
noisebudgetplot(budget_figure[1, 1], noise_result; group=:component)
@assert !isempty(noisecontributionview(noise_result; group=:component).labels)

@circuit DocsMakieRandomDivider() begin
    gnd = ground(); input = node(); output = node()
    Source = voltage_source(input, gnd; dc=1V)
    Rtop = resistor(input, output; value=10kΩ)
    Rbottom = resistor(output, gnd; value=10kΩ)
end

divider_metric(result) = only(voltage(result, :output))
ensemble = monte_carlo(DocsMakieRandomDivider(); samples=30, seed=2026,
    variations=Dict(
        Symbol("Rtop.value") => Gaussian(10kΩ, 500Ω),
        Symbol("Rbottom.value") => Gaussian(10kΩ, 500Ω)),
    metric=divider_metric)
statistics_figure = Figure(size=(1150, 560))
ensembleplot(statistics_figure[1, 1], ensemble;
    metric=:output_voltage, bins=12)
correlationplot(statistics_figure[1, 2], ensemble;
    parameter=Symbol("Rtop.value"), metric=:output_voltage)
yield_figure = Figure(size=(800, 500))
yieldplot(yield_figure[1, 1], ensemble; limits=0.47 => 0.53)

mktempdir() do directory
    figures = (step_figure, frequency_figure, spectrum_figure,
        noise_figure, budget_figure, statistics_figure, yield_figure)
    for (index, figure) in enumerate(figures)
        path = joinpath(directory, "tutorial-$(index).png")
        save(path, figure)
        @assert filesize(path) > 0
    end
end

println("Validated five AmberMakie tutorials and seven rendered figures.")
