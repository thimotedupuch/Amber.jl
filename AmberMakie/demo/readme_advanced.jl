# Run in an environment containing Amber, AmberMakie, and CairoMakie.
# Regenerate the second README image with:
#   julia --project=<plotting-environment> AmberMakie/demo/readme_advanced.jl
using Amber
using AmberMakie
using CairoMakie
using LinearAlgebra

CairoMakie.activate!()

# Reuse the repository examples so every panel can be traced to a runnable
# circuit definition. Only the plotted analysis parameters are selected here.
include(joinpath(@__DIR__, "..", "..", "examples", "12_cmos_inverter", "circuit.jl"))
include(joinpath(@__DIR__, "..", "..", "examples", "11_precision_bridge", "circuit.jl"))
include(joinpath(@__DIR__, "..", "..", "examples", "05_wien_oscillator", "circuit.jl"))

inverter_sweep = sweep(CMOSInverter(), "Input.dc" => range(0V, 5V; length=201);
    analysis=OperatingPoint(), metric=result -> only(voltage(result, :output)))
@assert failure_rate(inverter_sweep) == 0
inverter = invertermetrics(inverter_sweep; output=:output)
@assert isempty(inverter.warnings)

bridge = PrecisionBridge(strain=0.)
bridge_covariance = fill((0.2Ω)^2 * 0.8, 4, 4) +
    Diagonal(fill((0.2Ω)^2 * 0.2, 4))
bridge_variation = CorrelatedVariation(
    Symbol.("Rbridge" .* string.(1:4) .* ".value"),
    fill(1kΩ, 4), bridge_covariance)
offsets = monte_carlo(bridge; samples=180, seed=0xA8B3_2026,
    correlated=bridge_variation,
    metric=result -> only(voltage(result, :output)))
@assert failure_rate(offsets) == 0
offset_mv = successful(offsets) .* 1e3
offset_yield = yield_rate(offsets, offset -> abs(offset) < 2mV)

@circuit ReadmeNoiseAmplifier() begin
    gnd = ground()
    input = node()
    output = node()
    vdd = node()
    vss = node()
    VDD = voltage_source(vdd, gnd; dc=5V)
    VSS = voltage_source(vss, gnd; dc=-5V)
    Source = voltage_source(input, gnd; dc=0V, ac=1V)
    Buffer = opamp(input, output, output, vdd, vss;
        model=BehavioralOpAmp(dc_gain=1e5, gain_bandwidth=1MHz,
            input_voltage_noise_density=5e-9))
    Load = resistor(output, gnd; value=10kΩ)
end
noise_result = noise(ReadmeNoiseAmplifier(), 10Hz => 10MHz;
    output=voltage(:output), input=:Source, points=220)
noise_frequencies = frequencies(noise_result)
noise_density_nv = noise_density(noise_result) .* 1e9
noise_psd_values = noise_psd(noise_result)
noise_integrated_uv = zeros(length(noise_frequencies))
for i in 2:length(noise_frequencies)
    bin_variance = (noise_psd_values[i-1] + noise_psd_values[i]) *
        (noise_frequencies[i] - noise_frequencies[i-1]) / 2
    noise_integrated_uv[i] = sqrt(noise_integrated_uv[i-1]^2 + bin_variance * 1e12)
end

oscillator = transient(WienOscillator(), 0s => 4ms;
    saveat=1μs, max_step=1μs, reltol=1e-6)
@assert get(oscillator.stats, :converged, false)
spectrogram_times = collect(range(0.3ms, 3.7ms; length=44))
first_spectrum = spectrum(oscillator; signal=:output,
    interval=(first(spectrogram_times) - 0.25ms) =>
        (first(spectrogram_times) + 0.25ms), nfft=2048)
bins = findall(f -> 2kHz <= f <= 50kHz, first_spectrum.frequencies)
spectrogram_frequencies = first_spectrum.frequencies[bins]
spectrogram_db = Matrix{Float64}(undef, length(bins), length(spectrogram_times))
for (column, center) in enumerate(spectrogram_times)
    spectral = column == 1 ? first_spectrum : spectrum(oscillator; signal=:output,
        interval=(center - 0.25ms) => (center + 0.25ms), nfft=2048)
    spectrogram_db[:, column] .= 20log10.(max.(spectral.amplitude_rms[bins], 1e-6))
end

const BG = "#0B1422"
const PANEL = "#132338"
const GRID = "#33475F"
const TEXT = "#F2F6FC"
const MUTED = "#A7B8CA"
const CYAN = "#5ADCE5"
const CORAL = "#FF8A75"
const GOLD = "#F3C76C"
const LILAC = "#B5A5FF"

set_theme!(Theme(
    backgroundcolor=BG, textcolor=TEXT, fontsize=21,
    Axis=(backgroundcolor=PANEL, xgridcolor=GRID, ygridcolor=GRID,
        xgridwidth=0.7, ygridwidth=0.7, spinecolor=GRID,
        xlabelcolor=MUTED, ylabelcolor=MUTED,
        xticklabelcolor=MUTED, yticklabelcolor=MUTED,
        xtickcolor=MUTED, ytickcolor=MUTED,
        titlecolor=TEXT, titlesize=27, titlealign=:left,
        xlabelsize=20, ylabelsize=20, xticklabelsize=17, yticklabelsize=17),
))

fig = Figure(size=(1600, 1050), figure_padding=(65, 65, 42, 42))
Label(fig[1, 1:2], "AMBER  /  ADVANCED ANALYSIS";
    color=CYAN, fontsize=22, font=:bold, halign=:left, tellwidth=false)
Label(fig[2, 1:2], "Beyond the waveform";
    color=TEXT, fontsize=47, font=:bold, halign=:left, tellwidth=false)
Label(fig[3, 1:2], "Nonlinear response     ·     Correlated variation     ·     Noise integration     ·     Oscillator dynamics";
    color=MUTED, fontsize=21, halign=:left, tellwidth=false)

ax_inverter = Axis(fig[4, 1]; title="01   CMOS  /  INVERTER NOISE MARGINS",
    xlabel="Input voltage (V)", ylabel="Output voltage (V)")
vspan!(ax_inverter, inverter.measurements.vil, inverter.measurements.vih;
    color=(LILAC, 0.13))
lines!(ax_inverter, [0, 5], [0, 5]; color=(MUTED, 0.48),
    linewidth=1.5, linestyle=:dash)
lines!(ax_inverter, inverter.input, inverter.output;
    color=CYAN, linewidth=4)
for (x, color) in ((inverter.measurements.vil, LILAC),
                   (inverter.measurements.vih, LILAC))
    vlines!(ax_inverter, [x]; color=(color, 0.70), linewidth=1.6,
        linestyle=:dash)
end
scatter!(ax_inverter, [inverter.measurements.vm], [inverter.measurements.vm];
    color=CORAL, markersize=17)
text!(ax_inverter, 3.25, 4.50; text="VM = 2.20 V", color=CORAL,
    fontsize=19, align=(:left, :center))
text!(ax_inverter, 1.15, 0.38; text="VIL", color=LILAC, fontsize=18)
text!(ax_inverter, 2.61, 0.38; text="VIH", color=LILAC, fontsize=18)
xlims!(ax_inverter, 0, 5)
ylims!(ax_inverter, 0, 5.2)

ax_mc = Axis(fig[4, 2]; title="02   MONTE CARLO  /  BRIDGE OFFSET",
    xlabel="Output offset (mV)", ylabel="Samples")
vspan!(ax_mc, -2, 2; color=(CYAN, 0.11))
hist!(ax_mc, offset_mv; bins=26, color=GOLD,
    strokecolor=(BG, 0.55), strokewidth=1)
vlines!(ax_mc, [-2, 2]; color=CYAN, linewidth=1.7, linestyle=:dash)
text!(ax_mc, 0, 29; text="$(round(Int, 100offset_yield))% within ±2 mV",
    color=CYAN, fontsize=21, align=(:center, :center))
xlims!(ax_mc, -6.5, 6.5)
ylims!(ax_mc, 0, 33)

ax_noise = Axis(fig[5, 1]; title="03   NOISE  /  SPECTRAL TO INTEGRATED",
    xlabel="Frequency (Hz)", ylabel="Density (nV/√Hz)", xscale=log10,
    xticks=([10, 100, 1e3, 1e4, 1e5, 1e6, 1e7],
        ["10", "100", "1k", "10k", "100k", "1M", "10M"]))
band!(ax_noise, noise_frequencies, zeros(length(noise_frequencies)),
    noise_density_nv; color=(LILAC, 0.13))
lines!(ax_noise, noise_frequencies, noise_density_nv;
    color=LILAC, linewidth=3.8)
xlims!(ax_noise, 10, 1e7)
ylims!(ax_noise, 0, 6.5)
ax_integrated = Axis(fig[5, 1]; backgroundcolor=:transparent,
    xscale=log10, yaxisposition=:right, ylabel="Integrated RMS (μV)",
    ygridvisible=false, xgridvisible=false,
    xticks=([10, 100, 1e3, 1e4, 1e5, 1e6, 1e7],
        ["10", "100", "1k", "10k", "100k", "1M", "10M"]))
hidexdecorations!(ax_integrated; grid=false)
hidespines!(ax_integrated, :l, :t, :b)
lines!(ax_integrated, noise_frequencies, noise_integrated_uv;
    color=CORAL, linewidth=3.2)
xlims!(ax_integrated, 10, 1e7)
ylims!(ax_integrated, 0, maximum(noise_integrated_uv) * 1.15)
text!(ax_noise, 30, 5.62; text="density", color=LILAC, fontsize=19)
text!(ax_integrated, 2e4, maximum(noise_integrated_uv) * 0.58;
    text="integrated RMS", color=CORAL, fontsize=19)

ax_spectrogram = Axis(fig[5, 2]; title="04   OSCILLATOR  /  STARTUP SPECTROGRAM",
    xlabel="Time (ms)", ylabel="Frequency (kHz)")
heatmap!(ax_spectrogram, spectrogram_times .* 1e3,
    spectrogram_frequencies .* 1e-3, permutedims(spectrogram_db);
    colormap=cgrad([PANEL, "#27617F", CYAN, GOLD, CORAL]),
    colorrange=(-85, 5))
hlines!(ax_spectrogram, [10]; color=(TEXT, 0.46),
    linewidth=1.3, linestyle=:dash)
text!(ax_spectrogram, 0.52, 13; text="10 kHz mode", color=TEXT,
    fontsize=18)
xlims!(ax_spectrogram, 0, 4)
ylims!(ax_spectrogram, 2, 50)

Label(fig[6, 1:2], "201 bias points   •   180 correlated trials   •   220 noise frequencies   •   4,001 oscillator samples";
    color=MUTED, fontsize=17, halign=:left, tellwidth=false)
rowgap!(fig.layout, 15)
colgap!(fig.layout, 38)
rowsize!(fig.layout, 4, Relative(0.40))
rowsize!(fig.layout, 5, Relative(0.40))

output_path = joinpath(@__DIR__, "generated", "readme_advanced.png")
mkpath(dirname(output_path))
save(output_path, fig; px_per_unit=1.5)
println("Saved ", output_path)
