@testset "analysis metrics" begin
    result = transient(LowPass(), 0s => 1ms; saveat = 10μs)
    ripple = peak_to_peak(voltage(:vout), window = 500μs => 1ms)
    @test ripple(result) >= 0
    @test overshoot(result, :vout) >= 0
    @test propagation_delay(result; input = :vin, output = :vout) > 0
    periodic_module = Module(:PeriodicMetricsTest)
    Core.eval(periodic_module, :(using Amber))
    periodic_result = transient(LowPass(), 0s => 1ms; saveat = 10μs)
    comparison = compare(small_signal(LowPass(), 10Hz => 1kHz; points = 10), small_signal(LowPass(R = 20kΩ), 10Hz => 1kHz; points = 10); observable = voltage(:vout))
    @test length(comparison.error) == 10
end

@testset "directional delay and CMOS measurements without plotting" begin
    # Repeating piecewise-linear inverter with known .2/.4 s delays.
    t = collect(0.0:0.025:10.0)
    phase = mod.(t, 5.0)
    vin = [q < 2 ? clamp((q - 0.9) / 0.2, 0, 1) : clamp((3.1 - q) / 0.2, 0, 1) for q in phase]
    vout = [q < 2 ? 1 - clamp((q - 1.1) / 0.2, 0, 1) : clamp((q - 3.3) / 0.2, 0, 1) for q in phase]
    @test first(vin) == last(vin) == 0
    @test_throws ArgumentError propagation_delay(t, vin, vout)
    for occurrence in (1, 2)
        @test propagation_delay(
            t, vin, vout; threshold = 0.5, input_edge = :rising,
            output_edge = :falling, occurrence
        ) ≈ 0.2 atol = 1.0e-12
        @test propagation_delay(
            t, vin, vout; threshold = 0.5, input_edge = :falling,
            output_edge = :rising, occurrence
        ) ≈ 0.4 atol = 1.0e-12
    end
    @test propagation_delay(t, vin, vout; window = 0.5 => 2.0) ≈ 0.2 atol = 1.0e-12
    @test propagation_delay(
        t, vin, 2 .* vout; input_threshold = 0.5, output_threshold = 1.0,
        input_edge = :rising, output_edge = :falling
    ) ≈ 0.2 atol = 1.0e-12
    @test isnan(propagation_delay(t, vin, vout; input_edge = :rising, output_edge = :rising))
    @test isnan(propagation_delay(t, vin, ones(length(t)); input_edge = :rising, output_edge = :falling))
    @test isnan(propagation_delay(t, vin, vout; input_edge = :rising, output_edge = :falling, occurrence = 3))
    ring = copy(vout); ring[1.8 .< t .< 2.2] .= 1.0
    @test isnan(propagation_delay(t, vin, ring; input_edge = :rising, output_edge = :falling))
    @test_throws ArgumentError propagation_delay(t, vin, vout; input_edge = :up)
    @test_throws ArgumentError propagation_delay(t, vin, vout; threshold = NaN)
    @test_throws ArgumentError propagation_delay(t, vin, vout; occurrence = 0)
    @test_throws ArgumentError propagation_delay(t, vin, vout; window = -1 => 2)

    switching_measure = switchingmetrics(t, vin, vout, 2 .* t .+ 1; vdd = 1.0, window = 0.25 => 9.75)
    @test switching_measure.tphl ≈ 0.2 atol = 1.0e-12
    @test switching_measure.tplh ≈ 0.4 atol = 1.0e-12
    @test length(switching_measure.phl) == length(switching_measure.plh) == 2
    @test switching_measure.energy ≈ 104.5
    @test isnan(switchingmetrics(t, vin, ring, ones(length(t)); vdd = 1.0, window = 0.25 => 4.75).tphl)
    @test_throws ArgumentError switchingmetrics(t, vin, vout, ones(length(t)); vdd = 0.0, window = 0 => 4)

    x = collect(range(0, 1.8; length = 1001)); y = 1.8 ./ (1 .+ exp.(12 .* (x .- 0.9)))
    v = invertermetrics(x, y); m = v.measurements
    q = (1 - sqrt(1 - 4 / (1.8 * 12))) / 2
    @test m.vm ≈ 0.9
    @test m.vil ≈ 0.9 - log((1 - q) / q) / 12 atol = 2.0e-5
    @test m.nml ≈ m.nmh atol = 1.0e-12
    @test isempty(v.warnings)
    bad = copy(y); bad[500] = NaN
    incomplete = invertermetrics(x, bad)
    @test isnan(incomplete.measurements.nml)
    @test !isempty(incomplete.warnings)
    @test_throws ArgumentError invertermetrics([0.0, 0.0], [1.0, 0.0])

    result = transient(LowPass(), 0s => 1ms; saveat = 10μs)
    stats = copy(result.stats); stats[:converged] = false
    partial = SimulationResult(result.compiled, result.analysis, result.axis, result.values, stats)
    @test_throws ArgumentError propagation_delay(partial; input = :vin, output = :vout)
    @test_throws ArgumentError switchingmetrics(partial; input = :vin, output = :vout, supply = :V1, vdd = 1.0, window = 0 => 1ms)
    @test_throws ArgumentError propagation_delay(operating_point(LowPass()); input = :vin, output = :vout)
end
