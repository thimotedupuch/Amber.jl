@testset "parameter sweeps" begin
    values=sweep(compile(LowPass()),Symbol("R1.value")=>[1kΩ,10kΩ];analysis=OperatingPoint(),metric=r->voltage(r,:vout)[1])
    @test length(values)==2
end


@testset "sweep restoration" begin
    circuit=LowPass(); resistor=only(filter(component->component.name===:R1,circuit.components))
    original=resistor.parameters[:value]
    @test_throws ErrorException sweep(circuit,:R1=>[2original];metric=_result->error("metric failure"))
    @test resistor.parameters[:value]==original
end
