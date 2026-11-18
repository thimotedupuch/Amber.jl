@testset "reference examples" begin
    rectifier = HalfWaveRectifier(); @test length(rectifier.observations) == 5
    result = transient(rectifier, 0s => 40ms; max_step = 100μs)
    @test result.stats[:converged]; @test maximum(voltage(result, :vout)) > 1V
    line = RLGCLine(sections = 8); compiled = compile(line)
    @test summary(line).primitive_devices == 34; @test compiled.n > summary(line).nets
end
