"""Sampled inverter characteristic and extracted unity-gain noise margins."""
struct InverterView <: AbstractDisplayView
    input::Vector{Float64}
    output::Vector{Float64}
    gain::Vector{Float64}
    measurements::NamedTuple
    warnings::Vector{String}
    source::Any
end

"""
    inverterview(vin, vout; kwargs...)
    inverterview(sweep; output, kwargs...)

Display adapter for [`Amber.invertermetrics`](@ref). Numerical measurements,
including warnings for unresolved margins, are available without AmberMakie.
"""
function inverterview(args...; kwargs...)
    m = Amber.invertermetrics(args...; kwargs...)
    return InverterView(m.input, m.output, m.gain, m.measurements, m.warnings, m.source)
end

"""Plot inverter transfer, unity-gain boundaries, noise margins, and differential gain."""
function inverterplot(position, v::InverterView; axis = (;))
    slot = _position(position); grid = Makie.GridLayout(slot)
    ax = Makie.Axis(grid[1, 1]; merge((xlabel = "Input (V)", ylabel = "Output (V)"), axis)...)
    curve = Makie.lines!(ax, v.input, v.output)
    Makie.lines!(ax, v.input, v.input; color = :gray, linestyle = :dash)
    m = v.measurements
    if isfinite(m.vil)
        Makie.vlines!(ax, [m.vil, m.vih]; color = :gray, linestyle = :dot)
        Makie.scatter!(ax, [m.vil, m.vih], [m.voh, m.vol])
    end
    label = isfinite(m.nml) ? "NML = $(engineering(m.nml; unit = "V"))   NMH = $(engineering(m.nmh; unit = "V"))" : first(v.warnings)
    Makie.Label(grid[0, 1], label; tellwidth = false)
    gx = Makie.Axis(grid[2, 1]; xlabel = "Input (V)", ylabel = "dVout / dVin")
    gp = Makie.lines!(gx, v.input, v.gain); Makie.hlines!(gx, [-1.0]; linestyle = :dash, color = :gray)
    Makie.linkxaxes!(ax, gx)
    return PlotHandle(slot, (transfer = ax, gain = gx), (transfer = curve, gain = gp), v)
end

"""Load × supply study with retained per-point measurements and failures."""
struct SwitchingView <: AbstractDisplayView
    loads::Vector{Float64}
    supplies::Vector{Float64}
    points::Matrix{Any}
    failures::Vector{NamedTuple}
end
"""
    switchingview(measure; loads, supplies)

Call `measure(load, supply)` for each grid point. Return `switchingmetrics`
(or a NamedTuple with tphl, tplh, energy and optional result). Exceptions are
retained in `failures` and plotted as gaps. Coordinates use farads and volts.
"""
function switchingview(measure; loads, supplies)
    l = _cmos_grid(loads); s = _cmos_grid(supplies)
    all(>(0), l) && all(>(0), s) || throw(ArgumentError("loads and supplies must be positive"))
    points = Matrix{Any}(undef, length(l), length(s)); failures = NamedTuple[]
    for i in eachindex(l),j in eachindex(s)
        try
            p = measure(l[i], s[j])
            all(k -> getproperty(p, k) isa Real, (:tphl, :tplh, :energy)) || throw(ArgumentError("measurements must be real"))
            points[i, j] = p
        catch e
            e isa InterruptException && rethrow()
            points[i, j] = nothing
            push!(failures, (load = l[i], supply = s[j], message = sprint(showerror, e)))
        end
    end
    return SwitchingView(l, s, points, failures)
end
"""Plot tPHL, tPLH and total supply energy versus load, with one curve per supply."""
function switchingplot(position, v::SwitchingView)
    slot = _position(position); grid = Makie.GridLayout(slot); axes = Makie.Axis[]; plots = Any[]
    for (i, (key, label)) in enumerate(((:tphl, "tPHL (s)"), (:tplh, "tPLH (s)"), (:energy, "Supply energy / window (J)")))
        ax = Makie.Axis(grid[1, i]; xlabel = "Load (F)", ylabel = label, xtickformat = _engineering_ticks, ytickformat = _engineering_ticks)
        push!(axes, ax)
        for j in eachindex(v.supplies)
            y = [p === nothing ? NaN : getproperty(p, key) for p in v.points[:, j]]
            push!(plots, Makie.scatterlines!(ax, v.loads, y; label = engineering(v.supplies[j]; unit = "V")))
        end
    end
    Makie.Legend(grid[0, :], first(axes); orientation = :horizontal, tellwidth = false)
    incomplete = count(p -> p === nothing || !all(isfinite(getproperty(p, k)) for k in (:tphl, :tplh, :energy)), v.points)
    Makie.Label(grid[2, :], "$(length(v.points) - incomplete)/$(length(v.points)) complete points · energy includes leakage"; tellwidth = false)
    return PlotHandle(slot, (tphl = axes[1], tplh = axes[2], energy = axes[3]), (curves = plots,), v)
end

"""Conditioned offset or mismatch samples, including failed samples and provenance."""
struct MismatchView <: AbstractDisplayView
    groups::Vector{NamedTuple}
    quantity::String
    unit::String
end
"""
    mismatchview(groups; quantity="Input offset", unit="V")

Each group provides temperature (K), width/length (m), and `samples` (real,
missing or nothing), or `result` (Amber MonteCarloResult). Optional fields,
including seeds and simulation results, are retained in `source`. Groups must
have unique temperature/geometry. No statistical device assumptions are imposed.
"""
function mismatchview(groups; quantity = "Input offset", unit = "V")
    output = NamedTuple[]; seen = Set()
    for g in groups
        condition = (Float64(g.temperature), Float64(g.width), Float64(g.length))
        all(x -> isfinite(x)&&x > 0, condition) || throw(ArgumentError("temperature and geometry must be positive"))
        condition in seen && throw(ArgumentError("duplicate temperature/geometry group")); push!(seen, condition)
        raw = hasproperty(g, :samples) ? collect(g.samples) : [g.result.converged[i] ? g.result.values[i] : nothing for i in eachindex(g.result.values)]
        values = Float64[x for x in raw if x isa Real && isfinite(x)]
        n = length(values); mean = n == 0 ? NaN : sum(values) / n
        std = n < 2 ? NaN : sqrt(sum((values .- mean) .^ 2) / (n - 1))
        push!(
            output, (
                temperature = condition[1], width = condition[2], length = condition[3],
                samples = raw, values = values, mean = mean, std = std, failed = length(raw) - n, source = g,
            )
        )
    end
    isempty(output) && throw(ArgumentError("at least one group required"))
    return MismatchView(output, String(quantity), String(unit))
end
"""Plot per-condition empirical CDFs and mean ± sample standard deviation; show valid/total counts."""
function mismatchplot(position, v::MismatchView)
    slot = _position(position); grid = Makie.GridLayout(slot)
    labels = ["$(g.temperature) K, W/L=$(engineering(g.width; unit = "m"))/$(engineering(g.length; unit = "m"))  n=$(length(g.values))/$(length(g.samples))" for g in v.groups]
    ax = Makie.Axis(grid[1, 1]; xlabel = v.quantity * " (" * v.unit * ")", ylabel = "Empirical CDF", xtickformat = _engineering_ticks)
    sx = Makie.Axis(grid[2, 1]; xlabel = "Condition", ylabel = "Mean ± σ (" * v.unit * ")", xticks = (1:length(labels), string.(1:length(labels))), ytickformat = _engineering_ticks)
    curves = Any[]
    for (i, g) in enumerate(v.groups)
        if !isempty(g.values)
            ys = sort(g.values); n = length(ys)
            # Repeated x coordinates make the empirical CDF's jumps explicit.
            push!(curves, Makie.lines!(ax, repeat(ys; inner = 2), collect(Iterators.flatten(((j - 1) / n, j / n) for j in 1:n)); label = "$i: " * labels[i]))
        else
            push!(curves, Makie.lines!(ax, [NaN], [NaN]; label = "$i: " * labels[i]))
        end
    end
    means = [g.mean for g in v.groups]; deviations = [g.std for g in v.groups]
    Makie.errorbars!(sx, 1:length(labels), means, deviations)
    dots = Makie.scatter!(sx, 1:length(labels), means)
    Makie.Legend(grid[1:2, 2], ax; tellheight = false)
    return PlotHandle(slot, (distribution = ax, summary = sx), (curves = curves, means = dots), v)
end
