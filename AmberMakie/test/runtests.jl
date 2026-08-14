using Test
using Amber
using AmberMakie
import Makie
using CairoMakie
using TOML
CairoMakie.activate!()

@testset "engineering formatting" begin
    @test engineering(0; unit="V") == "0 V"
    @test engineering(1.25e-3; unit="V") == "1.25 mV"
    @test engineering(2.4e9; unit="Hz") == "2.4 GHz"
    @test engineering(-8e-12; unit="A") == "-8.0 pA"
    @test_throws ArgumentError engineering(1; digits=0)
end

@testset "control plots" begin
    frequencies = [1.0, 10.0, 100.0]
    values = reshape(ComplexF64[1, 1im, -1], 1, 1, :)
    response = Amber.LinearFrequencyResponse(frequencies, values, ["in"], [voltage(:out)], Dict{Symbol,Any}())
    @test hasproperty(nyquistplot(Makie.Figure()[1, 1], response).axes, :nyquist)
    @test hasproperty(nicholsplot(Makie.Figure()[1, 1], response).axes, :nichols)
    @test hasproperty(bodeplot(Makie.Figure()[1, 1], response).axes, :magnitude)
    delay = groupdelayplot(Makie.Figure()[1, 1], response)
    @test length(last(delay.view)) == 3
    @circuit MakieParticipation() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; dc=1V, ac=1V)
        R1 = resistor(input, output; value=1kΩ)
        C1 = capacitor(output, gnd; value=1nF)
    end
    model = linearize(MakieParticipation(); inputs=:V1, outputs=voltage(:output))
    participation = poleparticipationplot(Makie.Figure()[1, 1], model)
    @test sum(participation.view.full_participation) ≈ 1
    waterfall = waterfallplot(Makie.Figure()[1, 1], [1.0, 2.0, 3.0],
        [10.0, 20.0], [1.0 2.0; 2.0 3.0; 3.0 4.0])
    @test size(waterfall.view.values) == (3, 2)
end

@testset "statistical adapters and plots" begin
    sweep = Amber.SweepResult("R.value", Any[1.0, 2.0, 3.0], Any[2.0, nothing, 6.0],
        Any[nothing, nothing, nothing], BitVector([true, false, true]),
        [Amber.SweepFailure(2, 2.0, :ErrorException, "failed")], Amber.OperatingPoint(), Dict{Symbol,Any}())
    view = ensembleview(sweep)
    @test view.converged == [true, false, true]
    @test hasproperty(sweepplot(Makie.Figure()[1, 1], sweep).axes, :sweep)
    sweep_workbench = workbench(sweep)
    selectsample!(sweep_workbench, 2)
    @test sweep_workbench.selection[] == [:sweep_2]
    @test occursin("failed", sweep_workbench.measurements[:details][])
    close(sweep_workbench)
    reverse_sweep = Amber.SweepResult("R.value", Any[3.0, 2.0, 1.0],
        Any[5.5, 3.5, 1.5], Any[nothing, nothing, nothing], trues(3),
        Amber.SweepFailure[], Amber.OperatingPoint(), Dict{Symbol,Any}())
    transfer_handle = transfercharacteristicplot(Makie.Figure()[1, 1], sweep;
        reverse=reverse_sweep)
    @test transfer_handle.view.derivative == [2.0, 2.0]
    @test transfer_handle.view.hysteresis == [0.5, 0.5]
    sensitivity_handle = sensitivityplot(Makie.Figure()[1, 1],
        Dict(:R => -2.0, :C => 0.5))
    @test sensitivity_handle.view.labels == ["R", "C"]
    monte = Amber.MonteCarloResult(Amber.OperatingPoint(), Union{Nothing,Float64}[1.0, 2.0, nothing],
        [Dict(:resistance => 1.0), Dict(:resistance => 2.0), Dict{Symbol,Float64}()], UInt64[1, 2, 3], BitVector([true, true, false]),
        [Amber.MonteCarloFailure(3, UInt64(3), :ConvergenceError, "failed")], Dict{Symbol,Any}())
    ensemble_handle = ensembleplot(Makie.Figure()[1, 1], monte)
    @test length(ensemble_handle.view.metrics) == 3
    @test ensemble_handle.plots.confidence !== nothing
    @test correlationplot(Makie.Figure()[1, 1], monte; parameter=:resistance).view.metric == [1.0, 2.0]
    yield_handle = yieldplot(Makie.Figure()[1, 1], monte; limits=0.5 => 1.5)
    @test yield_handle.view.passed == [true, false]
    @test hasproperty(failureplot(Makie.Figure()[1, 1], monte).axes, :failures)
    matrix = parametermatrixplot(Makie.Figure()[1, 1], monte)
    @test size(matrix.view.correlations) == (2, 2)
    @test matrix.view.correlation === :spearman
    @test rank_correlation([1.0, 2.0, 3.0], [1.0, 4.0, 9.0]) == 1.0
    @test sampleplot(Makie.Figure()[1, 1], monte, 2).view.seed == UInt64(2)
    grid_monte = Amber.MonteCarloResult(Amber.OperatingPoint(),
        Union{Nothing,Float64}[0.2, 0.8, 1.2, 1.8],
        [Dict(:x => 0.0, :y => 0.0), Dict(:x => 1.0, :y => 0.0),
            Dict(:x => 0.0, :y => 1.0), Dict(:x => 1.0, :y => 1.0)],
        UInt64[1, 2, 3, 4], trues(4), Amber.MonteCarloFailure[], Dict{Symbol,Any}())
    yield_map = yieldmapplot(Makie.Figure()[1, 1], grid_monte;
        x=:x, y=:y, predicate=value -> value <= 1.0, bins=(2, 2), contours=false)
    @test sum(yield_map.view.totals) == 4
    @test sum(yield_map.view.passed) == 2
    outlier_result = Amber.MonteCarloResult(Amber.OperatingPoint(),
        Union{Nothing,Float64}[1.0, 1.0, 1.0, 1.0, 10.0],
        [Dict(:x => Float64(index)) for index in 1:5], UInt64[1, 2, 3, 4, 5],
        trues(5), Amber.MonteCarloFailure[], Dict{Symbol,Any}())
    @test outlier_samples(outlier_result) == [5]
    outlier_correlation = correlationplot(Makie.Figure()[1, 1], outlier_result;
        parameter=:x)
    @test outlier_correlation.view.outliers == [5]
    monte_workbench = workbench(monte; predicate=value -> value < 1.5)
    @test monte_workbench.measurements[:selected_sample][] == 1
    @test haskey(monte_workbench.axes, :correlation)
    @test monte_workbench.measurements[:linked_parameter] == :resistance
    selectsample!(monte_workbench, 2)
    @test monte_workbench.selection[] == [:sample_2]
    @test occursin("Replay unavailable", monte_workbench.measurements[:replay_text][])
    @test_throws ArgumentError replay_sample!(monte_workbench)
    close(monte_workbench)

    @circuit MakieMonteReplay() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; dc=1V)
        R1 = resistor(input, output; value=1kΩ)
        R2 = resistor(output, gnd; value=2kΩ)
    end
    replay_circuit = MakieMonteReplay()
    replay_metric = simulation -> voltage(simulation, :output)[1]
    replay_result = monte_carlo(replay_circuit; samples=3, seed=7,
        variations=Dict(Symbol("R1.value") => Gaussian(1kΩ, 20Ω)),
        metric=replay_metric)
    replay_workbench = workbench(replay_result; circuit=replay_circuit,
        metric=replay_metric)
    selectsample!(replay_workbench, 2)
    comparison = replay_sample!(replay_workbench)
    @test comparison.matches
    @test comparison.replayed == comparison.stored
    @test occursin("Replay MATCH", replay_workbench.measurements[:replay_text][])
    close(replay_workbench)
end

@testset "network and control integration" begin
    @circuit MakieSmallSignalWorkbench() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; ac=1V)
        R1 = resistor(input, output; value=1kΩ)
        C1 = capacitor(output, gnd; value=1e-6)
    end
    ac = small_signal(MakieSmallSignalWorkbench(), [1.0, 10.0, 100.0];
        source=:V1)
    ac_workbench = workbench(ac; input=voltage(:input), output=voltage(:output),
        outputs=[voltage(:output), voltage(:input)])
    @test hasproperty(ac_workbench.axes, :nyquist)
    @test length(ac_workbench.measurements[:output_choices]) == 2
    setcursor!(ac_workbench.cursors, :a, 90.0)
    @test ac_workbench.measurements[:frequency_readout][].a.frequency == 100.0
    ac_workbench.measurements[:selected_output][] = voltage(:input)
    @test ac_workbench.measurements[:frequency_readout][].a.gain_db ≈ 0.0 atol=1e-10
    @test occursin("Shift-click", ac_workbench.measurements[:help])
    close(ac_workbench)

    @circuit MakieTwoPort() begin
        gnd = ground(); input = node(); output = node()
        R1 = resistor(input, output; value=1kΩ)
        R2 = resistor(input, gnd; value=2kΩ)
        R3 = resistor(output, gnd; value=3kΩ)
    end
    result = port_response(MakieTwoPort(), [10Hz, 1kHz];
        ports=[Port(:input, :gnd; name=:input), Port(:output, :gnd; name=:output)])
    @test networkview(result; parameter=:s, element=(2, 1)).port_labels == ["input", "output"]
    @test hasproperty(networkplot(Makie.Figure()[1, 1], result).axes, :magnitude)
    @test hasproperty(smithplot(Makie.Figure()[1, 1], result).axes, :smith)
    smith_readout = smith_cursor_readout(result, 800.0; element=(1, 1))
    @test smith_readout.frequency == 1_000.0
    @test smith_readout.impedance ≈ inv(smith_readout.admittance)
    @test_throws ArgumentError smith_cursor_readout(result, 10.0; element=(2, 1))
    @test hasproperty(stabilitycircleplot(Makie.Figure()[1, 1], result).axes, :stability)
    impedance = impedanceplot(Makie.Figure()[1, 1], result;
        quantity=:admittance, view=:magnitude_phase)
    @test hasproperty(impedance.axes, :secondary)
    @test impedance.view.quantity === :admittance
    network_workbench = workbench(result)
    @test hasproperty(network_workbench.axes, :smith)
    @test length(network_workbench.measurements[:element_choices]) == 4
    @test network_workbench.measurements[:smith_a][].frequency == 10.0
    setcursor!(network_workbench.cursors, :a, 900.0)
    @test network_workbench.measurements[:smith_a][].frequency == 1_000.0
    network_workbench.measurements[:selected_element][] = (2, 1)
    @test network_workbench.selection[] == [:S21]
    @test network_workbench.measurements[:smith_a][].impedance === nothing
    network_workbench.measurements[:selected_parameter][] = :z
    @test network_workbench.selection[] == [:Z21]
    network_recipe = copyrecipe(network_workbench)
    @test occursin(":selected_parameter", network_recipe)
    @test occursin("parameter=:s", network_recipe)
    @test occursin("handle.plots.magnitude", network_recipe)
    network_workbench.measurements[:selected_element][] = (2, 2)
    @test network_workbench.measurements[:smith_a][].impedance !== nothing
    close(network_workbench)
end

@testset "study lifecycle" begin
    calls = Ref(0)
    study = explore(parameters=(gain=(1.0, 9.0, :log),)) do parameters
        calls[] += 1
        parameters.gain * 2
    end
    @test study.parameters[:gain] == 3.0
    runstudy!(study); wait(study.task)
    @test study.status[] === :ready
    @test study.result[] == 6.0
    pin!(study); @test study.pinned == [6.0]
    runstudy!(study)
    @test calls[] == 1
    setparameter!(study, :gain, 4.0; run=true); wait(study.task)
    @test study.result[] == 8.0
    close(study); @test study.status[] === :closed
    @test isempty(study.subscriptions)
end

@testset "exact measurements" begin
    x = collect(0.0:1.0:4.0)
    y = x .^ 2
    @test nearest_sample(x, y, 1.6) == CursorSample(3, 2.0, 4.0)
    cursors = cursor_readout(x, y, 1.1, 3.2)
    @test cursors.a.x == 1.0
    @test cursors.b.x == 3.0
    @test cursors.delta_x == 2.0
    @test cursors.delta_y == 8.0
    @test cursors.slope == 4.0
    interval = interval_readout(x, y, 1.0 => 3.0)
    @test interval.samples == 3
    @test interval.peak_to_peak == 8.0
    @test interval.integral == 9.0
    @test_throws ArgumentError interval_readout(x, y, 1.2 => 1.8)
end

@testset "cursor state" begin
    state = CursorState([1.0, 2.0, 3.0], [2.0, 4.0, 8.0])
    setcursor!(state, :a, 2.1)
    setcursor!(state, :b, 3.0)
    @test state.readout[].a.index == 2
    @test state.readout[].delta_y == 4.0
    setinterval!(state, 1.0 => 2.0)
    @test state.interval_readout[].samples == 2
    AmberMakie._close!(state)
    @test isempty(state.subscriptions)
end

@testset "spectrum adapter" begin
    result = SpectrumResult([0.0, 1.0], ComplexF64[0, 1], [0.0, 0.5], [0.0, 0.25],
        2.0, :hann, 0.5, 1.0, Dict{Symbol,Any}(:warnings => ["example"]))
    view = spectrumview(result)
    @test view.frequencies === result.frequencies
    @test view.amplitude_rms === result.amplitude_rms
    @test view.window === :hann
    @test view.warnings == ["example"]
    cursor = spectrum_cursor(result, 0.9; fundamental=1.0)
    @test cursor.classification === :fundamental
    @test cursor.harmonic_order == 1
    @test cursor.frequency == 1.0
    spectrum_handle = spectrumplot(Makie.Figure()[1, 1], result;
        scale=:dbv, band=0.0 => 1.0, fundamental=1.0)
    @test hasproperty(spectrum_handle.axes, :spectrum)
    @test startswith(copyrecipe(spectrum_handle), "handle = spectrumplot")
    @test occursin("Makie.xlims!", copyrecipe(spectrum_handle))
    @test occursin("handle.plots.spectrum", copyrecipe(spectrum_handle))
    @test_throws ArgumentError spectrumplot(Makie.Figure()[1, 1], result; scale=:dbfs)
end

@testset "spectrogram and noise detail plots" begin
    @circuit MakieSignal() begin
        gnd = ground(); output = node()
        V1 = voltage_source(output, gnd; waveform=Sine(amplitude=1V, frequency=1kHz))
    end
    transient_result = transient(MakieSignal(), 0s => 4ms;
        initial=:discharged, saveat=20μs, method=:bdf2)
    transient_workbench = workbench(transient_result;
        signals=[:output, current(:V1)])
    @test length(transient_workbench.measurements[:signal_choices]) == 2
    selectsignal!(transient_workbench, current(:V1))
    @test transient_workbench.measurements[:selected_signal][] == current(:V1)
    @test !transient_workbench.plots[1].visible[]
    @test transient_workbench.plots[2].visible[]
    @test occursin("selectsignal!", copyrecipe(transient_workbench))
    close(transient_workbench)
    spectrogram = spectrogramview(transient_result; signal=:output, samples=64,
        overlap=0.5, window=:hann)
    @test size(spectrogram.psd) == (length(spectrogram.frequencies), length(spectrogram.times))
    @test issorted(spectrogram.times)
    @test hasproperty(spectrogramplot(Makie.Figure()[1, 1], transient_result;
        signal=:output, samples=64).axes, :spectrogram)
    eye = eyediagramview(transient_result; signal=:output, period=1e-3,
        mask=(phase, value) -> abs(value) > 0.9)
    @test !isempty(eye.phases)
    @test !isempty(eye.violations)
    @test hasproperty(eyediagramplot(Makie.Figure()[1, 1], transient_result;
        signal=:output, period=1e-3).axes, :eye)
    jitter = jitterview(transient_result; signal=:output, nominal_period=1e-3)
    @test length(jitter.crossings) >= 3
    @test maximum(abs, jitter.period_jitter) < 1e-5
    bathtub = jitterplot(Makie.Figure()[1, 1], transient_result;
        signal=:output, nominal_period=1e-3, kind=:bathtub)
    @test bathtub.view.kind === :bathtub
    @test all(>(0), bathtub.view.display.y)
    comparison_result = transient(MakieSignal(), 0.1ms => 3.9ms;
        initial=:discharged, saveat=25μs, method=:bdf2)
    comparison = compareplot(Makie.Figure()[1, 1],
        [transient_result, comparison_result]; signals=:output,
        alignment=:interpolate, tolerance=(; atol=0.05, rtol=0.01))
    @test hasproperty(comparison.axes, :delta)
    @test comparison.view.diagnostics[2].compared < length(transient_result.axis)
    @test comparison.view.diagnostics[2].outside_domain > 0
    soa = safeoperatingareaplot(Makie.Figure()[1, 1], transient_result;
        device=:V1, voltage=:output,
        limits=(max_voltage=0.5, max_current=1.0, max_power=1.0))
    @test !isempty(soa.view.violations)
    pss = Amber.PSSResult(transient_result, 4e-3, 1e-8, 3,
        begin
            matrix = zeros(size(transient_result.values, 1), size(transient_result.values, 1))
            matrix[1, 1] = 0.5; matrix[end, end] = 1.1; matrix
        end,
        ComplexF64[0.5, 1.1], false, nothing,
        Dict{Symbol,Any}(:converged => true, :warnings => String[]))
    pss_handle = pssplot(Makie.Figure()[1, 1], pss; signals=:output)
    @test hasproperty(pss_handle.axes, :floquet)
    @test pss_handle.view.unstable_multipliers == 1
    mode = floquet_mode(pss, :dominant)
    @test mode.multiplier ≈ 1.1
    @test sum(mode.participation) ≈ 1
    pss_workbench = workbench(pss; signals=[:output, current(:V1)])
    @test hasproperty(pss_workbench.axes, :mode_participation)
    @test hasproperty(pss_workbench.axes, :linked_state)
    @test pss_workbench.measurements[:selected_mode][].multiplier ≈ 1.1
    selected_state = pss_workbench.measurements[:selected_state][]
    @test pss_workbench.measurements[:state_trace][] ==
        real.(pss.orbit.values[selected_state, :])
    pss_workbench.measurements[:mode_index][] = 1
    @test pss_workbench.selection[][1] == :mode_1
    @test pss_workbench.measurements[:selected_state][] ==
        argmax(pss_workbench.measurements[:selected_mode][].participation)
    selectsignal!(pss_workbench, current(:V1))
    @test pss_workbench.selection[][3] == Symbol(string(current(:V1)))
    @test !pss_workbench.plots.traces[1].visible[]
    @test pss_workbench.plots.traces[2].visible[]
    close(pss_workbench)
    harmonic_result = harmonic_analysis(transient_result; signal=:output,
        fundamental=1e3, harmonics=3)
    harmonic_workbench = workbench(harmonic_result)
    @test harmonic_workbench.measurements[:harmonic_cursor][].order == 1
    harmonic_workbench.measurements[:selected_order][] = 2
    @test harmonic_workbench.selection[] == [:H2]
    close(harmonic_workbench)

    @circuit MakieNoise() begin
        gnd = ground(); input = node(); output = node()
        V1 = voltage_source(input, gnd; dc=1V, ac=1V)
        R1 = resistor(input, output; value=1kΩ)
        R2 = resistor(output, gnd; value=2kΩ)
    end
    operating_point_result = operating_point(MakieNoise())
    operating_view = operatingpointview(operating_point_result)
    @test any(row -> row.name == "output", operating_view.nodes)
    @test any(row -> row.name == "R1" && row.power !== nothing,
        operating_view.devices)
    @test only(operatingpointview(operating_point_result; query="r1").devices).name == "R1"
    operating_handle = operatingpointplot(Makie.Figure()[1, 1], operating_point_result)
    @test hasproperty(operating_handle.axes, :devices)
    operating_workbench = workbench(operating_point_result)
    selectcomponent!(operating_workbench, "R1")
    @test operating_workbench.selection[] == [:R1]
    @test operating_workbench.measurements[:convergence].converged
    @test hasproperty(operating_workbench.axes, :convergence)
    @test operating_workbench.measurements[:convergence].history_available
    @test !isempty(operating_workbench.measurements[:convergence].history)
    @test length(operating_workbench.measurements[:convergence].history) ==
        operating_workbench.measurements[:convergence].iterations
    @test operating_workbench.measurements[:convergence].dominant_residual === nothing
    close(operating_workbench)
    power_handle = powerdashboard(Makie.Figure()[1, 1], operating_point_result;
        output=:R2)
    @test power_handle.view.supplied > 0
    @test 0 <= power_handle.view.efficiency <= 1
    noise_result = noise(MakieNoise(), [10Hz, 100Hz, 1kHz, 10kHz];
        output=voltage(:output), input=:V1)
    contributions = noisecontributionview(noise_result; group=:component)
    @test !isempty(contributions.values)
    @test issorted(contributions.values; rev=true)
    @test contributions.total_variance >= 0
    @test hasproperty(noisecontributionplot(Makie.Figure()[1, 1], noise_result).axes,
        :noise_contributions)
    budget = noisebudgetplot(Makie.Figure()[1, 1], noise_result;
        group=:component)
    @test hasproperty(budget.axes, :noise_budget)
    @test size(budget.view.spectra, 2) == length(noise_result.frequencies)
    integrated = integratednoiseplot(Makie.Figure()[1, 1], noise_result)
    @test issorted(integrated.view.rms)
    @test integrated.view.rms[1] == 0
    noise_workbench = workbench(noise_result)
    @test hasproperty(noise_workbench.axes, :noise_contributions)
    @test noise_workbench.measurements[:band_rms][] > 0
    full_band_rms = noise_workbench.measurements[:band_rms][]
    setinterval!(noise_workbench.cursors, 100.0 => 1_000.0)
    @test noise_workbench.cursors.interval[] == (100.0 => 1_000.0)
    @test noise_workbench.measurements[:band_rms][] < full_band_rms
    close(noise_workbench)
    phase_ratio = fill(1e-12, length(noise_result.frequencies))
    phase_result = Amber.PhaseNoiseResult(noise_result.frequencies, noise_result.output,
        phase_ratio, 10log10.(phase_ratio), 1e-6, noise_result.output_psd,
        noise_result.contributions, zeros(1, length(noise_result.frequencies)),
        1.0 + 0im, noise_result.compiled,
        Dict{Symbol,Any}(:warnings => ["synthetic phase-noise fixture"]))
    grouped_diagnostics = diagnosticgroups(phase_result)
    @test grouped_diagnostics.groups["General"] == ["synthetic phase-noise fixture"]
    @test hasproperty(diagnosticplot(Makie.Figure()[1, 1], phase_result).plots,
        :device_validity)
    phase_handle = phasenoiseplot(Makie.Figure()[1, 1], phase_result;
        carrier_frequency=1e6)
    @test phase_handle.view.integrated > 0
    @test phase_handle.view.carrier_frequency == 1e6
    phase_workbench = workbench(phase_result; carrier_frequency=1e6)
    @test haskey(phase_workbench.measurements, :integrated_phase)
    @test hasproperty(phase_workbench.axes, :noise_budget)
    @test phase_workbench.measurements[:contributions][].total_variance > 0
    @test haskey(phase_workbench.measurements, :validity)
    full_phase = phase_workbench.measurements[:integrated_phase][]
    setinterval!(phase_workbench.cursors, 100.0 => 1_000.0)
    @test phase_workbench.measurements[:integrated_phase][] < full_phase
    close(phase_workbench)
    sidebands = [-1, 0, 1]
    periodic_result = Amber.PeriodicNoiseResult(noise_result.frequencies,
        noise_result.output, nothing, 1, sidebands, noise_result.output_psd,
        nothing, fill(1e-12, length(sidebands), length(noise_result.frequencies)),
        noise_result.contributions, noise_result.compiled,
        Dict{Symbol,Any}(:warnings => String[]))
    @test hasproperty(periodicnoiseplot(Makie.Figure()[1, 1], periodic_result).axes,
        :periodic_noise)
    periodic_workbench = workbench(periodic_result)
    @test hasproperty(periodic_workbench.axes, :periodic_noise)
    close(periodic_workbench)
    linked_periodic = workbench(periodic_result; pss=pss, signals=:output)
    @test linked_periodic.axes.orbit !== nothing
    linked_periodic.measurements[:selected_sideband][] = -1
    @test linked_periodic.selection[] == [Symbol("sideband_-1")]
    @test linked_periodic.measurements[:sideband_readout][].translated_frequency !== nothing
    close(linked_periodic)
    report_handle = reportfigure(noise_result)
    @test report_handle.view.template === :noise
    @test report_handle.view.metrics.integrated_noise_rms > 0
    @test !isempty(report_handle.view.provenance)
    @test hasproperty(report_handle.axes, :metrics)
    @test hasproperty(report_handle.axes, :provenance)
    @test occursin("Integrated over", report_handle.view.annotation_text)
    @test length(report_handle.view.metric_table.labels) > 1
    directory = mktempdir(); report_path = joinpath(directory, "noise-report.png")
    @test savefigure(report_path, report_handle) == report_path
    @test isfile(report_path * ".toml")
    @test occursin("provenance", read(report_path * ".toml", String))
end

@testset "workbench ownership" begin
    result = SpectrumResult([0.0, 1.0, 2.0], ComplexF64[0, 1, 0], [0.0, 0.5, 0.0],
        [0.0, 0.25, 0.0], 4.0, :hann, 0.5, 1.0,
        Dict{Symbol,Any}(:warnings => ["inspect sampling"]),)
    handle = workbench(result)
    @test handle.warnings == ["inspect sampling"]
    setcursor!(handle.cursors, :a, 0.9)
    @test handle.measurements[:spectrum_cursor][].frequency == 1.0
    @test !isempty(handle.cursors.subscriptions)
    setcursor!(handle.cursors, :a, 0.8)
    @test handle.measurements[:cursors][].a.x == 1.0
    @test haskey(handle.measurements, :context_toolbar)
    @test handle.measurements[:legend_entries] == ["spectrum"]
    isolatetrace!(handle, "spectrum")
    @test handle.measurements[:isolated_trace][] == "spectrum"
    toggletrace!(handle, "spectrum")
    @test !handle.plots.spectrum.visible[]
    showalltraces!(handle)
    @test handle.plots.spectrum.visible[]
    @test !isempty(helptext(handle))
    close(handle)
    @test handle.closed
    @test isempty(handle.cursors.subscriptions)
    @test isempty(handle.measurements[:control_subscriptions])
    close(handle)
end

@testset "Cairo export" begin
    result = SpectrumResult([0.0, 1.0], ComplexF64[0, 1], [0.0, 0.5], [0.0, 0.25],
        2.0, :hann, 0.5, 1.0, Dict{Symbol,Any}(:warnings => String[]))
    handle = workbench(result)
    directory = mktempdir(); path = joinpath(directory, "spectrum.png")
    @test savefigure(path, handle) == path
    @test isfile(path)
    @test isfile(path * ".toml")
    metadata = TOML.parsefile(path * ".toml")
    @test metadata["provenance"] isa Dict
    @test metadata["measurements"] isa Dict
    @test metadata["measurements"]["spectrum_cursor"]["frequency"] == 0.0
    @test metadata["measurements"]["spectrum_cursor"]["classification"] == "dc"
    @test metadata["axis_limits"]["spectrum"]["x"] isa Vector
    @test AmberMakie._metadata_value((1, :two)) == Any[1, "two"]
    @test AmberMakie._metadata_value([1 2; 3 4]) == [[1, 2], [3, 4]]
    @test occursin("setcursor!", copyrecipe(handle))
    @test occursin("Makie.xlims!", copyrecipe(handle))
    close(handle)
end
