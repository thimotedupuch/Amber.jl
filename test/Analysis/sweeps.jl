@testset "parameter sweeps" begin
    values=sweep(compile(LowPass()),Symbol("R1.value")=>[1kΩ,10kΩ];analysis=OperatingPoint(),metric=r->voltage(r,:vout)[1])
    @test length(values)==2
end
