@testset "small signal" begin
    result = small_signal(LowPass(), 10Hz => 1MHz; points = 20)
    @test abs(voltage(result, :vout)[1]) > 0.9; @test length(frequencies(result)) == 20
    @circuit BiasedAC() begin
        gnd = ground(); supply = node(); input = node(); output = node()
        VDD = voltage_source(supply, gnd; dc = 12V)
        Vin = voltage_source(input, gnd; dc = 2V, ac = 1V)
        R1 = resistor(input, output; value = 1kΩ); R2 = resistor(output, gnd; value = 1kΩ)
    end
    biased = small_signal(BiasedAC(), 1kHz => 1kHz; source = :Vin)
    @test voltage(biased, :output)[1] ≈ 0.5V
    @test voltage(biased, :supply)[1] ≈ 0V
end

@testset "explicit frequency grids and response metrics" begin
    grid = [10Hz, 100Hz, 1kHz, 10kHz]
    result = small_signal(LowPass(), grid; source = :V1)
    @test frequencies(result) == grid
    @test result.analysis.frequencies == grid
    @test length(db20(voltage(result, :vout))) == length(grid)
    @test phase(ComplexF64[-1 - im, -1 + im]; unwrap = true)[2] < phase(ComplexF64[-1 - im, -1 + im]; unwrap = true)[1]
    @test all(isfinite, group_delay(grid, voltage(result, :vout)))
    @test_throws AnalysisValidationError small_signal(LowPass(), [1kHz, 100Hz])

    @circuit ComplexACSource() begin
        gnd = ground(); input = node()
        V1 = voltage_source(input, gnd; ac = 1 + 1im)
    end
    serialized = deserialize_circuit(serialize_circuit(ComplexACSource()))
    @test Amber.ac_excitation(compile(serialized))[end] == 1 + 1im
end

@testset "single canonical small-signal API" begin
    analysis = SmallSignal(10Hz => 1kHz; points = 3, source = :V1)
    @test analysis.frequencies ≈ [10Hz, 100Hz, 1kHz]
    @test !hasproperty(analysis, :points)
    @test !hasproperty(analysis, :scale)

    @circuit MultipleACSources() begin
        gnd = ground(); first = node(); second = node()
        V1 = voltage_source(first, gnd; ac = 1V)
        V2 = voltage_source(second, gnd; ac = 1V)
        R1 = resistor(first, gnd; value = 1kΩ)
        R2 = resistor(second, gnd; value = 1kΩ)
    end
    @test_throws ArgumentError small_signal(MultipleACSources(), [1kHz])
    @test small_signal(MultipleACSources(), [1kHz]; source = :V1).stats[:converged]
end


@testset "small-signal bias convergence" begin
    @test_throws AnalysisValidationError small_signal(LowPass(), 10Hz => 1kHz; maxiters = 0)
    biased = with_parameters(compile(LowPass()), "V1.dc" => 1.0)
    @test_throws ConvergenceError small_signal(biased, 10Hz => 1kHz; maxiters = 1)
end
