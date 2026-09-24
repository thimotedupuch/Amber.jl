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
