using Test, Amber
# Standalone runner until included by the package/test entrypoints.
isdefined(Amber, :TemperaturePolicy) || Base.include(Amber, joinpath(@__DIR__, "../../src/Devices/Temperature.jl"))
isdefined(Amber, :CompactModelCallback) || Base.include(Amber, joinpath(@__DIR__, "../../src/Devices/CompactModels.jl"))
@testset "temperature resolution and compact callback contracts" begin
    @test Amber.device_temperature(Amber.TemperaturePolicy(ambient=290, offset=20)) == 310
    @test Amber.device_temperature(Amber.TemperaturePolicy(ambient=290, offset=20, instance=330)) == 330
    @test_throws ArgumentError Amber.TemperaturePolicy(offset=-400)
    model = Amber.CompactModelCallback(2, (v,t) -> begin
        g=1e-3; c=1e-9; d=v[1]-v[2]
        (; currents=[g*d,-g*d], charges=[c*d,-c*d], conductance=[g -g; -g g], capacitance=[c -c; -c c])
    end)
    @test Amber.compact_model_point(model,[1,0]).currents ≈ [1e-3,-1e-3]
    @test_throws DimensionMismatch Amber.compact_model_point(model,[1,0,0])
    bad=Amber.CompactModelCallback(2,(v,t)->(;currents=[1.,0.],charges=zeros(2),conductance=zeros(2,2),capacitance=zeros(2,2)))
    @test_throws ArgumentError Amber.compact_model_point(bad,[1,0])
end
@testset "amplifier current limiting" begin
    @circuit LimitedFollower() begin
        g=ground(); i=node(); o=node(); vp=node(); vn=node()
        voltage_source(i,g;dc=1V)
        voltage_source(vp,g;dc=5V)
        voltage_source(vn,g;dc=-5V)
        opamp(i,o,o,vp,vn;model=BehavioralOpAmp(output_current_limit=1mA))
        resistor(o,g;value=100Ω)
    end
    result=operating_point(LimitedFollower())
    @test only(voltage(result,:o)) ≈ 0.1V rtol=1e-5
    @test_throws ArgumentError BehavioralOpAmp(slew_rate=0.0)
    @test_throws ArgumentError BehavioralOpAmp(output_current_limit=-1.0)
end
@testset "amplifier slew bound" begin
    @circuit SlewFollower() begin
        g=ground(); i=node(); o=node(); vp=node(); vn=node()
        voltage_source(i,g;waveform=Step(low=0V,high=1V,at=1μs,rise=0.1μs))
        voltage_source(vp,g;dc=5V); voltage_source(vn,g;dc=-5V)
        opamp(i,o,o,vp,vn;model=BehavioralOpAmp(slew_rate=1e4))
        resistor(o,g;value=1MΩ)
    end
    r=transient(SlewFollower(),0s=>20μs;max_step=0.1μs,method=:bdf1)
    v=ustrip.(voltage(r,:o)); dt=diff(r.axis)
    @test maximum(abs.(diff(v)./dt)) <= 1e4*(1+1e-5)
    @test last(v) > 0.1
end
@testset "ideal output compatibility" begin
    @test BehavioralOpAmp(output_resistance=0Ω).output_resistance == 0
    @test_throws ArgumentError BehavioralOpAmp(output_resistance=0Ω,output_current_limit=1mA)
end
