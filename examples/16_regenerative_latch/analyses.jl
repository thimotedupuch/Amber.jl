include("circuit.jl")

result=operating_point(RegenerativeLatch())
@assert result.stats[:converged]
@assert result.stats[:strategy]===:pseudo_transient
@assert isapprox(voltage(result,:q)[1],-0.343075557;atol=1e-7)
@assert isapprox(voltage(result,:qb)[1],0.343075557;atol=1e-7)
