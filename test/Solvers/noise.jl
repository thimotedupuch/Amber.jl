@testset "noise" begin
    result=noise(LowPass(),10Hz=>100kHz;output=voltage(:vout),referred_to=:V1,points=12)
    @test length(output_noise_density(result))==12
    @test all(>(0),output_noise_density(result))
    @test all(isfinite,input_referred_noise_density(result))
    @test integrated_noise(result,10Hz=>100kHz)>0
end


@testset "noise bias convergence" begin
    circuit=LowPass()
    @test_throws ConvergenceError noise(circuit,10Hz=>1kHz;output=voltage(:vout),maxiters=0)
end
