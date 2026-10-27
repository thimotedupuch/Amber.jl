@testset "results" begin
    result = small_signal(HierarchicalFilter(), 10Hz => 100kHz; points = 10)
    @test abs(voltage(result, :output)[1]) > 0.9
    @test length(current(result, "First.R1")) == 10
    @test voltage(result, "First.output") ≈ voltage(result, :middle)
    @test haskey(provenance(result), :topology_fingerprint)
    transient_result = transient(LowPass(), 0s => 200μs; saveat = 10μs)
    @test all(isfinite, current(transient_result, :C1))
    @test all(isfinite, power(transient_result, :R1))
    diode_result = transient(HalfWaveRectifier(), 0s => 1ms; max_step = 100μs)
    @test all(isfinite, current(diode_result, :D1))
    @test all(isfinite, charge(diode_result, :D1))
    sampler_module = Module(:SamplerResultTest)
    Base.include(sampler_module, normpath(joinpath(@__DIR__, "..", "..", "examples", "06_sample_and_hold", "circuit.jl")))
    sampler = getfield(sampler_module, :SampleAndHold)()
    sampler_op = operating_point(sampler)
    @test length(state(sampler_op, :Buffer, :dominant_pole)) == 1
    @circuit NamedObservation() begin
        reference = ground(); output = node(); source = voltage_source(output, reference; dc = 3V)
        observe(voltage(output); name = :measured_output)
    end
    named = NamedObservation()
    named_result = operating_point(named)
    @test only(observations(named)).name === :measured_output
    @test observation(named_result, :measured_output)[1] ≈ 3V
    @test trace(named_result, :measured_output) == observation(named_result, :measured_output)
    @test voltage(named_result, :measured_output) == observation(named_result, :measured_output)
    rectifier_result = transient(HalfWaveRectifier(), 0s => 2ms; max_step = 100μs)
    validity = validity_report(rectifier_result)
    @test haskey(validity[:devices], "D1")
    @test haskey(validity[:devices], "C1")
    @test haskey(provenance(rectifier_result), :parameters)
    table = result_table(result)
    @test length(table) == length(result.axis)
    @test hasproperty(first(table), :frequency)
    @test hasproperty(first(table), :output)
    selected = result_table(
        transient_result; signals = (
            output_V = voltage(:vout),
            resistor_A = current(:R1), resistor_W = power(:R1),
        )
    )
    @test getproperty.(selected, :resistor_A) == current(transient_result, :R1)
    @test getproperty.(selected, :resistor_W) == power(transient_result, :R1)
    @test keys(first(selected)) == (:time, :output_V, :resistor_A, :resistor_W)
    @test only(result_table(named_result; signals = (measured_V = :measured_output,))).measured_V ≈ 3V
    @test_throws ArgumentError result_table(transient_result; signals = (time = voltage(:vout),))
    @test_throws ArgumentError result_table(transient_result; signals = [:vout])
    compact = report(rectifier_result)
    @test !haskey(compact[:statistics], :bdf_orders)
    @test compact[:warnings] == validity[:warnings]
    @test haskey(compact[:devices], "C1")
    @test compact[:samples] == length(rectifier_result.axis)
    @test compact[:interval] == (first(rectifier_result.axis) => last(rectifier_result.axis))
    @test report(rectifier_result; detailed = true)[:statistics] == rectifier_result.stats
    @test haskey(rectifier_result.stats, :bdf_orders) # Reporting must not mutate the result.

    builder = CircuitBuilder(:UnsupportedValue); ground!(builder, :gnd)
    @test_throws MethodError add!(builder, "not a primitive")
end


@testset "result snapshots" begin
    compiled = compile(LowPass()); result = operating_point(compiled); before = current(result, :R1)
    updated = with_parameters(compiled, "R1.value" => 20kΩ)
    @test current(result, :R1) == before
    @test provenance(result)[:parameters]["R1"][:value] != provenance(operating_point(updated))[:parameters]["R1"][:value]
end

@testset "engineering reports and device windows" begin
    # A manufactured trace with a known BDF1 current on an irregular grid.
    # Full-trace reconstruction is essential: slicing first loses the 1 A
    # current at the start of the selected window.
    cc = compile(LowPass(C = 1.0))
    values = zeros(size(operating_point(cc).values, 1), 3)
    values[Amber._hierarchical_net_index(cc, "vout"), :] = [0.0, 1.0, 7.0]
    stats = Dict{Symbol, Any}(
        :bdf_orders => [1, 1, 1], :converged => true,
        :warnings => ["whole-run warning"]
    )
    tr = SimulationResult(cc, Transient(0.0 => 3.0), [0.0, 1.0, 3.0], values, stats)
    @test current(tr, :C1) ≈ [1.0, 1.0, 3.0]
    full = report(tr)
    selected = report(tr; window = 1.0 => 3.0)
    @test full[:devices]["C1"].ripple_current_rms ≈ sqrt(11 / 3)
    @test selected[:devices]["C1"].ripple_current_rms ≈ sqrt(5)
    @test selected[:device_window].interval == (1.0 => 3.0)
    @test selected[:device_window].samples == 2
    @test selected[:device_window].scope === :selected_window
    @test selected[:warnings] == full[:warnings]
    @test selected[:samples] == 3
    @test selected[:interval] == (0.0 => 3.0)
    single = report(tr; window = 0.5 => 2.0)
    @test single[:device_window].requested == (0.5 => 2.0)
    @test single[:device_window].interval == (1.0 => 1.0)
    @test single[:devices]["C1"].ripple_current_rms ≈ 1.0
    @test report(tr; window = 1.0 => 1.0)[:devices]["C1"].ripple_current_rms ≈ 1.0
    for window in (-1.0 => 2.0, 0.0 => 4.0, 2.0 => 1.0, NaN => 2.0, 0.0 => Inf, 0.1 => 0.2)
        @test_throws ArgumentError report(tr; window)
    end
    @test_throws ArgumentError report(tr; window = (0.0, 1.0))
    @test_throws ArgumentError report(operating_point(LowPass()); window = 0.0 => 1.0)
    @test Dict(full)[:devices] == full[:devices]
    @test get(full, :warnings, nothing) == full[:warnings]
    @test copy(full) == full
    rendered = sprint(println, full)
    @test occursin("rated ripple current is unspecified", rendered)
    @test occursin("whole-run warning", rendered)
    @test occursin("includes startup", rendered)
    @test occursin(" A", rendered)
    @test !occursin("Dict{", rendered)
    @test occursin("Requested window: 1.0 → 3.0 s", sprint(println, selected))
    @test sprint(show, MIME"text/plain"(), selected) * "\n" == sprint(println, selected)
    @test stats == Dict{Symbol, Any}(
        :bdf_orders => [1, 1, 1], :converged => true,
        :warnings => ["whole-run warning"]
    )

    rect = transient(HalfWaveRectifier(), 0s => 2ms; max_step = 100μs, saveat = 100μs)
    bounds = rect.axis[5] => rect.axis[10]
    findings = validity_report(rect; window = bounds)
    @test findings[:devices]["D1"].maximum_forward_current ≈ maximum(current(rect, :D1)[5:10])
    @test findings[:devices]["D1"].maximum_reverse_voltage ≈
        max(0.0, -minimum((voltage(rect, :vin) - voltage(rect, :vout))[5:10]))

    nr = noise(LowPass(), 10Hz => 1kHz; output = voltage(:vout), points = 3)
    nr.stats[:warnings] = ["noise warning"]
    summary = report(nr)
    @test summary[:warnings] == validity_report(nr)[:warnings]
    @test summary[:interval] == (10.0 => 1000.0)
    @test occursin("noise warning", sprint(println, summary))
    @test occursin("Hz", sprint(println, summary))
end

@testset "source current and power readout" begin
    @circuit SourceReadout() begin
        gnd = ground(); input = node(); output = node(); controlled = node()
        V = voltage_source(input, gnd; dc = 2.0, ac = 0.5, waveform = t -> 2 + t)
        B = behavioral_current_source(
            ((input, gnd),), output, gnd;
            current = (v, t) -> v[1]^2 + t,
            gradient = (v, t) -> (2v[1], 0.0, 0.0, 0.0)
        )
        I = current_source(output, gnd; dc = 0.1, ac = 0.2)
        R = resistor(output, gnd; value = 2.0)
        G = transconductance(input, gnd, controlled, gnd; gm = 0.25)
        resistor(controlled, gnd; value = 3.0)
        observe(current(B); name = :source_current)
    end
    circuit = SourceReadout()
    op = operating_point(circuit)
    @test current(op, :B) ≈ [4.0]
    @test current(op, :source_current) == current(op, :B)
    @test observation(op, :source_current) == current(op, :B)
    @test power(op, :B) ≈ voltage(op, :output) .* current(op, :B)
    @test power(op, :G) ≈ voltage(op, :controlled) .* current(op, :G)
    @test current(op, :B) + current(op, :I) + current(op, :R) ≈ [0.0] atol = 1e-12
    tr = transient(circuit, 0.0 => 0.01; max_step = 0.001)
    @test current(tr, :B) ≈ voltage(tr, :input).^2 + tr.axis
    @test current(tr, :B) + current(tr, :I) + current(tr, :R) ≈ zeros(length(tr.axis)) atol = 1e-10
    ac = small_signal(circuit, [10.0, 100.0]; source = :V)
    @test current(ac, :B) ≈ 4 .* voltage(ac, :input)
    @test current(ac, :I) == zeros(ComplexF64, 2)
    @test current(ac, :B) + current(ac, :R) ≈ zeros(ComplexF64, 2) atol = 1e-12
    selected = small_signal(circuit, [10.0]; source = "I")
    @test current(selected, :I) ≈ [0.2 + 0im]
    @test current(selected, :B) ≈ [0.0 + 0im]
    @test only(result_table(op; signals = (source_A = current(:B),))).source_A ≈ 4.0

    @circuit ControlledVoltagePower() begin
        gnd = ground(); input = node(); output = node()
        voltage_source(input, gnd; dc = 2.0)
        E = voltage_controlled_voltage_source(input, gnd, output, gnd; gain = 3.0)
        resistor(output, gnd; value = 4.0)
    end
    controlled = operating_point(ControlledVoltagePower())
    @test power(controlled, :E) ≈ [-9.0]
end

@subcircuit BehavioralReadoutBlock(p, n) begin
    B = behavioral_current_source(
        ((p, n), (n, p)), p, n;
        current = (v, t) -> v[1]^2 + 3v[2] + 1,
        gradient = (v, t) -> (2v[1], 3.0, 0.0, 0.0)
    )
    observe(current(B); name = :measured)
end

@testset "hierarchical behavioral current readout" begin
    @circuit BehavioralReadoutHierarchy() begin
        gnd = ground(); input = node()
        V = voltage_source(input, gnd; dc = 2.0, ac = 0.5)
        Block = BehavioralReadoutBlock(input, gnd)
        Bconstant = behavioral_current_source(
            (), input, gnd; current = (v, t) -> 0.25,
            gradient = (v, t) -> (0.0, 0.0, 0.0, 0.0)
        )
    end
    circuit = BehavioralReadoutHierarchy()
    op = operating_point(circuit)
    @test current(op, "Block.B") ≈ [-1.0]
    @test current(op, "Block.measured") ≈ [-1.0]
    @test current(op, :Bconstant) ≈ [0.25]
    ac = small_signal(circuit, [10.0, 100.0])
    @test current(ac, "Block.B") ≈ fill(0.5 + 0im, 2)
    @test current(ac, :Bconstant) ≈ zeros(ComplexF64, 2)
    @test current(ac, "Block.B") + current(ac, :Bconstant) + current(ac, :V) ≈ zeros(ComplexF64, 2) atol = 1e-12
end
