function networkplot(position, result::Amber.NetworkResult; parameter=:s, element=(2, 1), magnitude=:db, kwargs...)
    view = networkview(result; parameter, element)
    magnitude in (:db, :linear) || throw(ArgumentError("magnitude must be :db or :linear"))
    slot = _position(position); layout = Makie.GridLayout(slot)
    magnitude_axis = _frequency_axis(layout[1, 1], view.frequencies; ylabel=magnitude === :db ? "Magnitude (dB)" : "Magnitude")
    phase_axis = _frequency_axis(layout[2, 1], view.frequencies; xlabel="Frequency (Hz)", ylabel="Phase (°)")
    Makie.linkxaxes!(magnitude_axis, phase_axis)
    magnitude_values = magnitude === :db ? 20log10.(abs.(view.values)) : abs.(view.values)
    plots = (magnitude=Makie.lines!(magnitude_axis, view.frequencies, magnitude_values; kwargs...),
        phase=Makie.lines!(phase_axis, view.frequencies, rad2deg.(_unwrap(angle.(view.values))); kwargs...))
    PlotHandle(layout, (magnitude=magnitude_axis, phase=phase_axis), plots, view)
end

_reflection(z) = (z - 1) / (z + 1)
_smithpoint(z) = Makie.Point2f(real(z), imag(z))

function _smith_grid!(axis; labels=true)
    θ = range(0, 2π; length=361)
    major = (:gray35, 0.42); minor = (:gray45, 0.20)
    Makie.lines!(axis, cos.(θ), sin.(θ); color=(:gray25, 0.72), linewidth=1.25)
    Makie.lines!(axis, [-1, 1], [0, 0]; color=major, linewidth=0.8)
    reactance_samples = vcat(range(-80, -0.001; length=600), range(0.001, 80; length=600))
    for resistance in (0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0)
        curve = _reflection.(resistance .+ im .* reactance_samples)
        ismajor = resistance in (0.2, 0.5, 1.0, 2.0, 5.0)
        Makie.lines!(axis, real.(curve), imag.(curve); color=ismajor ? major : minor,
            linewidth=ismajor ? 0.8 : 0.55)
        labels && ismajor && Makie.text!(axis, [_smithpoint(_reflection(complex(resistance, 0)))];
            text=[string(resistance)], fontsize=9, color=:gray35,
            align=(:center, :bottom), offset=(0, 2))
    end
    resistance_samples = range(0, 80; length=700)
    for reactance in (0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0)
        for sign in (-1, 1)
            value = sign * reactance
            curve = _reflection.(resistance_samples .+ im * value)
            ismajor = reactance in (0.2, 0.5, 1.0, 2.0, 5.0)
            Makie.lines!(axis, real.(curve), imag.(curve); color=ismajor ? major : minor,
                linewidth=ismajor ? 0.8 : 0.55)
            if labels && ismajor
                location = _reflection(im * value)
                Makie.text!(axis, [_smithpoint(location)]; text=[string(sign > 0 ? "+j" : "−j", reactance)],
                    fontsize=8, color=:gray35, align=(:left, sign > 0 ? :bottom : :top), offset=(2, sign * 1))
            end
        end
    end
    labels && Makie.text!(axis, [(-1.0, 0.0), (0.0, 0.0), (1.0, 0.0)];
        text=["short", "matched", "open"], fontsize=9, color=:gray30,
        align=[(:left, :bottom), (:center, :bottom), (:right, :bottom)], offset=(0, 4))
end

function smithplot(position, result::Amber.NetworkResult; element=(1, 1), grid=:impedance,
        direction_markers=7, kwargs...)
    grid === :impedance || throw(ArgumentError("grid must currently be :impedance"))
    view = networkview(result; parameter=:s, element)
    row, column = element
    reference = row == column ? view.reference_impedances[column] : view.reference_impedances[column]
    slot = _position(position); axis = Makie.Axis(slot; xlabel="", ylabel="",
        title="S$(row)$(column) · Z₀=$(engineering(reference; unit="Ω"))",
        aspect=Makie.DataAspect(), xgridvisible=false, ygridvisible=false,
        xticksvisible=false, yticksvisible=false, xticklabelsvisible=false, yticklabelsvisible=false)
    _smith_grid!(axis)
    plot = Makie.lines!(axis, real.(view.values), imag.(view.values); kwargs...)
    count = clamp(Int(direction_markers), 2, length(view.values))
    marker_indices = unique(round.(Int, exp.(range(log(1), log(length(view.values)); length=count))))
    direction = Makie.scatter!(axis, real.(view.values[marker_indices]), imag.(view.values[marker_indices]);
        color=log10.(view.frequencies[marker_indices]), colormap=:viridis, markersize=7)
    endpoints = Makie.scatter!(axis, real.([first(view.values), last(view.values)]),
        imag.([first(view.values), last(view.values)]); marker=[:circle, :utriangle],
        color=[_AMBER_COLORS.nominal, _AMBER_COLORS.output], markersize=11)
    sweep_text = "● start  $(strip(engineering(first(view.frequencies); unit="Hz")))\n▲ end    $(strip(engineering(last(view.frequencies); unit="Hz")))"
    Makie.text!(axis, -0.98, 0.98; text=sweep_text, align=(:left, :top),
        fontsize=9, color=:gray25)
    Makie.xlims!(axis, -1.08, 1.08); Makie.ylims!(axis, -1.08, 1.08)
    PlotHandle(slot, (smith=axis,), (smith=plot, direction=direction, endpoints=endpoints), view)
end

function _stability_circles(result::Amber.NetworkResult)
    size(result.z, 1) == 2 || throw(ArgumentError("stability circles require a two-port network"))
    s = Amber.network_parameters(result, :s)
    source_centers = ComplexF64[]; source_radii = Float64[]
    load_centers = ComplexF64[]; load_radii = Float64[]
    for index in eachindex(result.frequencies)
        s11, s12, s21, s22 = s[1,1,index], s[1,2,index], s[2,1,index], s[2,2,index]
        Δ = s11 * s22 - s12 * s21
        ds = abs2(s11) - abs2(Δ); dl = abs2(s22) - abs2(Δ)
        push!(source_centers, iszero(ds) ? complex(NaN, NaN) : conj(s11 - Δ * conj(s22)) / ds)
        push!(load_centers, iszero(dl) ? complex(NaN, NaN) : conj(s22 - Δ * conj(s11)) / dl)
        push!(source_radii, iszero(ds) ? NaN : abs(s12 * s21 / ds))
        push!(load_radii, iszero(dl) ? NaN : abs(s12 * s21 / dl))
    end
    source_centers, source_radii, load_centers, load_radii
end

function stabilitycircleplot(position, result::Amber.NetworkResult; frequency_index=length(result.frequencies), kwargs...)
    source, sradius, load, lradius = _stability_circles(result)
    checkbounds(result.frequencies, frequency_index)
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Real Γ", ylabel="Imaginary Γ", aspect=Makie.DataAspect())
    _smith_grid!(axis); θ = range(0, 2π; length=361)
    sourceplot = Makie.lines!(axis, real(source[frequency_index]) .+ sradius[frequency_index] .* cos.(θ),
        imag(source[frequency_index]) .+ sradius[frequency_index] .* sin.(θ); label="Source", kwargs...)
    loadplot = Makie.lines!(axis, real(load[frequency_index]) .+ lradius[frequency_index] .* cos.(θ),
        imag(load[frequency_index]) .+ lradius[frequency_index] .* sin.(θ); label="Load", linestyle=:dash)
    Makie.axislegend(axis)
    PlotHandle(slot, (stability=axis,), (source=sourceplot, load=loadplot),
        (frequency=result.frequencies[frequency_index], source=source[frequency_index]=>sradius[frequency_index], load=load[frequency_index]=>lradius[frequency_index]))
end

function mixedmodeplot(position, result::Amber.NetworkResult; element=(2, 1), kwargs...)
    length(result.ports) == 4 || throw(ArgumentError("mixed-mode views require four single-ended ports"))
    s = Amber.network_parameters(result, :s)
    transform = ComplexF64[1 -1 0 0; 0 0 1 -1; 1 1 0 0; 0 0 1 1] / sqrt(2)
    mixed = similar(s)
    for index in eachindex(result.frequencies); mixed[:,:,index] = transform * s[:,:,index] * transform' end
    values = vec(mixed[element[1], element[2], :])
    slot = _position(position); axis = _frequency_axis(slot, result.frequencies; xlabel="Frequency (Hz)", ylabel="Mixed-mode magnitude (dB)")
    plot = Makie.lines!(axis, result.frequencies, 20log10.(abs.(values)); kwargs...)
    PlotHandle(slot, (mixedmode=axis,), (mixedmode=plot,), values)
end
