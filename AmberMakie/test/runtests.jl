using Test
using Amber
using AmberMakie
import Makie
using CairoMakie
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
end

@testset "statistical adapters and plots" begin
    sweep = Amber.SweepResult("R.value", Any[1.0, 2.0, 3.0], Any[2.0, nothing, 6.0],
        Any[nothing, nothing, nothing], BitVector([true, false, true]),
        [Amber.SweepFailure(2, 2.0, :ErrorException, "failed")], Amber.OperatingPoint(), Dict{Symbol,Any}())
    view = ensembleview(sweep)
    @test view.converged == [true, false, true]
    @test hasproperty(sweepplot(Makie.Figure()[1, 1], sweep).axes, :sweep)
    monte = Amber.MonteCarloResult(Amber.OperatingPoint(), Union{Nothing,Float64}[1.0, 2.0, nothing],
        [Dict(:resistance => 1.0), Dict(:resistance => 2.0), Dict{Symbol,Float64}()], UInt64[1, 2, 3], BitVector([true, true, false]),
        Amber.MonteCarloFailure[], Dict{Symbol,Any}())
    @test length(ensembleplot(Makie.Figure()[1, 1], monte).view.metrics) == 3
    @test correlationplot(Makie.Figure()[1, 1], monte; parameter=:resistance).view.metric == [1.0, 2.0]
end

@testset "network and control integration" begin
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
    @test hasproperty(stabilitycircleplot(Makie.Figure()[1, 1], result).axes, :stability)
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
end

@testset "workbench ownership" begin
    result = SpectrumResult([0.0, 1.0, 2.0], ComplexF64[0, 1, 0], [0.0, 0.5, 0.0],
        [0.0, 0.25, 0.0], 4.0, :hann, 0.5, 1.0,
        Dict{Symbol,Any}(:warnings => ["inspect sampling"]),)
    handle = workbench(result)
    @test handle.warnings == ["inspect sampling"]
    @test !isempty(handle.cursors.subscriptions)
    setcursor!(handle.cursors, :a, 0.8)
    @test handle.measurements[:cursors][].a.x == 1.0
    close(handle)
    @test handle.closed
    @test isempty(handle.cursors.subscriptions)
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
    close(handle)
end
