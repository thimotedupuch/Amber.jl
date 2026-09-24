@testset "device models" begin
    @test compile(RealisticRC()).n > 0
    @test JunctionDiode(ideality = 1.7).ideality == 1.7
    @test_throws ArgumentError Level1MOSFET(noise_coefficient = 2 / 3)
    @test_throws ArgumentError GummelPoonBJT(flicker_noise = true)
    @test_throws ArgumentError BehavioralOpAmp(input_voltage_noise = 1.0e-9)
    @test Sine(amplitude = 2V, frequency = 1kHz)(0.25ms) ≈ 2V
    @test 120dB ≈ 1.0e6
    @test 180° ≈ π
    practical = PracticalLowPassForElaboration = RealisticRC()
    @test any(x -> string(x.path) == "R1.package_inductance", devices(practical))
    @test any(x -> string(x.path) == "C1.esr", devices(practical))
    rectifier = HalfWaveRectifier()
    @test any(x -> string(x.path) == "D1.series_resistance", devices(rectifier))
    @test count(x -> startswith(string(x.path), "C1.da"), devices(rectifier)) == 6
    diode_model = JunctionDiode(junction_capacitance = 15pF, transit_time = 2ns)
    for diode_voltage in range(-1V, 0.6V; length = 20)
        step = 1.0e-6
        numerical = (charge(diode_model, diode_voltage + step) - charge(diode_model, diode_voltage - step)) / (2step)
        @test numerical ≈ differential_capacitance(diode_model, diode_voltage) rtol = 1.0e-5
    end
    sampler_module = Module(:DeviceElaborationSampler)
    Base.include(sampler_module, normpath(joinpath(@__DIR__, "..", "..", "examples", "06_sample_and_hold", "circuit.jl")))
    sampler = getfield(sampler_module, :SampleAndHold)()
    @test resolve(sampler, "S1.clock_feedthrough").kind == :device
    @test resolve(sampler, "Buffer.input_capacitance").kind == :device
    @test count(x -> occursin("bias_current", string(x.path)), devices(sampler)) == 2
    @circuit PracticalInductor() begin
        inductor_ground = ground(); inductor_node = node(); source = voltage_source(inductor_node, inductor_ground; dc = 1V)
        L1 = inductor(inductor_node, inductor_ground; value = 1mH, winding_resistance = 2Ω, parallel_capacitance = 5pF)
    end
    practical_inductor = PracticalInductor()
    @test resolve(practical_inductor, "L1.winding_resistance").kind == :device
    @test resolve(practical_inductor, "L1.parallel_capacitance").kind == :device
    amplifier_module = Module(:BJTElaborationAmplifier)
    Base.include(amplifier_module, normpath(joinpath(@__DIR__, "..", "..", "examples", "03_common_emitter", "circuit.jl")))
    amplifier = getfield(amplifier_module, :CommonEmitterAmplifier)()
    @test resolve(amplifier, "Q1.base_resistance").kind == :device
    smooth = SmoothSwitch(threshold = 1V, transition = 0.1V, ron = 10Ω, roff = 1GΩ)
    @test Amber._switch_conductance(smooth, 2V) > Amber._switch_conductance(smooth, 0V)
    @test Amber._switch_conductance_derivative(smooth, 1V) > 0
    @test EventSwitch(threshold = 2V).threshold == 2V
end
