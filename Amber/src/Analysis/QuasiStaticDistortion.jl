"""Local cubic approximation to a memoryless DC transfer characteristic.

Coefficients multiply `(input-bias)^k` (they are not raw derivatives).
This approximation excludes dynamic nonlinearities and frequency-dependent
loading. Supply at least five ordered, finite samples spanning `bias`.
"""
struct QuasiStaticDistortion{B,C,E,R}
    bias::B
    coefficients::C
    relative_fit_error::E
    input_radius::R
end
function quasistatic_distortion(x::AbstractVector, y::AbstractVector; bias)
    length(x) == length(y) >= 5 || throw(ArgumentError("at least five paired samples required"))
    all(isfinite, x) && all(isfinite, y) || throw(ArgumentError("samples must be finite"))
    all(v -> v > zero(v), diff(x)) || throw(ArgumentError("input samples must increase strictly"))
    first(x) < bias < last(x) || throw(ArgumentError("bias must lie inside sampled interval"))
    radius = min(bias-first(x), last(x)-bias)
    z = Float64.((x .- bias) ./ radius)
    yu = oneunit(first(y)); values = Float64.(y ./ yu)
    matrix = hcat(ones(length(z)), z, z.^2, z.^3)
    c = matrix \ values
    coefficients = Tuple(c[k+1] * yu / radius^k for k in 0:3)
    error = norm(matrix*c-values) / max(norm(values .- sum(values)/length(values)), eps(Float64))
    return QuasiStaticDistortion(bias, coefficients, error, radius)
end
"""Peak cosine amplitudes through cubic order for one small input tone.

The returned fundamental includes cubic compression/expansion. Signs retain
relative cosine phase. Amplitude must fit inside the characterization radius.
"""
function distortion_harmonics(model::QuasiStaticDistortion, amplitude)
    0*model.input_radius < amplitude <= model.input_radius || throw(ArgumentError("amplitude must be positive and inside characterized radius"))
    c0,c1,c2,c3 = model.coefficients
    fundamental = c1*amplitude + 3c3*amplitude^3/4
    second = c2*amplitude^2/2; third = c3*amplitude^3/4
    return (; dc=c0+c2*amplitude^2/2, fundamental, second, third,
        thd=iszero(fundamental) ? Inf : sqrt(abs2(second)+abs2(third))/abs(fundamental),
        relative_fit_error=model.relative_fit_error)
end
"""Peak IM2 and IM3 amplitudes for two equal, nondegenerate tones.

`im2` applies to f1±f2; `im3` to 2f1±f2 and 2f2±f1. Tone frequencies
must avoid coincident products; no frequency-domain circuit solve is implied.
"""
function distortion_intermodulation(model::QuasiStaticDistortion, amplitude)
    0*model.input_radius < 2amplitude <= model.input_radius || throw(ArgumentError("combined tone peaks must fit characterization radius"))
    _,c1,c2,c3 = model.coefficients
    return (; fundamental=c1*amplitude+9c3*amplitude^3/4,
        im2=c2*amplitude^2, im3=3c3*amplitude^3/4,
        relative_fit_error=model.relative_fit_error)
end
