"""Uniform distributed RLGC line with SI per-length parameters and physical length.

This analytic frequency-domain model does not approximate the line with lumped sections.
It is a characterization API, not yet a transient MNA device.
"""
struct DistributedLine
    resistance::Float64
    inductance::Float64
    conductance::Float64
    capacitance::Float64
    length::Float64
    function DistributedLine(; resistance = 0.0, inductance, conductance = 0.0, capacitance, length)
        r = Float64(_si_value(resistance, Unitful.Ω / Unitful.m))
        l = Float64(_si_value(inductance, Unitful.H / Unitful.m))
        g = Float64(_si_value(conductance, inv(Unitful.Ω * Unitful.m)))
        c = Float64(_si_value(capacitance, Unitful.F / Unitful.m))
        d = Float64(_si_value(length, Unitful.m))
        all(isfinite, (r,l,g,c,d)) && r >= 0 && g >= 0 && l > 0 && c > 0 && d > 0 ||
            throw(ArgumentError("line requires finite nonnegative R/G and positive L/C/length"))
        new(r,l,g,c,d)
    end
end

"""Exact two-port chain matrix [Vin; Iin] = ABCD * [Vout; -Iout]."""
function line_abcd(line::DistributedLine, frequency)
    f = Float64(_si_value(frequency, Unitful.Hz))
    isfinite(f) && f >= 0 || throw(ArgumentError("frequency must be finite and nonnegative"))
    z = line.resistance + 2pi * im * f * line.inductance
    y = line.conductance + 2pi * im * f * line.capacitance
    u = sqrt(z * y) * line.length
    # sinh(u)/u has a removable singularity at DC for lossless and RC lines.
    factor = abs(u) < 1e-6 ? 1 + u^2 / 6 + u^4 / 120 : sinh(u) / u
    a = cosh(u)
    return ComplexF64[a z * line.length * factor; y * line.length * factor a]
end
