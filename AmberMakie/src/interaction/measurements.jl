struct CursorSample{X,Y}
    index::Int
    x::X
    y::Y
end

struct CursorReadout{A,B}
    a::A
    b::B
    delta_x
    delta_y
    slope
    ratio
    decades
    octaves
end

struct IntervalReadout{T}
    interval::Tuple{T,T}
    samples::Int
    minimum::T
    maximum::T
    mean::T
    rms::T
    peak_to_peak::T
    integral::T
    energy::T
end

function nearest_sample(x::AbstractVector, y::AbstractVector, target::Real)
    length(x) == length(y) || throw(DimensionMismatch("axis and trace lengths differ"))
    isempty(x) && throw(ArgumentError("cannot inspect an empty trace"))
    issorted(x) || throw(ArgumentError("cursor axes must be sorted"))
    right = searchsortedfirst(x, target)
    index = right <= 1 ? 1 : right > length(x) ? length(x) :
        abs(x[right] - target) < abs(target - x[right - 1]) ? right : right - 1
    CursorSample(index, x[index], y[index])
end

function cursor_readout(x::AbstractVector, y::AbstractVector, a::Real, b::Real)
    sa, sb = nearest_sample(x, y, a), nearest_sample(x, y, b)
    dx, dy = sb.x - sa.x, sb.y - sa.y
    ratio = sa.x == 0 ? oftype(float(dx), NaN) : sb.x / sa.x
    positive_ratio = isreal(ratio) && ratio > 0
    CursorReadout(sa, sb, dx, dy, iszero(dx) ? oftype(float(real(dy)), NaN) : dy / dx,
        ratio, positive_ratio ? log10(ratio) : NaN, positive_ratio ? log2(ratio) : NaN)
end

function _trapezoid(x, y)
    sum((y[i] + y[i + 1]) * (x[i + 1] - x[i]) / 2 for i in 1:length(x)-1)
end

function interval_readout(x::AbstractVector, y::AbstractVector, interval::Pair)
    length(x) == length(y) || throw(DimensionMismatch("axis and trace lengths differ"))
    lo, hi = extrema((first(interval), last(interval)))
    indices = findall(value -> lo <= value <= hi, x)
    length(indices) >= 2 || throw(ArgumentError("interval must contain at least two samples"))
    xs, ys = x[indices], real.(y[indices])
    duration = last(xs) - first(xs)
    duration > 0 || throw(ArgumentError("interval duration must be positive"))
    integral = _trapezoid(xs, ys)
    energy = _trapezoid(xs, abs2.(ys))
    T = promote_type(Float64, eltype(xs), eltype(ys))
    IntervalReadout{T}((T(first(xs)), T(last(xs))), length(xs), T(minimum(ys)),
        T(maximum(ys)), T(integral / duration), T(sqrt(energy / duration)),
        T(maximum(ys) - minimum(ys)), T(integral), T(energy))
end
