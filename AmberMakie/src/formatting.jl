const _SI_PREFIXES = ((-15, "f"), (-12, "p"), (-9, "n"), (-6, "μ"),
    (-3, "m"), (0, ""), (3, "k"), (6, "M"), (9, "G"), (12, "T"))

"""Format a number with stable significant digits and an SI prefix."""
function engineering(value::Real; unit="", digits::Integer=4)
    digits > 0 || throw(ArgumentError("digits must be positive"))
    isnan(value) && return "NaN" * (isempty(unit) ? "" : " " * unit)
    isinf(value) && return (signbit(value) ? "−Inf" : "Inf") * (isempty(unit) ? "" : " " * unit)
    value == 0 && return "0" * (isempty(unit) ? "" : " " * unit)
    exponent = clamp(3floor(Int, log10(abs(float(value))) / 3), -15, 12)
    prefix = last(only(filter(item -> first(item) == exponent, _SI_PREFIXES)))
    rendered = string(round(value / 10.0^exponent; sigdigits=digits))
    string(rendered, " ", prefix, unit)
end

function _log_minor_ticks(values)
    positive = filter(>(0), values)
    isempty(positive) && throw(ArgumentError("a logarithmic axis requires positive values"))
    first_decade = floor(Int, log10(minimum(positive))) - 1
    last_decade = ceil(Int, log10(maximum(positive))) + 1
    [multiplier * 10.0^decade for decade in first_decade:last_decade for multiplier in 2:9]
end


function _log_major_ticks(values)
    positive = filter(>(0), values)
    isempty(positive) && throw(ArgumentError("a logarithmic axis requires positive values"))
    low = floor(Int, log10(minimum(positive)))
    high = ceil(Int, log10(maximum(positive)))
    ticks = 10.0 .^ collect(low:high)
    ticks, [strip(engineering(value; unit="Hz", digits=1)) for value in ticks]
end

function _frequency_axis(position, frequencies; kwargs...)
    Makie.Axis(position; xscale=log10, xticks=_log_major_ticks(frequencies),
        xminorticks=_log_minor_ticks(frequencies), xminorticksvisible=true,
        xminorgridvisible=true, xminorgridcolor=(:black, 0.075), kwargs...)
end
