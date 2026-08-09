function operatingpointplot(position, result::Amber.SimulationResult; kwargs...)
    result.analysis isa Amber.OperatingPoint || throw(ArgumentError("operatingpointplot requires an operating-point result"))
    rows = Amber.result_table(result); row = only(rows)
    names = collect(String.(propertynames(row)[2:end])); values = Float64[real(getproperty(row, name)) for name in propertynames(row)[2:end]]
    slot = _position(position); axis = Makie.Axis(slot; xlabel="Observable", ylabel="Voltage (V)", xticks=(collect(eachindex(names)), names))
    plot = Makie.barplot!(axis, collect(eachindex(values)), values; kwargs...)
    PlotHandle(slot, (operatingpoint=axis,), (operatingpoint=plot,), (names=names, values=values))
end

function diagnosticplot(position, result; kwargs...)
    report = Amber.validity_report(result)
    warnings = String.(get(report, :warnings, String[]))
    slot = _position(position); layout = Makie.GridLayout(slot)
    text = isempty(warnings) ? "No validity warnings" : join(("• " * warning for warning in warnings), "\n")
    label = Makie.Label(layout[1, 1], text; justification=:left, halign=:left, valign=:top, kwargs...)
    PlotHandle(layout, NamedTuple(), (diagnostics=label,), report)
end
