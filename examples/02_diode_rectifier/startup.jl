include("circuit.jl")

rectifier=HalfWaveRectifier()
result=transient(rectifier,0s=>500ms;reltol=1e-6,max_step=100μs)
validity_report(result)
