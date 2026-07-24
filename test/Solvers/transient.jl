@testset "transient" begin
    result=transient(LowPass(),0s=>1ms;saveat=10μs)
    @test result.stats[:converged]; @test voltage(result,:vout)[end]>.9V
    first_order=transient(LowPass(),0s=>200μs;saveat=10μs,method=:bdf1)
    @test first_order.analysis.method==:bdf1
    @circuit InitializedCapacitor() begin
        gnd=ground(); output=node(); R1=resistor(output,gnd;value=1kΩ)
        C1=capacitor(output,gnd;value=1μF); initial_voltage(C1,2V)
    end
    initialized=transient(InitializedCapacitor(),0s=>100μs;saveat=10μs)
    @test voltage(initialized,:output)[1]≈2V
    @test voltage(initialized,:output)[end]<2V
    compiled=compile(LowPass())
    overridden=simulate(compiled,Transient(0s=>200μs;saveat=10μs,overrides=Dict(Symbol("V1.waveform")=>Step(low=0V,high=2V,at=0s))))
    @test voltage(overridden,:vout)[end]>1V
    original=transient(compiled,0s=>200μs;saveat=10μs)
    @test voltage(original,:vin)[end]≈1V
    pulse_circuit=Circuit(:PulseEvents); pulse_ground=ground!(pulse_circuit,:gnd); pulse_node=node!(pulse_circuit,:clock)
    add!(pulse_circuit,voltage_source(pulse_node,pulse_ground;waveform=Pulse(frequency=100kHz,rise=2ns,fall=2ns,duty_cycle=.15));name=:Clock)
    event_result=transient(pulse_circuit,0s=>3μs;max_step=50ns,event_mode=:exact)
    @test any(==(2ns),event_result.axis)
    @test any(==(1.5μs),event_result.axis)
    sampler_module=Module(:SwitchEventSampler)
    Base.include(sampler_module,normpath(joinpath(@__DIR__,"..","..","examples","06_sample_and_hold","circuit.jl")))
    sampler_result=transient(getfield(sampler_module,:SampleAndHold)(),0s=>3μs;max_step=50ns,event_mode=:exact)
    @test sampler_result.stats[:converged]
    @test all(isfinite,voltage(sampler_result,:hold))
    adaptive_result=transient(LowPass(),0s=>1ms;adaptive=true,reltol=1e-4,abstol=1e-8,event_mode=:exact)
    @test adaptive_result.stats[:converged]

    # The analysis object preserves the same automatic policy as the direct
    # API: an explicit output/maximum step selects the deterministic grid,
    # while an unconstrained transient selects adaptive stepping.
    fixed_from_analysis=simulate(LowPass(),Transient(0s=>100μs;max_step=10μs))
    automatic_from_analysis=simulate(LowPass(),Transient(0s=>100μs))
    @test fixed_from_analysis.analysis.adaptive === false
    @test automatic_from_analysis.analysis.adaptive === true
    @test adaptive_result.stats[:rejected_steps]>=0
    @test length(unique(round.(diff(adaptive_result.axis);sigdigits=6)))>1
    @test voltage(adaptive_result,:vout)[end]>.9V
end
