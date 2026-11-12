@testset "periodic steady state shooting" begin
    @circuit DrivenRC() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; dc = 0V, ac = 1V, waveform = Sine(amplitude = 1V, frequency = 1kHz))
        Iprobe = current_source(output, gnd; dc = 0A)
        R1 = resistor(input, output; value = 1kΩ)
        C1 = capacitor(output, gnd; value = 100nF)
    end
    result = periodic_steady_state(DrivenRC(); period = 1ms, saveat = 20μs, max_step = 20μs, maxiters = 5)
    @test result.stats[:converged]
    @test result.residual_norm < 1.0e-5
    @test length(result.floquet_multipliers) == size(result.monodromy, 1)
    @test voltage(result.orbit, :output)[1] ≈ voltage(result.orbit, :output)[end] atol = 1.0e-5V
    periodic_result = periodic_noise(
        result, [100Hz, 200Hz];
        output = voltage(:output), sidebands = -1:1
    )
    stationary_result = noise(DrivenRC(), [100Hz, 200Hz]; output = voltage(:output))
    @test noise_psd(periodic_result) ≈ noise_psd(stationary_result) rtol = 1.0e-4
    direct = periodic_noise(result, [100Hz]; output = current(:Iprobe), input = :Iprobe, sidebands = -1:1)
    @test all(iszero, noise_psd(direct))
    @test all(iszero, input_referred_noise_psd(direct))

    @test_throws AnalysisValidationError phase_noise(
        result, [100Hz];
        output = voltage(:output)
    )
end
