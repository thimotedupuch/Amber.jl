# Run in an environment containing Amber, AmberMakie, and CairoMakie.
# Regenerate the README image with:
#   julia --project=<plotting-environment> AmberMakie/demo/readme_overview.jl
using Amber
using AmberMakie
using CairoMakie

CairoMakie.activate!()

@circuit ReadmeLowPass() begin
    gnd = ground()
    input = node()
    output = node()
    V1 = voltage_source(input, gnd; dc=0V, ac=1V,
        waveform=Pulse(low=0V, high=1V, delay=100μs, rise=20μs,
            fall=20μs, frequency=1kHz, duty_cycle=0.35))
    R1 = resistor(input, output; value=1kΩ)
    C1 = capacitor(output, gnd; value=100nF)
end

@circuit ReadmeTwoPort() begin
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

lowpass = ReadmeLowPass()
transient_result = transient(lowpass, 0s => 3ms; saveat=5μs, max_step=5μs)
frequency_result = small_signal(lowpass, 10Hz => 1MHz; source=:V1, points=240)
mos_view = mosfetview(ChargeBasedMOSFET(width=8μm, length=2μm,
    channel_length_modulation=0.02); vgs=range(0.0, 1.5; length=151),
    vds=[0.05, 0.25, 1.2])
network_result = port_response(ReadmeTwoPort(), 1MHz => 10GHz; points=320,
    ports=[Port(:port1, :gnd; name=:input), Port(:port2, :gnd; name=:output)])

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
Label(fig[1, 1:2], "AMBER  /  CIRCUIT SIMULATION";
    color=CYAN, fontsize=22, font=:bold, halign=:left, tellwidth=false)
Label(fig[2, 1:2], "Circuit simulation, from signal to silicon";
    color=TEXT, fontsize=47, font=:bold, halign=:left, tellwidth=false)
Label(fig[3, 1:2], "Time domain     ·     Frequency response     ·     Device physics     ·     RF networks";
    color=MUTED, fontsize=21, halign=:left, tellwidth=false)

ax_time = Axis(fig[4, 1]; title="01   TRANSIENT  /  RC LOW-PASS",
    xlabel="Time (ms)", ylabel="Voltage (V)")
times = transient_result.axis .* 1e3
input = voltage(transient_result, :input)
output = voltage(transient_result, :output)
band!(ax_time, times, zeros(length(times)), output; color=(CYAN, 0.09))
lines!(ax_time, times, input; color=CORAL, linewidth=2.5, label="input")
lines!(ax_time, times, output; color=CYAN, linewidth=3.7, label="output")
axislegend(ax_time; position=:rt, framevisible=false, labelsize=19,
    patchsize=(30, 12))
xlims!(ax_time, 0, 3)
ylims!(ax_time, -0.07, 1.1)

ax_bode = Axis(fig[4, 2]; title="02   SMALL-SIGNAL  /  FILTER RESPONSE",
    xlabel="Frequency (Hz)", ylabel="Gain (dB)", xscale=log10,
    xticks=([10, 100, 1e3, 1e4, 1e5, 1e6], ["10", "100", "1k", "10k", "100k", "1M"]))
freqs = frequencies(frequency_result)
gain = transfer(frequency_result; input=voltage(:input), output=voltage(:output))
gain_db = 20log10.(abs.(gain))
lines!(ax_bode, freqs, gain_db; color=GOLD, linewidth=3.8)
corner = 1 / (2π * 1e3 * 100e-9)
vlines!(ax_bode, [corner]; color=(CORAL, 0.72), linewidth=1.7, linestyle=:dash)
scatter!(ax_bode, [corner], [-3.0103]; color=CORAL, markersize=15)
text!(ax_bode, corner * 1.16, -8.0; text="−3 dB · 1.59 kHz", color=CORAL,
    fontsize=19, align=(:left, :center))
xlims!(ax_bode, 10, 1e6)
ylims!(ax_bode, -58, 5)

ax_mos = Axis(fig[5, 1]; title="03   CMOS  /  NMOS BIAS SWEEP",
    xlabel="Gate voltage VGS (V)", ylabel="Drain current (μA)", yscale=log10,
    yticks=([1e-3, 1e-1, 10, 1e3], ["0.001", "0.1", "10", "1,000"]))
for (j, color) in enumerate((CYAN, LILAC, CORAL))
    current_ua = [max(abs(point.id) * 1e6, 1e-8) for point in mos_view.points[:, j]]
    lines!(ax_mos, mos_view.vgs, current_ua; color, linewidth=3.2,
        label="VDS = $(mos_view.vds[j]) V")
end
axislegend(ax_mos; position=:lt, framevisible=false, labelsize=18,
    patchsize=(28, 12))
xlims!(ax_mos, 0, 1.5)
ylims!(ax_mos, 1e-3, 1e3)

ax_rf = Axis(fig[5, 2]; title="04   RF  /  INPUT REFLECTION",
    xlabel="Real Γ", ylabel="Imaginary Γ", aspect=DataAspect(),
    xticks=-1:0.5:1, yticks=-1:0.5:1)
θ = range(0, 2π; length=361)
lines!(ax_rf, cos.(θ), sin.(θ); color=(MUTED, 0.85), linewidth=1.5)
lines!(ax_rf, [-1, 1], [0, 0]; color=(MUTED, 0.35), linewidth=1)
for resistance in (0.2, 0.5, 1.0, 2.0, 5.0)
    center = resistance / (resistance + 1)
    radius = 1 / (resistance + 1)
    lines!(ax_rf, center .+ radius .* cos.(θ), radius .* sin.(θ);
        color=(MUTED, 0.20), linewidth=0.9)
end
for reactance in (0.5, 1.0, 2.0), sign in (-1, 1)
    r = range(0, 100; length=450)
    z = r .+ im * sign * reactance
    reflection = (z .- 1) ./ (z .+ 1)
    lines!(ax_rf, real.(reflection), imag.(reflection);
        color=(MUTED, 0.17), linewidth=0.8)
end
s11 = vec(network_parameters(network_result, :s)[1, 1, :])
lines!(ax_rf, real.(s11), imag.(s11); color=GOLD, linewidth=4)
scatter!(ax_rf, [real(first(s11))], [imag(first(s11))]; color=CYAN, markersize=16)
scatter!(ax_rf, [real(last(s11))], [imag(last(s11))]; color=CORAL, markersize=16)
xlims!(ax_rf, -1.08, 1.08)
ylims!(ax_rf, -1.08, 1.08)

Label(fig[6, 1:2], "Amber.jl  +  AmberMakie     •     Plots from numerical simulations and a charge-based MOSFET model";
    color=MUTED, fontsize=17, halign=:left, tellwidth=false)
rowgap!(fig.layout, 15)
colgap!(fig.layout, 38)
rowsize!(fig.layout, 4, Relative(0.40))
rowsize!(fig.layout, 5, Relative(0.40))

output_path = joinpath(@__DIR__, "generated", "readme_overview.png")
mkpath(dirname(output_path))
save(output_path, fig; px_per_unit=1.5)
println("Saved ", output_path)
