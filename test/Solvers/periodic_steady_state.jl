@testset "periodic steady state shooting" begin
    @circuit DrivenRC() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; dc = 0V, ac = 1V, waveform = Sine(amplitude = 1V, frequency = 1kHz))
        R1 = resistor(input, output; value = 1kΩ)
        C1 = capacitor(output, gnd; value = 100nF)
    end
    result = periodic_steady_state(DrivenRC(); period = 1ms, saveat = 20μs, max_step = 20μs, maxiters = 5)
    @test result.stats[:converged]
    @test result.residual_norm < 1.0e-5
    @test length(result.floquet_multipliers) == size(result.monodromy, 1)
    @test voltage(result.orbit, :output)[1] ≈ voltage(result.orbit, :output)[end] atol = 1.0e-5
    periodic_result = periodic_noise(
        result, [100Hz, 200Hz];
        output = voltage(:output), sidebands = -1:1
    )
    stationary_result = noise(DrivenRC(), [100Hz, 200Hz]; output = voltage(:output))
    @test noise_psd(periodic_result) ≈ noise_psd(stationary_result) rtol = 1.0e-4
    @test_throws AnalysisValidationError phase_noise(
        result, [100Hz];
        output = voltage(:output)
    )
end
