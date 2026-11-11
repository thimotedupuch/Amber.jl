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

@testset "sparse frequency passbands" begin
    falling = passbands([1.0, 100.0], [1.0, 0.1]; level_db = -10)
    @test length(falling) == 1
    @test falling[1].low == 1.0
    @test falling[1].high ≈ 10.0
    rising = passbands([1.0, 100.0], [0.1, 1.0]; level_db = -10)
    @test length(rising) == 1
    @test rising[1].low ≈ 10.0
    @test rising[1].high == 100.0
    edge = passbands([1.0, 10.0, 100.0], [1.0, 0.1, 0.01]; level_db = -20)
    @test length(edge) == 1
    @test edge[1].high ≈ 10.0
end

@testset "frequency metric input dimensions" begin
    @test_throws DimensionMismatch phase_delay([1.0, 2.0], [1.0im])
    @test phase_delay([1.0, 2.0], [1.0im, 1.0im]) ≈ [-0.25, -0.125]
    @test_throws ArgumentError passbands([1.0], [1.0])
    @test_throws ArgumentError passbands([2.0, 1.0], [1.0, 0.1])
    @test_throws DimensionMismatch passbands([1.0, 2.0], [1.0])
end

@testset "sampling metrics use actual edge indices" begin
    base = transient(LowPass(), 0s => 5μs; saveat = 1μs)
    values = zeros(size(base.values, 1), 6)
    values[Amber._hierarchical_net_index(base.compiled, :vin), :] .= [0, 0, 1, 1, 0, 0]
    values[Amber._hierarchical_net_index(base.compiled, :vout), :] .= [0, 0, 0, 1, 7, 8]
    result = SimulationResult(base.compiled, base.analysis, collect(0.0:5.0), values, Dict{Symbol, Any}())
    metrics = sampling_metrics(result; input = :vin, held = :vout, clock = :vin)
    @test metrics.acquisition_time == 2.0
    @test metrics.aperture_error == 7.0
    @test metrics.charge_injection_step == 6.0
    values[Amber._hierarchical_net_index(base.compiled, :vin), :] .= [1, 0, 0, 1, 1, 0]
    @test sampling_metrics(result; input = :vin, held = :vout, clock = :vin).acquisition_time == 2.0
    values[Amber._hierarchical_net_index(base.compiled, :vin), :] .= 1
    absent = sampling_metrics(result; input = :vin, held = :vout, clock = :vin)
    @test isnan(absent.acquisition_time)
    @test isnan(absent.aperture_error)
    @test isnan(absent.charge_injection_step)
end

@testset "group delay on nonuniform frequencies" begin
    fs = [1.0, 2.0, 4.0]
    response = cis.(-0.01 .* fs.^2)
    @test group_delay(fs, response)[2] ≈ 0.04 / (2π)
end

@testset "frequency crossings across numerical scales" begin
    for amplitude in (1e-200, 1.0, 1e308)
        @test only(crossings([1.0, 100.0], [-amplitude, amplitude])) ≈ 10.0
        @test only(crossings([1.0, 100.0], [amplitude, -amplitude])) ≈ 10.0
    end
end

@testset "phase delay follows unwrapped phase" begin
    fs = [0.0, 1.0, 2.0, 3.0]
    delay = phase_delay(fs, cis.(-2π .* fs .* 0.2))
    @test isnan(delay[1])
    @test delay[2:end] ≈ fill(0.2, 3)
end

@testset "passbands remain connected at threshold touches" begin
    for (response, level) in (([1.0, 1.0, 1.0], 0.0), ([1.0, 0.5, 1.0], db20(0.5)))
        bands = passbands([1.0, 10.0, 100.0], response; level_db = level)
        @test length(bands) == 1
        @test only(bands).low == 1.0
        @test only(bands).high == 100.0
    end
end

@testset "cutoffs and bands with transmission zeros" begin
    fs = [1.0, 100.0]
    for response in ([0.0, 1.0], [1.0, 0.0])
        cutoff = only(cutoff_frequencies(fs, response; reference = 1.0, level_db = db20(0.5)))
        @test cutoff ≈ 10.0
        band = only(passbands(fs, response; reference = 1.0, level_db = db20(0.5)))
        @test band.low ≈ (response[1] == 0 ? 10.0 : 1.0)
        @test band.high ≈ (response[1] == 0 ? 100.0 : 10.0)
    end
end
