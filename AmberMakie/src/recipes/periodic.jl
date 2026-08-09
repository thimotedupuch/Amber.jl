struct FloquetModeReadout
    index::Int
    multiplier::ComplexF64
    state_labels::Vector{String}
    participation::Vector{Float64}
    stable::Bool
end

function floquet_mode(result::Amber.PSSResult, selector=:dominant)
    decomposition = LinearAlgebra.eigen(result.monodromy)
    isempty(decomposition.values) && throw(ArgumentError("PSS result has no Floquet modes"))
    index = if selector === :dominant
        argmax(abs.(decomposition.values))
    elseif selector isa Integer
        checkbounds(decomposition.values, selector); Int(selector)
    else
        argmin(abs.(decomposition.values .- ComplexF64(selector)))
    end
    multiplier = ComplexF64(decomposition.values[index])
    raw = abs.(decomposition.vectors[:, index])
    total = sum(raw); total > 0 || throw(ArgumentError("Floquet eigenvector is singular"))
    labels = [Amber._unknown_label(result.orbit.compiled, state)
        for state in eachindex(raw)]
    FloquetModeReadout(index, multiplier, labels, raw ./ total,
        abs(multiplier) <= 1 + sqrt(eps(Float64)))
end

function pssplot(position, result::Amber.PSSResult; signals, cycles=1, kwargs...)
    cycles >= 1 || throw(ArgumentError("cycles must be positive"))
    orbit = result.orbit; signal_list = signals isa AbstractVector || signals isa Tuple ? collect(signals) : [signals]
    isempty(signal_list) && throw(ArgumentError("signals must not be empty"))
    slot = _position(position); layout = Makie.GridLayout(slot)
    axis = Makie.Axis(layout[1:2, 1]; xlabel="Time (s)", ylabel="Value")
    floquet_axis = Makie.Axis(layout[1, 2]; xlabel="Real", ylabel="Imaginary",
        title="Floquet multipliers", aspect=Makie.DataAspect())
    plots = Any[]
    for signal in signal_list
        values = Amber.trace(orbit, signal)
        times = reduce(vcat, [orbit.axis .+ (cycle - 1) * result.period for cycle in 1:cycles])
        repeated = repeat(values, cycles)
        push!(plots, Makie.lines!(axis, times, real.(repeated); label=string(signal), kwargs...))
    end
    Makie.axislegend(axis)
    θ = range(0, 2π; length=361)
    unit_circle = Makie.lines!(floquet_axis, cos.(θ), sin.(θ); color=:gray55,
        linestyle=:dash)
    stable = abs.(result.floquet_multipliers) .<= 1 + sqrt(eps(Float64))
    multipliers = Makie.scatter!(floquet_axis, real.(result.floquet_multipliers),
        imag.(result.floquet_multipliers);
        color=ifelse.(stable, _AMBER_COLORS.nominal, _AMBER_COLORS.invalid),
        marker=ifelse.(stable, :circle, :x))
    Makie.xlims!(floquet_axis, -1.15max(1, maximum(abs, real.(result.floquet_multipliers); init=0)),
        1.15max(1, maximum(abs, real.(result.floquet_multipliers); init=0)))
    Makie.ylims!(floquet_axis, -1.15max(1, maximum(abs, imag.(result.floquet_multipliers); init=0)),
        1.15max(1, maximum(abs, imag.(result.floquet_multipliers); init=0)))
    converged = get(result.stats, :converged, false)
    status = converged ? "CONVERGED" : "NOT CONVERGED"
    unstable = count(!, stable)
    summary = "$(status)\nclosure residual: $(engineering(result.residual_norm))\niterations: $(result.iterations)\nunstable multipliers: $(unstable)"
    Makie.Label(layout[2, 2], summary; halign=:left, valign=:top,
        justification=:left, color=converged && unstable == 0 ? _AMBER_COLORS.nominal : _AMBER_COLORS.invalid)
    PlotHandle(layout, (pss=axis, floquet=floquet_axis),
        (traces=plots, multipliers=multipliers, unit_circle=unit_circle),
        (result, converged, closure_residual=result.residual_norm, unstable_multipliers=unstable))
end

function orbitplot(position, result::Amber.PSSResult; x, y, kwargs...)
    xv, yv = Amber.trace(result.orbit, x), Amber.trace(result.orbit, y)
    slot = _position(position); axis = Makie.Axis(slot; xlabel=string(x), ylabel=string(y))
    plot = Makie.lines!(axis, real.(xv), real.(yv); kwargs...)
    PlotHandle(slot, (orbit=axis,), (orbit=plot,), result)
end
