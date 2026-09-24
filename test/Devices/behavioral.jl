@testset "behavioral current source" begin
    @circuit ExponentialDecay begin
        gnd = ground(); state = node()
        Cstate = capacitor(state, gnd; value = 1.0)
        resistor(state, gnd; value = 1.0e15)
        behavioral_current_source(
            ((state, gnd),), state, gnd;
            current = (x, t) -> x[1], gradient = (x, t) -> (1.0, 0.0, 0.0, 0.0)
        )
        initial_voltage(Cstate, 1.0)
        observe(state)
    end
    result = transient(ExponentialDecay(), 0s => 1s; max_step = 1ms)
    @test result.stats[:converged]
    @test voltage(result, :state)[end] ≈ exp(-1) rtol = 2.0e-3

    @circuit TwoControlProduct begin
        gnd = ground(); x = node(); y = node(); output = node()
        voltage_source(x, gnd; dc = 2.0); voltage_source(y, gnd; dc = 3.0)
        resistor(output, gnd; value = 1.0)
        behavioral_current_source(
            ((x, gnd), (y, gnd)), output, gnd;
            current = (v, t) -> v[1] * v[2], gradient = (v, t) -> (v[2], v[1], 0.0, 0.0)
        )
        observe(output)
    end
    op = operating_point(TwoControlProduct())
    @test voltage(op, :output)[1] ≈ -6.0
end


@testset "behavioral voltage source" begin
    @circuit SquaringVoltageSource begin
        gnd = ground(); input = node(); output = node()
        voltage_source(input, gnd; dc = 2.0)
        behavioral_voltage_source(
            ((input, gnd),), output, gnd;
            voltage = (v, t) -> v[1]^2, gradient = (v, t) -> (2v[1], 0.0, 0.0, 0.0)
        )
        resistor(output, gnd; value = 2.0)
        observe(output)
    end
    op = operating_point(SquaringVoltageSource())
    @test voltage(op, :output)[1] ≈ 4.0

    @circuit ArbitraryVoltageGenerator begin
        gnd = ground(); output = node()
        behavioral_voltage_source(
            (), output, gnd;
            voltage = (v, t) -> sin(2π * t), gradient = (v, t) -> (0.0, 0.0, 0.0, 0.0)
        )
        resistor(output, gnd; value = 1.0)
        observe(output)
    end
    result = transient(ArbitraryVoltageGenerator(), 0s => 0.25s; max_step = 0.5ms)
    @test result.stats[:converged]
    @test voltage(result, :output)[end] ≈ 1.0 atol = 1.0e-5
end
