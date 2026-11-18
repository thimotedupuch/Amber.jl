@testset "Parameter sensitivity" begin
    cc = compile(LowPass())
    frequency = 1000.0
    metric = magnitude(transfer(:V1 => voltage(:vout)); at = frequency)
    result = sensitivity(cc; metric, parameters = ["R1.value", "C1.value", "V1.ac"])
    resistance, capacitance = 1e4, 1e-8
    x = 2π * frequency * resistance * capacitance
    gain = inv(sqrt(1 + x^2))
    @test result.value ≈ gain
    @test result["R1.value"] ≈ -x^2 * gain^3 / resistance
    @test result[Symbol("C1.value")] ≈ -x^2 * gain^3 / capacitance
    @test abs(result["V1.ac"]) < 1e-12
    @test sensitivity(cc; metric = voltage(:vout), parameters = ["V1.dc"])["V1.dc"] ≈ 1
    @test sensitivity([1.0, 3.0]) == [0.5, 0.25]

    @test_throws ArgumentError sensitivity(cc; metric, parameters = String[])
    @test_throws KeyError sensitivity(cc; metric, parameters = ["missing.value"])
    @test_throws AnalysisValidationError magnitude(transfer(:V1 => voltage(:vout)); at = 0)
end

@testset "Biased transistor small-signal sensitivity" begin
    cc = with_parameters(compile(BiasedNPN()), "Supply.ac" => 1.0)
    metric = magnitude(transfer(voltage(:vcc) => voltage(:coll)); at = 1kHz)
    parameters = ["Q1.forward_beta", "Rc.value", "Supply.dc"]
    result = sensitivity(cc; metric, parameters)
    gain(circuit) = only(magnitude(transfer(small_signal(circuit, [1000.0]);
        input = voltage(:vcc), output = voltage(:coll))))
    @test result.value ≈ gain(cc)
    for (parameter, value) in zip(parameters, (150.0, 2000.0, 5.0))
        step = 1e-4 * value
        upper = gain(with_parameters(cc, parameter => value + step))
        lower = gain(with_parameters(cc, parameter => value - step))
        @test result[parameter] ≈ (upper - lower) / (2step) rtol = 1e-4
    end
end

@testset "Sensitivity through retained parameter dependencies" begin
    builder = CircuitBuilder(:LossyRC)
    ground = ground!(builder)
    input = node!(builder, :input)
    output = node!(builder, :output)
    add!(builder, voltage_source(input, ground; ac = 1.0); name = :Supply)
    add!(builder, resistor(input, output; value = 1000.0); name = :R)
    add!(builder, capacitor(output, ground; value = 1e-6,
        dielectric = Polypropylene(loss_tangent = 0.02, reference_frequency = 1000.0)); name = :C)
    cc = compile(finish(builder); specialization_limit = 0)
    @test !isempty(parameter_dependencies(cc))
    metric = magnitude(transfer(:Supply => voltage(:output)); at = 1kHz)
    result = sensitivity(cc; metric, parameters = ["C.value"])
    gain(value) = only(magnitude(voltage(small_signal(
        with_parameters(cc, "C.value" => value), [1000.0]), :output))) / V
    step = 1e-10
    @test result["C.value"] ≈ (gain(1e-6 + step) - gain(1e-6 - step)) / (2step) rtol = 1e-6
end

@testset "Phase, decibels and current transfer sensitivity" begin
    cc = compile(LowPass())
    frequency = 1000.0
    parameter = "R1.value"
    response = transfer(:V1 => voltage(:vout))
    x = 2π * frequency * 1e4 * 1e-8
    radians = sensitivity(cc; metric = phase(response; at = frequency), parameters = [parameter])
    degrees = sensitivity(cc; metric = phase(response; at = frequency, degrees = true), parameters = [parameter])
    decibels = sensitivity(cc; metric = db20(response; at = frequency), parameters = [parameter])
    @test radians.value ≈ -atan(x)
    @test radians[parameter] ≈ -x / (1e4 * (1 + x^2))
    @test degrees.value ≈ rad2deg(radians.value)
    @test degrees[parameter] ≈ rad2deg(radians[parameter])
    @test decibels.value ≈ -10log10(1 + x^2)
    @test decibels[parameter] ≈ -20x^2 / (log(10) * 1e4 * (1 + x^2))

    metric = magnitude(transfer(voltage(:vin) => current(:R1)); at = frequency)
    result = sensitivity(cc; metric, parameters = [parameter])
    measured(circuit) = abs(only(current(small_signal(circuit, [frequency]), :R1)) / A)
    @test result.value ≈ measured(cc)
    @test result[parameter] ≈
        (measured(with_parameters(cc, parameter => 10001.0)) -
         measured(with_parameters(cc, parameter => 9999.0))) / 2
end

@testset "DC branch currents and absorbed power" begin
    builder = CircuitBuilder(:PowerSensitivity)
    gnd = ground!(builder)
    input = node!(builder, :input)
    add!(builder, voltage_source(input, gnd; dc = 2.0, ac = 1.0); name = :V1)
    add!(builder, resistor(input, gnd; value = 4.0); name = :R1)
    add!(builder, current_source(input, gnd; dc = 0.25); name = :I1)
    cc = compile(finish(builder))
    parameters = ["V1.dc", "R1.value", "I1.dc"]
    for (observable, expected, derivatives) in (
        (current(:R1), 0.5, (0.25, -0.125, 0.0)),
        (current(:I1), 0.25, (0.0, 0.0, 1.0)),
        (current(:V1), -0.75, (-0.25, 0.125, -1.0)),
        (power(:R1), 1.0, (1.0, -0.25, 0.0)),
        (power(:I1), 0.5, (0.25, 0.0, 2.0)),
        (power(:V1), -1.5, (-1.25, 0.25, -2.0)),
    )
        result = sensitivity(cc; metric = observable, parameters)
        @test result.value ≈ expected
        @test [result[p] for p in parameters] ≈ collect(derivatives)
    end
    # The supply current divided by its excitation lies on the phase cut.
    phase_metric = phase(transfer(:V1 => current(:V1)); at = 1kHz)
    @test_throws AnalysisValidationError sensitivity(cc; metric = phase_metric, parameters)

    # An unselected current source gives zero transfer magnitude.
    excited = with_parameters(cc, "I1.ac" => 2.0)
    direct_metric = magnitude(transfer(voltage(:input) => current(:I1)); at = 1kHz)
    @test_throws AnalysisValidationError sensitivity(excited; metric = direct_metric,
        parameters = ["I1.ac"], source = :V1)

end
