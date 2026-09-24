include("circuit.jl")

result = operating_point(PathologicalConvergence())
@assert result.stats[:converged]
@assert isapprox(voltage(result, :diode_bias)[1], 1.071197308; atol = 1.0e-6)
@assert isapprox(voltage(result, :divider_midpoint)[1], 50V; atol = 1.0e-6)
