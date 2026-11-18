@testset "spectrum and harmonic analysis" begin
    @circuit SpectrumReference() begin
        gnd = ground(); output = node()
        V1 = voltage_source(output, gnd; waveform = Sine(amplitude = 2V, frequency = 1kHz))
    end
    transient_result = transient(SpectrumReference(), 0s => 10ms; initial = :discharged, saveat = 10μs, method = :bdf2)
    spectral = spectrum(transient_result; signal = :output, window = :rectangular, detrend = :none)
    @test spectral.sample_rate ≈ 100000.0 rtol = 1.0e-10
    @test frequencies(spectral)[argmax(spectral.amplitude_rms)] ≈ 1kHz rtol = 0.02
    @test maximum(spectral.amplitude_rms) ≈ sqrt(2) rtol = 0.03
    @test crest_factor(spectral) ≈ sqrt(2) rtol = 0.03
    @test band_power(spectral, 800Hz => 1200Hz) > 1.8

    harmonic = harmonic_analysis(transient_result; signal = :output, fundamental = 1kHz, window = :rectangular, harmonics = 5)
    @test harmonic.fundamental.frequency ≈ 1000.0 rtol = 0.02
    for nfft in (1001, 1002)
        odd_or_even = harmonic_analysis(transient_result; signal = :output,
            fundamental = 1kHz, window = :rectangular, harmonics = 5, nfft)
        peak_bin = odd_or_even.fundamental.bin
        expected_offset, _ = Amber._quadratic_peak(odd_or_even.spectrum.amplitude_rms, peak_bin)
        @test odd_or_even.fundamental.frequency ≈
            (peak_bin - 1 + expected_offset) * odd_or_even.spectrum.sample_rate / nfft
    end
    for invalid in (0.0, -1.0, Inf, NaN, 1e9)
        @test_throws ArgumentError harmonic_analysis(transient_result; signal = :output, fundamental = invalid)
    end
    for invalid in (0, -1, 1.5)
        @test_throws ArgumentError harmonic_analysis(transient_result; signal = :output, harmonics = invalid)
    end
    @test thd(harmonic) < 0.02
    @test thdn(harmonic) < 0.03
    short_record = harmonic_analysis(transient_result; signal = :output,
        fundamental = 1kHz, window = :rectangular, interval = 2ms => 4ms)
    @test short_record.stats[:fundamental_cycles] ≈ 2 rtol = 0.02
    @test any(occursin("fewer than four", warning) for warning in short_record.stats[:warnings])

    times = collect(0:999) ./ 100_000
    distorted_values = copy(transient_result.values[:, 1:1000])
    output_index = Amber._hierarchical_net_index(transient_result.compiled, :output)
    distorted_values[output_index, :] .= sin.(2π * 1000 .* times) .+ 0.1sin.(2π * 2000 .* times)
    distorted = SimulationResult(transient_result.compiled, transient_result.analysis,
        times, distorted_values, Dict{Symbol, Any}())
    distortion = harmonic_analysis(distorted; signal = :output, fundamental = 1kHz,
        window = :rectangular, harmonics = 5)
    @test sfdr(distortion) ≈ 20 atol = 0.1
    for window in (:hann, :hamming, :blackman_harris), nfft in (1000, 4000)
        tapered = harmonic_analysis(distorted; signal = :output, fundamental = 1kHz, window, nfft, harmonics = 5)
        @test thd(tapered) ≈ 0.1 atol = 0.002
        # Zero padding resolves window sidelobes outside the integrated main lobe.
        # Their residual power remains part of THD+N.
        @test thdn(tapered) ≈ 0.1 atol = 0.003
        @test sfdr(tapered) ≈ 20 atol = 0.1
    end

    for invalid_time in (NaN, Inf, transient_result.axis[1], -1.0)
        invalid_axis = copy(transient_result.axis)
        invalid_axis[2] = invalid_time
        invalid_result = SimulationResult(transient_result.compiled, transient_result.analysis,
            invalid_axis, transient_result.values, Dict{Symbol, Any}())
        @test_throws ArgumentError spectrum(invalid_result; signal = :output)
    end

    for samples in (fill(2.0, 1000), 2.0 .* (-1.0) .^ (0:999))
        edge_values = copy(transient_result.values[:, 1:1000])
        edge_values[output_index, :] .= samples
        edge_result = SimulationResult(transient_result.compiled, transient_result.analysis,
            times, edge_values, Dict{Symbol, Any}())
        edge_spectrum = spectrum(edge_result; signal = :output, window = :rectangular, detrend = :none)
        @test band_power(edge_spectrum, 0.0 => last(edge_spectrum.frequencies)) ≈ 4.0
        peak_frequency = edge_spectrum.frequencies[argmax(edge_spectrum.psd)]
        @test band_power(edge_spectrum, peak_frequency => peak_frequency) ≈ 4.0
    end

    silent = SimulationResult(transient_result.compiled, transient_result.analysis,
        times, zeros(size(distorted_values)), Dict{Symbol, Any}())
    silent_harmonics = harmonic_analysis(silent; signal = :output,
        fundamental = 1kHz, window = :rectangular)
    @test isnan(snr(silent_harmonics))
    @test isnan(sinad(silent_harmonics))
    @test isnan(sfdr(silent_harmonics))
    @test isnan(enob(silent_harmonics))

    for invalid in (NaN, Inf)
        invalid_values = copy(distorted_values)
        invalid_values[output_index, 20] = invalid
        invalid_signal = SimulationResult(transient_result.compiled, transient_result.analysis,
            times, invalid_values, Dict{Symbol, Any}())
        @test_throws ArgumentError spectrum(invalid_signal; signal = :output)
    end

end

@testset "manual spectrum bin width" begin
    result = SpectrumResult([0.0, 1.0, 2.0], ComplexF64[0, 1, 0],
        [0.0, 0.5, 0.0], [0.0, 0.25, 0.0], 4.0, :hann, 0.5, 1.0,
        Dict{Symbol, Any}())
    @test band_power(result, 0Hz => 2Hz) == 0.25
end
