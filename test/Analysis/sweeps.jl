@testset "parameter sweeps" begin
    result=sweep(compile(LowPass()),Symbol("R1.value")=>[1kΩ,10kΩ];analysis=OperatingPoint(),metric=r->voltage(r,:vout)[1])
    @test result isa SweepResult
    @test length(result)==2
    @test all(result.converged)
    @test collect(result)==result.metrics
    @test successful(result)==result.metrics
    @test failure_rate(result)==0
    @test report(result)[:successful_points]==2
end


@testset "sweep restoration" begin
    circuit=compile(LowPass()); original=circuit.fingerprint
    result=sweep(circuit,:R1=>[20kΩ];metric=_result->error("metric failure"))
    @test result.converged==[false]
    @test result.metrics==[nothing]
    @test only(result.failures).error_type===:ErrorException
    @test occursin("metric failure",only(result.failures).message)
    @test failure_rate(result)==1
    @test circuit.fingerprint==original
end
