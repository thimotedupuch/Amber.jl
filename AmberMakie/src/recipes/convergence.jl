"""Extract recorded Newton diagnostics without running or modifying a simulation."""
function convergenceview(result)
    history = get(result.stats, :residual_history, NamedTuple[])
    return (history=copy(history), iterations=collect(eachindex(history)),
        residuals=Float64[get(row, :residual_norm, NaN) for row in history],
        updates=Float64[get(row, :update_norm, NaN) for row in history],
        damping=Float64[get(row, :damping, NaN) for row in history],
        source_scale=Float64[get(row, :source_scale, NaN) for row in history],
        gmin=Float64[get(row, :gmin, NaN) for row in history],
        converged=get(result.stats, :converged, false))
end
"""Inspect recorded Newton residuals, damping and continuation stages.

Zeros and nonfinite residuals are omitted only in the logarithmic display;
the original history is retained in `handle.view.history`.
"""
function convergenceplot(position, result)
    view = convergenceview(result)
    layout = Makie.GridLayout(_position(position))
    residual = Makie.Axis(layout[1, 1]; xlabel="Recorded iteration", ylabel="Residual norm", yscale=log10)
    valid = findall(v -> isfinite(v) && v > 0, view.residuals)
    rp = Makie.lines!(residual, view.iterations[valid], view.residuals[valid])
    damping = Makie.Axis(layout[2, 1]; xlabel="Recorded iteration", ylabel="Damping / source scale")
    dp = Makie.lines!(damping, view.iterations, view.damping; label="Damping")
    sp = Makie.lines!(damping, view.iterations, view.source_scale; label="Source scale")
    Makie.linkxaxes!(residual, damping)
    Makie.axislegend(damping)
    isempty(view.history) && Makie.Label(layout[3, 1], "No Newton history recorded for this result")
    return PlotHandle(layout, (; residual, damping), (; residual=rp, damping=dp, source_scale=sp), view)
end
