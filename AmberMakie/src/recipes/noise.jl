function noiseplot(position, result::Amber.NoiseResult; referred=:output, kwargs...)
    view = noiseview(result; referred)
    slot = _position(position)
    axis = _frequency_axis(slot, view.frequencies; yscale=log10, xlabel="Frequency (Hz)",
        ylabel=string(titlecase(String(referred)), "-referred noise density (", view.unit, ")"))
    axis.yminorticks = _log_minor_ticks(view.density)
    axis.yminorticksvisible = true
    axis.yminorgridvisible = true
    plot = Makie.lines!(axis, view.frequencies, view.density; kwargs...)
    PlotHandle(slot, (noise=axis,), (noise=plot,), view)
end
