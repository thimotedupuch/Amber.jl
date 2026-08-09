function _frequency_response(response::Amber.LinearFrequencyResponse; input=1, output=1)
    response.frequencies, vec(response.values[output, input, :])
end
_frequency_response(response::Amber.LoopGainResult; kw...) = (response.response.frequencies, response.values)
_frequency_response(view::FrequencyView; kw...) = (view.frequencies, view.response)
_frequency_response(values::Tuple{<:AbstractVector,<:AbstractVector}; kw...) = values

function nyquistplot(position, response; critical_point=-1 + 0im, input=1, output=1, kwargs...)
    _, values = _frequency_response(response; input, output)
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Real", ylabel="Imaginary", aspect=Makie.DataAspect())
    curve = Makie.lines!(axis, real.(values), imag.(values); kwargs...)
    critical = Makie.scatter!(axis, [real(critical_point)], [imag(critical_point)]; marker=:x, color=_AMBER_COLORS.invalid)
    PlotHandle(slot, (nyquist=axis,), (curve=curve, critical=critical), response)
end

function nicholsplot(position, response; input=1, output=1, kwargs...)
    _, values = _frequency_response(response; input, output)
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Phase (°)", ylabel="Gain (dB)")
    plot = Makie.lines!(axis, rad2deg.(_unwrap(angle.(values))), 20log10.(abs.(values)); kwargs...)
    PlotHandle(slot, (nichols=axis,), (nichols=plot,), response)
end

function polezeroplot(position, model::Amber.LinearizedModel; kwargs...)
    poles = Amber.poles(model)
    zeros = Amber.transmission_zeros(model)
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Real (rad/s)", ylabel="Imaginary (rad/s)")
    poleplot = Makie.scatter!(axis, real.(poles), imag.(poles); marker=:x, label="Poles", kwargs...)
    zeroplot = Makie.scatter!(axis, real.(zeros), imag.(zeros); marker=:circle, color=:transparent,
        strokecolor=_AMBER_COLORS.output, strokewidth=2, label="Zeros")
    Makie.axislegend(axis)
    PlotHandle(slot, (polezero=axis,), (poles=poleplot, zeros=zeroplot), model)
end

function rootlocusplot(position, model::Amber.LinearizedModel, gains; input=1, output=1, kwargs...)
    gain_values = collect(gains)
    roots = Amber.root_locus(model, gain_values; input, output)
    slot = _position(position)
    axis = Makie.Axis(slot; xlabel="Real (rad/s)", ylabel="Imaginary (rad/s)")
    plot = Makie.scatter!(axis, reduce(vcat, real.(roots)), reduce(vcat, imag.(roots));
        color=repeat(gain_values; inner=length(first(roots))), colormap=:viridis, kwargs...)
    PlotHandle(slot, (rootlocus=axis,), (rootlocus=plot,), roots)
end

function marginplot(position, result::Amber.LoopGainResult; kwargs...)
    frequencies, values = _frequency_response(result)
    slot = _position(position); layout = Makie.GridLayout(slot)
    gainaxis = _frequency_axis(layout[1, 1], frequencies; ylabel="Loop gain (dB)")
    phaseaxis = _frequency_axis(layout[2, 1], frequencies; xlabel="Frequency (Hz)", ylabel="Phase (°)")
    Makie.linkxaxes!(gainaxis, phaseaxis)
    plots = (gain=Makie.lines!(gainaxis, frequencies, 20log10.(abs.(values)); kwargs...),
        phase=Makie.lines!(phaseaxis, frequencies, rad2deg.(_unwrap(angle.(values))); kwargs...))
    isfinite(result.margins.gain_crossover) && Makie.vlines!(gainaxis, [result.margins.gain_crossover]; linestyle=:dash)
    isfinite(result.margins.phase_crossover) && Makie.vlines!(phaseaxis, [result.margins.phase_crossover]; linestyle=:dash)
    PlotHandle(layout, (magnitude=gainaxis, phase=phaseaxis), plots, result)
end

function groupdelayplot(position, response; input=1, output=1, kwargs...)
    frequencies, values = _frequency_response(response; input, output)
    phases = _unwrap(angle.(values)); delay = similar(phases)
    length(phases) >= 2 || throw(ArgumentError("group delay requires at least two frequencies"))
    delay[1] = -(phases[2] - phases[1]) / (2π * (frequencies[2] - frequencies[1]))
    delay[end] = -(phases[end] - phases[end-1]) / (2π * (frequencies[end] - frequencies[end-1]))
    for i in 2:length(delay)-1
        delay[i] = -(phases[i+1] - phases[i-1]) / (2π * (frequencies[i+1] - frequencies[i-1]))
    end
    slot = _position(position); axis = _frequency_axis(slot, frequencies; xlabel="Frequency (Hz)", ylabel="Group delay (s)")
    plot = Makie.lines!(axis, frequencies, delay; kwargs...)
    PlotHandle(slot, (groupdelay=axis,), (groupdelay=plot,), (frequencies, delay))
end

function poleparticipationplot(position, model::Amber.LinearizedModel;
        pole=:dominant, labels=nothing, top=20, kwargs...)
    decomposition = LinearAlgebra.eigen(model.A, model.E)
    finite = findall(isfinite, decomposition.values)
    isempty(finite) && throw(ArgumentError("model has no finite poles"))
    pole_index = if pole === :dominant
        finite[argmax(real.(decomposition.values[finite]))]
    elseif pole isa Integer
        checkbounds(decomposition.values, pole); Int(pole)
    else
        finite[argmin(abs.(decomposition.values[finite] .- ComplexF64(pole)))]
    end
    selected_pole = decomposition.values[pole_index]
    right = decomposition.vectors[:, pole_index]
    left_decomposition = LinearAlgebra.eigen(transpose(model.A), transpose(model.E))
    left_index = argmin(abs.(left_decomposition.values .- conj(selected_pole)))
    left = left_decomposition.vectors[:, left_index]
    raw = abs.(conj.(left) .* right)
    total = sum(raw); total > 0 || throw(ArgumentError("pole participation is singular"))
    participation = raw ./ total
    state_labels = labels === nothing ? ["state $(index)" for index in eachindex(raw)] :
        String.(collect(labels))
    length(state_labels) == length(raw) ||
        throw(DimensionMismatch("participation labels must match model states"))
    order = sortperm(participation; rev=true)[1:min(Int(top), length(raw))]
    slot = _position(position); axis = Makie.Axis(slot;
        xlabel="Normalized participation", ylabel="State",
        yticks=(collect(eachindex(order)), state_labels[order]),
        title="Pole $(engineering(real(selected_pole); unit="rad/s")) $(imag(selected_pole) < 0 ? "−" : "+") j$(engineering(abs(imag(selected_pole)); unit="rad/s"))")
    plot = Makie.barplot!(axis, collect(eachindex(order)), participation[order];
        direction=:x, kwargs...)
    PlotHandle(slot, (participation=axis,), (participation=plot,),
        (pole=selected_pole, state_indices=order, labels=state_labels[order],
            participation=participation[order], full_participation=participation))
end
