@testset "Unitful unit exports" begin
    import Unitful
    prefixes = (
        :f => 1.0e-15, :p => 1.0e-12, :n => 1.0e-9, :μ => 1.0e-6, :m => 1.0e-3,
        :k => 1.0e3, :M => 1.0e6, :G => 1.0e9, :T => 1.0e12,
    )
    for unit in (:Ω, :V, :A, :F, :H, :C, :s, :Hz, :S, :K)
        @test getfield(Amber, unit) === getfield(Unitful, unit)
        @test unit in names(Amber)
        for (prefix, scale) in prefixes
            name = Symbol(prefix, unit)
            @test getfield(Amber, name) === getfield(Unitful, name)
            @test name in names(Amber)
        end
    end
    @test m === Unitful.m
    @test mm === Unitful.mm
    @test μm === Unitful.μm
    @test km === Unitful.km
    @test all(name -> name in names(Amber), (:m, :fm, :pm, :nm, :μm, :mm, :km, :Mm, :Gm, :Tm))
end

@testset "Unitful component inputs" begin
    import Unitful
    @test Amber._component_parameter(:resistor, :value, 2Unitful.kΩ) == 2000
    @test Amber._component_parameter(:capacitor, :value, 3Unitful.nF) ≈ 3e-9
    @test Amber._component_parameter(:voltage_source, :dc, 500Unitful.mV) == 0.5
    @test_throws Unitful.DimensionError Amber._component_parameter(:resistor, :value, 2Unitful.V)
end

@testset "Unitful model parameters" begin
    import Unitful
    diode = JunctionDiode(saturation_current=2Unitful.nA, junction_potential=700Unitful.mV)
    @test diode.saturation_current ≈ 2e-9
    @test diode.junction_potential ≈ 0.7
    @test with_model_parameter(diode, :series_resistance, 2Unitful.kΩ).series_resistance == 2000
    @test_throws Unitful.DimensionError JunctionDiode(saturation_current=1Unitful.V)
    @test_throws Unitful.DimensionError JunctionDiode(ideality=1Unitful.V)
    @test DebyeBranches(time_constants=[1Unitful.ms], fractions=[0.1]).time_constants ≈ [0.001]
    @test ChargeBasedMOSFET(width=2Unitful.μm).width ≈ 2e-6
end

@testset "Unitful waveforms" begin
    import Unitful
    wave = Sine(amplitude=2Unitful.mV, frequency=1Unitful.kHz, phase=90Unitful.°)
    normalized = Amber._component_parameter(:voltage_source, :waveform, wave)
    @test normalized(0.0) ≈ 0.002
    step = Step(high=3Unitful.mA, at=1Unitful.ms)
    normalized = Amber._component_parameter(:current_source, :waveform, step)
    @test normalized(0.002) ≈ 0.003
    @test_throws Unitful.DimensionError Amber._component_parameter(:voltage_source, :waveform, step)
    @test_throws Unitful.DimensionError Pulse(frequency=1Unitful.s)
end

@testset "Unitful analysis descriptors" begin
    import Unitful
    @test SolverOptions(voltage_abstol=2Unitful.nV).voltage_abstol ≈ 2e-9
    @test IntegrationOptions(min_step=2Unitful.ns).min_step ≈ 2e-9
    @test OperatingPoint(temperature=25Unitful.°C).temperature ≈ 298.15
    @test Transient(0Unitful.s => 2Unitful.ms; saveat=1Unitful.μs).interval == (0.0 => 0.002)
    @test SmallSignal([1Unitful.kHz, 2Unitful.kHz]).frequencies == [1000, 2000]
    @test SmallSignal(1Unitful.kHz => 10Unitful.kHz; points=2).frequencies ≈ [1000, 10000]
    @test_throws Unitful.DimensionError SolverOptions(voltage_abstol=1Unitful.A)
    @test_throws Unitful.DimensionError OperatingPoint(temperature=1Unitful.s)
end

@testset "Unitful circuit integration" begin
    builder = CircuitBuilder(:UnitfulDivider)
    gnd = ground!(builder, :gnd)
    input = node!(builder, :input)
    output = node!(builder, :output)
    add!(builder, voltage_source(input, gnd; dc=2V); name=:Source)
    add!(builder, resistor(input, output; value=1kΩ); name=:R1)
    add!(builder, resistor(output, gnd; value=1kΩ); name=:R2)
    design = finish(builder)
    compiled = compile(design)
    @test only(voltage(operating_point(compiled), :output)) ≈ 1V
    tuned = with_parameters(compiled, "R1.value" => 3kΩ)
    @test only(voltage(operating_point(tuned), :output)) ≈ 0.5V
    restored = deserialize_circuit(serialize_circuit(design))
    @test only(voltage(operating_point(restored), :output)) ≈ 1V
end

@testset "Unitful noise and network inputs" begin
    @test Port(:p, :n; reference_impedance=0.05kΩ).reference_impedance == 50
    @test Amber._frequency_grid(1kHz => 10kHz; points=2) ≈ [1000, 10000]
    @test Amber._frequency_grid([1kHz, 2kHz]) == [1000, 2000]
    @test_throws Amber.Unitful.DimensionError Port(:p, :n; reference_impedance=1V)
end

@testset "Unitful frequency derivative" begin
    f = [1, 2, 3] .* kHz
    response = exp.(-2π .* im .* ustrip.(uconvert.(Hz, f)) .* 1e-6)
    @test group_delay(f, response) ≈ fill(1e-6s, 3)
end

@testset "Unitful logarithmic gain" begin
    @test uconvertrp(NoUnits, 120dB) ≈ 1e6
    @test BehavioralOpAmp(dc_gain=120dB).dc_gain ≈ 1e6
    @test uconvertp(NoUnits, 20dB) ≈ 100
end

@testset "Unitful variation inputs" begin
    @test Gaussian(10kΩ, 500Ω).mean == 10000
    @test Gaussian(10kΩ, 500Ω).sigma == 500
    @test UniformVariation(1kΩ, 2kΩ).high == 2000
    @test_throws Amber.Unitful.DimensionError Gaussian(1V, 1A)
end

@testset "Unitful quantity encoding" begin
    for value in (2u"kΩ", 25u"°C", 5percent, 2u"rad", (1//3) * V)
        encoded = Amber._encode_value(value)
        @test Amber._decode_value(encoded, Dict(), Dict()) == value
    end
end

@testset "Unitful callable waveform outputs" begin
    waveform = Amber._component_parameter(:voltage_source, :waveform, t -> 2mV)
    @test waveform(0.0) ≈ 0.002
    @test Amber._component_parameter(:voltage_source, :waveform, waveform) === waveform
    invalid = Amber._component_parameter(:current_source, :waveform, t -> 2mV)
    @test_throws Amber.Unitful.DimensionError invalid(0.0)
end

@testset "Unitful waveform levels" begin
    @test Step(high=2V, at=1ms)(0s) == 0V
    @test Step(high=2V, at=1ms)(2ms) == 2V
    @test Pulse(high=2mA, frequency=1kHz)(0s) == 2mA
    @test_throws Amber.Unitful.DimensionError Step(low=1V, high=1A)
end

@testset "Unitful delay at DC" begin
    delay = phase_delay([0Hz, 1kHz], [1.0 + 0im, 1.0 + 0im])
    @test isnan(first(delay))
    @test Amber.Unitful.dimension(first(delay)) == Amber.Unitful.dimension(1s)
    @test last(delay) == 0s
end

@testset "Unitful sine offset" begin
    @test Sine(amplitude=0.0, offset=2mV)(0s) == 2mV
    @test_throws Amber.Unitful.DimensionError Sine(amplitude=1V, offset=1A)
end

@testset "Unitful catalogue boundaries" begin
    @test photodiode(:a, :b; photocurrent=2mA).parameters.photocurrent ≈ 0.002
    @test solar_cell(:a, :b; photocurrent=2mA, shunt_resistance=1kΩ).parameters.shunt_resistance == 1000
    @test crystal(:a, :b; motional_resistance=2Ω, motional_inductance=1mH).parameters.motional_inductance ≈ 0.001
    @test transmission_line(:a, :b, :g; resistance=1Ω, inductance=2nH, conductance=1μS, capacitance=3pF).parameters.capacitance ≈ 3e-12
    @test_throws Amber.Unitful.DimensionError photodiode(:a, :b; photocurrent=1V)
end
