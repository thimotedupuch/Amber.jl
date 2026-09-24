@testset "spectrum and harmonic analysis" begin
    @circuit SpectrumReference() begin
        gnd = ground(); output = node()
        V1 = voltage_source(output, gnd; waveform = Sine(amplitude = 2V, frequency = 1kHz))
    end
    transient_result = transient(SpectrumReference(), 0s => 10ms; initial = :discharged, saveat = 10μs, method = :bdf2)
    spectral = spectrum(transient_result; signal = :output, window = :rectangular, detrend = :none)
    @test spectral.sample_rate ≈ 100kHz rtol = 1.0e-10
    @test spectral.frequencies[argmax(spectral.amplitude_rms)] ≈ 1kHz rtol = 0.02
    @test maximum(spectral.amplitude_rms) ≈ sqrt(2) rtol = 0.03
    @test crest_factor(spectral) ≈ sqrt(2) rtol = 0.03
    @test band_power(spectral, 800Hz => 1200Hz) > 1.8

    harmonic = harmonic_analysis(transient_result; signal = :output, fundamental = 1kHz, window = :rectangular, harmonics = 5)
    @test harmonic.fundamental.frequency ≈ 1kHz rtol = 0.02
    @test thd(harmonic) < 0.02
    @test thdn(harmonic) < 0.03
end
