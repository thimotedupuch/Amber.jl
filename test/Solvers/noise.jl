@testset "noise" begin
    result = noise(LowPass(), 10Hz => 100kHz; output = voltage(:vout), input = :V1, points = 12)
    @test length(noise_density(result)) == 12
    @test all(>(0), noise_density(result))
    @test all(isfinite, input_referred_noise_density(result))
    @test integrated_noise(result, 10Hz => 100kHz) > 0
    @test sum((contribution.output_psd for contribution in result.contributions)) ≈
        noise_psd(result)
end

@testset "noise PSD identities and contributions" begin
    temperature = 325.0
    resistance = 4.7kΩ
    @circuit NoiseIdentity() begin
        gnd = ground()
        output = node()
        R1 = resistor(output, gnd; value = resistance)
    end
    result = noise(
        NoiseIdentity(), [10Hz, 1kHz, 10kHz];
        output = voltage(:output), temperature
    )
    @test noise_psd(result) ≈ fill(4 * 1.380649e-23 * temperature * resistance, 3)
    @test only(noise_contributions(result; component = :R1)).mechanism === :thermal
    variance = integrated_noise(result, 10Hz => 10kHz; quantity = :variance)
    @test variance ≈ noise_psd(result)[1] * (10kHz - 10Hz)
    interpolated = integrated_noise(result, 100Hz => 5kHz; quantity = :variance)
    @test interpolated ≈ noise_psd(result)[1] * (5kHz - 100Hz)

    @circuit ConductanceIdentity() begin
        gnd = ground()
        output = node()
        G1 = conductance(output, gnd; value = inv(resistance))
    end
    conductance_result = noise(
        ConductanceIdentity(), [1kHz];
        output = voltage(:output), temperature
    )
    @test noise_psd(conductance_result) ≈ noise_psd(
        noise(
            NoiseIdentity(), [1kHz];
            output = voltage(:output), temperature
        )
    )

    @circuit NortonIdentity() begin
        gnd = ground()
        output = node()
        Vshort = voltage_source(output, gnd; dc = 0V)
        R1 = resistor(output, gnd; value = resistance)
    end
    norton = noise(NortonIdentity(), [1kHz]; output = current(:R1), temperature)
    @test noise_psd(norton)[1] ≈ 4 * 1.380649e-23 * temperature / resistance

    capacitance = 10nF
    @circuit RCNoiseIdentity() begin
        gnd = ground()
        output = node()
        R1 = resistor(output, gnd; value = resistance)
        C1 = capacitor(output, gnd; value = capacitance)
    end
    rc_noise = noise(
        RCNoiseIdentity(), 1.0e-3Hz => 1.0e12Hz;
        output = voltage(:output), temperature, points = 301
    )
    rc_variance = integrated_noise(rc_noise, 1.0e-3Hz => 1.0e12Hz; quantity = :variance)
    @test rc_variance ≈ 1.380649e-23 * temperature / capacitance rtol = 0.02

    @circuit ExcessNoise() begin
        gnd = ground()
        input = node()
        output = node()
        V1 = voltage_source(input, gnd; dc = 1V)
        R1 = resistor(
            input, output; value = 1kΩ,
            material = ThinFilm(excess_noise_coefficient = 1.0e-12)
        )
        R2 = resistor(output, gnd; value = 1kΩ)
    end
    flicker = noise(ExcessNoise(), [10Hz, 1kHz]; output = voltage(:output))
    flicker_contribution = only(
        noise_contributions(
            flicker;
            component = :R1, mechanism = :flicker
        )
    )
    @test flicker_contribution.output_psd[1] /
        flicker_contribution.output_psd[2] ≈ 100

    @test isnothing(
        Amber._validate_correlation(
            ComplexF64[1 im / 2;-im / 2 1], :valid
        )
    )
    @test_throws AnalysisValidationError Amber._validate_correlation(
        ComplexF64[1 2;2 1], :invalid
    )

    @circuit NoisyFollower() begin
        gnd = ground()
        positive = node()
        output = node()
        supply = node()
        VDD = voltage_source(supply, gnd; dc = 5V)
        Vin = voltage_source(positive, gnd; dc = 0V, ac = 1V)
        A1 = opamp(
            positive, output, output, supply, gnd;
            model = BehavioralOpAmp(
                input_voltage_noise_density = 5nV / sqrt(Hz),
                positive_input_current_noise_density = 1pA / sqrt(Hz)
            )
        )
        Load = resistor(output, gnd; value = 10kΩ)
    end
    follower_noise = noise(NoisyFollower(), [1kHz]; output = voltage(:output))
    @test !isempty(
        noise_contributions(
            follower_noise; component = :A1,
            mechanism = :opamp_voltage
        )
    )
    @test !isempty(
        noise_contributions(
            follower_noise; component = :A1,
            mechanism = :opamp_current
        )
    )

    rectifier = noise(HalfWaveRectifier(), [1kHz]; output = voltage(:vout))
    @test any(
        contribution -> contribution.component === :D1&&
            occursin("series_resistance", String(contribution.source)),
        rectifier.contributions
    )
end

@testset "fixed-grid transient noise reproducibility" begin
    first_run = transient_noise(
        LowPass(), 0s => 10μs; timestep = 1μs, seed = 0x1234,
        abstol = 1.0e-15
    )
    second_run = transient_noise(
        LowPass(), 0s => 10μs; timestep = 1μs, seed = 0x1234,
        abstol = 1.0e-15
    )
    changed_seed = transient_noise(
        LowPass(), 0s => 10μs; timestep = 1μs, seed = 0x1235,
        abstol = 1.0e-15
    )
    @test first_run.values == second_run.values
    @test first_run.values != changed_seed.values
    @test first_run.analysis isa TransientNoise
    @test_throws AnalysisValidationError transient_noise(
        LowPass(), 0s => 10μs;
        timestep = 3μs, seed = 1
    )
end


@testset "noise bias convergence" begin
    circuit = LowPass()
    @test_throws AnalysisValidationError noise(circuit, 10Hz => 1kHz; output = voltage(:vout), maxiters = 0)
    biased = with_parameters(compile(circuit), "V1.dc" => 1.0)
    @test_throws ConvergenceError noise(biased, 10Hz => 1kHz; output = voltage(:vout), maxiters = 1)
end
