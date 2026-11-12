@testset "descriptor and control analysis" begin
    model = linearize(LowPass(); inputs = :V1, outputs = voltage(:vout))
    response = frequency_response(model, [10Hz, 1kHz, 100kHz])
    @test size(response.values) == (1, 1, 3)
    @test abs(response.values[1, 1, 1]) > 0.99
    @test dcgain(model)[1] ≈ 1
    finite_poles = poles(model)
    @test any(value -> isapprox(value, -10_000; rtol = 1.0e-6), finite_poles)
    @test isstable(model)
    @test any(isinf, poles(model; include_infinite = true))

    time = step_response(model, 0s => 1ms; saveat = 10μs)
    @test time.values[1, 1, end] > 0.99
    @test rise_time(time) > 0
    @test settling_time(time) > 0
    @test abs(steady_state_error(time)) < 1.0e-3
    @test length(root_locus(model, 0.0:1.0:2.0)) == 3
end

@testset "negative phase margin retains unwrapped phase" begin
    fs = [1.0, 10.0, 100.0]
    values = reshape([10.0, 1.0, 0.1] .* cis.(deg2rad.([-100.0, -200.0, -250.0])), 1, 1, 3)
    response = LinearFrequencyResponse(fs, values, ["input"], Amber.Observable[], Dict{Symbol, Any}())
    @test phase_margin(response) ≈ -20.0
end

@testset "stability interpolation from DC" begin
    values = reshape([10.0, 0.1] .* cis.(deg2rad.([-170.0, -190.0])), 1, 1, 2)
    response = LinearFrequencyResponse([0.0, 10.0], values, ["input"], Amber.Observable[], Dict{Symbol, Any}())
    margins = stability_margins(response)
    @test margins.phase_crossover ≈ 5.0
    @test margins.gain_margin ≈ 0.0 atol = 1e-12
    @test margins.phase_margin ≈ 0.0 atol = 1e-12
end

@testset "time response peaks and feedthrough feedback" begin
    response = TimeResponse([0.0, 1.0, 2.0, 3.0], reshape([0.0, 1.2, 1.1, 1.0], 1, 1, 4),
        ["input"], Amber.Observable[], Dict{Symbol, Any}())
    @test peak_time(response) == 1.0
    falling = TimeResponse(response.axis, -response.values, response.inputs, response.outputs, response.stats)
    @test peak_time(falling) == 1.0
    model = linearize(LowPass(); inputs = :V1, outputs = voltage(:vout))
    model.D[1, 1] = 0.5
    stepped = step_response(model, 0s => 1ms; saveat = 10μs)
    @test stepped.values[1, 1, 1] == 0.5
    locus = root_locus(model, [2.0])
    @test only(only(locus)) ≈ -20_000 rtol = 1e-6
    @test_throws ArgumentError root_locus(model, [-2.0])
end

@testset "linearization validates supplied bias" begin
    bias = operating_point(LowPass())
    stats = copy(bias.stats); stats[:converged] = false
    failed = SimulationResult(bias.compiled, bias.analysis, bias.axis, bias.values, stats)
    @test_throws Amber.ConvergenceError linearize(LowPass(); inputs = :V1, outputs = :vout, bias = failed)
    @circuit OtherLinearizationCircuit() begin
        gnd = ground(); a = node(); b = node()
        Source = voltage_source(a, gnd; dc = 1V)
        R = resistor(a, b; value = 1kΩ)
        C = capacitor(b, gnd; value = 1nF)
    end
    @test_throws ArgumentError linearize(OtherLinearizationCircuit(); inputs = :Source, outputs = :b, bias)
    invalid = copy(bias.values[:, 1]); invalid[1] = NaN
    @test_throws ArgumentError linearize(LowPass(); inputs = :V1, outputs = :vout, bias = invalid)
    @test_throws ArgumentError linearize(LowPass(); inputs = :V1, outputs = :vout, bias, temperature = -1.0)
end

@testset "rise time at small signal amplitudes" begin
    values = reshape([1.0, 1.1, 3.0] .* 1e-200, 1, 1, 3)
    response = TimeResponse([0.0, 1.0, 2.0], values, ["input"], Amber.Observable[], Dict{Symbol, Any}())
    @test rise_time(response) ≈ 1.6 / 1.9
end

@testset "time response includes requested endpoint" begin
    model = linearize(LowPass(); inputs = :V1, outputs = :vout)
    response = step_response(model, 0s => 1ms; saveat = 0.7ms)
    @test last(response.axis) == 0.001
    @test response.values[1, 1, end] ≈ 1 - 1 / 8 / 4
    coarse = step_response(model, 0s => 1ms; saveat = 2ms)
    @test coarse.axis == [0.0, 0.001]
    @test coarse.values[1, 1, end] ≈ 10 / 11
    @test_throws ArgumentError step_response(model, 0.0 => Inf; saveat = 1.0)
    @test_throws ArgumentError step_response(model, 0.0 => 1.0; saveat = Inf)
end

@testset "independent current source descriptor output" begin
    @circuit CurrentSourceDescriptor() begin
        gnd = ground(); output = node()
        I1 = current_source(output, gnd; dc = 1mA)
        I2 = current_source(output, gnd; dc = 0mA)
        R = resistor(output, gnd; value = 500Ω)
    end
    model = linearize(CurrentSourceDescriptor(); inputs = [:I1, :I2], outputs = [current(:I1), voltage(:output)])
    @test dcgain(model) ≈ [1.0 0.0; -500.0 -500.0]
    response = frequency_response(model, [1kHz])
    @test response.values[:, :, 1] ≈ [1.0 0.0; -500.0 -500.0]
    @test step_response(model, 0s => 1ms; saveat = 1ms).values[1, 1, 1] == 1.0
end

@testset "response interpolation at transmission zeros" begin
    response = LinearFrequencyResponse([1.0, 100.0], reshape(ComplexF64[0, 1], 1, 1, 2),
        ["input"], Amber.Observable[], Dict{Symbol, Any}())
    @test Amber._interpolate_response(response, 100.0) == 1.0
    @test Amber._interpolate_response(response, 10.0) ≈ 0.5
    reversed_response = LinearFrequencyResponse(response.frequencies, reverse(response.values; dims = 3),
        response.inputs, response.outputs, response.stats)
    @test Amber._interpolate_response(reversed_response, 10.0) ≈ 0.5
    @test Amber._interpolate_response(reversed_response, 100.0) == 0.0
end
