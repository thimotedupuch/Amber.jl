# Run in an environment containing Amber, AmberMakie, and CairoMakie.
# Regenerate the third README image with:
#   julia --project=<plotting-environment> AmberMakie/demo/readme_design_space.jl
using Amber
using AmberMakie
using CairoMakie

CairoMakie.activate!()

@circuit FeedbackPlant() begin
    gnd = ground()
    input = node()
    first_stage = node()
    second_stage = node()
    output = node()
    Source = voltage_source(input, gnd; ac=1V)
    R1 = resistor(input, first_stage; value=1kΩ)
    C1 = capacitor(first_stage, gnd; value=1μF)
    R2 = resistor(first_stage, second_stage; value=2kΩ)
    C2 = capacitor(second_stage, gnd; value=220nF)
    R3 = resistor(second_stage, output; value=4kΩ)
    C3 = capacitor(output, gnd; value=47nF)
end
plant = linearize(FeedbackPlant(); inputs=:Source, outputs=voltage(:output))
gain_values = collect(range(0.0, 60.0; length=120))
locus = root_locus(plant, gain_values)
@assert all(length(roots) == 3 for roots in locus)

@circuit EyeLink() begin
    gnd = ground()
    drive = node()
    input = node()
    output = node()
    Bits = voltage_source(drive, gnd; dc=0V,
        waveform=Pulse(low=0V, high=1V, frequency=1MHz,
            duty_cycle=0.48, rise=20ns, fall=20ns))
    Interference = voltage_source(input, drive; dc=0V,
        waveform=Sine(amplitude=0.08V, frequency=79kHz))
    R = resistor(input, output; value=500Ω)
    C = capacitor(output, gnd; value=300pF)
end
link = transient(EyeLink(), 0s => 40μs; saveat=5ns, max_step=5ns)
@assert get(link.stats, :converged, false)
eye = eyediagramview(link; signal=:output, period=1μs, unit_intervals=2)

@circuit YieldDivider() begin
    gnd = ground()
    supply = node()
    output = node()
    VDD = voltage_source(supply, gnd; dc=5V)
    Rtop = resistor(supply, output; value=1kΩ)
    Rbottom = resistor(output, gnd; value=1kΩ)
    Load = resistor(output, gnd; value=10kΩ)
end
trials = monte_carlo(YieldDivider(); samples=4_000, seed=2026,
    variations=(Symbol("Rtop.value") => UniformVariation(800Ω, 1200Ω),
        Symbol("Rbottom.value") => UniformVariation(800Ω, 1200Ω),
        Symbol("Load.value") => Gaussian(10kΩ, 1kΩ)),
    metric=result -> only(voltage(result, :output)))
@assert failure_rate(trials) == 0
target = output -> 2.25V <= output <= 2.55V
yield_fraction = yield_rate(trials, target)
edges = collect(range(0.8, 1.2; length=17))
centers = (edges[1:end-1] .+ edges[2:end]) ./ 2
totals = zeros(Int, 16, 16)
passed = zeros(Int, 16, 16)
for sample in eachindex(trials.values)
    parameters = trials.parameters[sample]
    top = parameters[Symbol("Rtop.value")] / 1e3
    bottom = parameters[Symbol("Rbottom.value")] / 1e3
    xi = clamp(searchsortedlast(edges, top), 1, 16)
    yi = clamp(searchsortedlast(edges, bottom), 1, 16)
    totals[xi, yi] += 1
    passed[xi, yi] += target(trials.values[sample])
end
@assert minimum(totals) > 0
rates = passed ./ totals

@circuit ResonantBandpass() begin
    gnd = ground()
    input = node()
    after_l = node()
    output = node()
    Source = voltage_source(input, gnd; ac=1V)
    L = inductor(input, after_l; value=10mH)
    C = capacitor(after_l, output; value=1μF)
    R = resistor(output, gnd; value=100Ω)
end
lissajous_frequencies = [800Hz, 1.6kHz, 5kHz]
resonant_response = small_signal(ResonantBandpass(),
    lissajous_frequencies; source=:Source)
phasors = transfer(resonant_response;
    input=voltage(:input), output=voltage(:output))
phase = range(0, 2π; length=500)

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
Label(fig[1, 1:2], "AMBER  /  DESIGN EXPLORATION";
    color=CYAN, fontsize=22, font=:bold, halign=:left, tellwidth=false)
Label(fig[2, 1:2], "From stability to phase space";
    color=TEXT, fontsize=47, font=:bold, halign=:left, tellwidth=false)
Label(fig[3, 1:2], "Descriptor control     ·     Signal integrity     ·     Statistical yield     ·     Resonant response";
    color=MUTED, fontsize=21, halign=:left, tellwidth=false)

ax_locus = Axis(fig[4, 1]; title="01   CONTROL  /  CLOSED-LOOP POLES",
    xlabel="Real pole (krad/s)", ylabel="Imaginary pole (krad/s)")
vlines!(ax_locus, [0]; color=(CORAL, 0.55), linewidth=1.6, linestyle=:dash)
for (gain, roots) in zip(gain_values, locus)
    scatter!(ax_locus, real.(roots) ./ 1e3, imag.(roots) ./ 1e3;
        color=fill(gain, length(roots)),
        colormap=cgrad([CYAN, LILAC, GOLD]), colorrange=(0, 60),
        markersize=8)
end
scatter!(ax_locus, real.(first(locus)) ./ 1e3,
    imag.(first(locus)) ./ 1e3;
    color=CYAN, marker=:x, markersize=21, strokewidth=3)
text!(ax_locus, -12.7, 7.3; text="gain 0 → 60", color=GOLD,
    fontsize=19)
text!(ax_locus, -12.7, -7.6; text="stable", color=MUTED,
    fontsize=18)
text!(ax_locus, 0.2, -7.6; text="unstable", color=CORAL,
    fontsize=18)
xlims!(ax_locus, -13.5, 2.5)
ylims!(ax_locus, -8.5, 8.5)

ax_eye = Axis(fig[4, 2]; title="02   SIGNAL INTEGRITY  /  EYE DIAGRAM",
    xlabel="Unit intervals", ylabel="Output voltage (V)")
for (phase, values) in zip(eye.phases, eye.values)
    lines!(ax_eye, phase, values; color=(CYAN, 0.30), linewidth=2.0)
end
hlines!(ax_eye, [0.5]; color=(GOLD, 0.6), linewidth=1.5,
    linestyle=:dash)
vlines!(ax_eye, [0.5, 1.5]; color=(GOLD, 0.4), linewidth=1.3,
    linestyle=:dash)
xlims!(ax_eye, 0, 2)
ylims!(ax_eye, -0.13, 1.13)

yield_layout = GridLayout(fig[5, 1])
ax_yield = Axis(yield_layout[1, 1]; title="03   DESIGN SPACE  /  YIELD MAP",
    xlabel="Top resistance (kΩ)", ylabel="Bottom resistance (kΩ)")
yield_plot = heatmap!(ax_yield, centers, centers, rates;
    colormap=cgrad([CORAL, "#334A68", CYAN]), colorrange=(0, 1))
contour!(ax_yield, centers, centers, rates;
    levels=[0.5], color=(TEXT, 0.72), linewidth=2)
Colorbar(yield_layout[1, 2], yield_plot; label="Yield",
    width=18, ticks=([0, 0.5, 1], ["0", "50%", "100%"]),
    ticklabelcolor=MUTED, labelcolor=MUTED,
    ticklabelsize=16, labelsize=18)
text!(ax_yield, 0.82, 1.18;
    text="$(round(Int, 100yield_fraction))% overall yield", color=TEXT,
    fontsize=19, align=(:left, :top))
xlims!(ax_yield, 0.8, 1.2)
ylims!(ax_yield, 0.8, 1.2)

ax_lissajous = Axis(fig[5, 2];
    title="04   RESONANCE  /  LISSAJOUS",
    xlabel="Input voltage (V)", ylabel="Output voltage (V)",
    aspect=DataAspect())
hlines!(ax_lissajous, [0]; color=(MUTED, 0.30), linewidth=1)
vlines!(ax_lissajous, [0]; color=(MUTED, 0.30), linewidth=1)
for (index, color) in enumerate((CYAN, GOLD, CORAL))
    frequency = lissajous_frequencies[index]
    output = real.(phasors[index] .* exp.(im .* phase))
    lines!(ax_lissajous, cos.(phase), output;
        color, linewidth=3.2, label="$(frequency / 1kHz) kHz")
end
axislegend(ax_lissajous; position=:lt, framevisible=false,
    labelsize=19, patchsize=(27, 12))
xlims!(ax_lissajous, -1.12, 1.12)
ylims!(ax_lissajous, -1.12, 1.12)

Label(fig[6, 1:2], "120 feedback gains   •   20 eye folds   •   4,000 circuit trials   •   3 AC phasors";
    color=MUTED, fontsize=17, halign=:left, tellwidth=false)
rowgap!(fig.layout, 15)
colgap!(fig.layout, 38)
rowsize!(fig.layout, 4, Relative(0.40))
rowsize!(fig.layout, 5, Relative(0.40))

output_path = joinpath(@__DIR__, "generated", "readme_design_space.png")
mkpath(dirname(output_path))
save(output_path, fig; px_per_unit=1.5)
println("Saved ", output_path)
