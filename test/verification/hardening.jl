using LinearAlgebra, SparseArrays

@testset "Monte Carlo status and replay contracts" begin
    metric=r->voltage(r,:vout)[1]
    variations=Dict(Symbol("R1.value")=>Gaussian(20kΩ,100Ω))
    serial=monte_carlo(LowPass();samples=257,seed=23,variations,metric)
    parallel=monte_carlo(LowPass();samples=257,seed=23,variations,metric,parallel=true)
    @test all(parallel.converged)
    @test serial.parameters==parallel.parameters
    @test serial.values==parallel.values
    callback_failure=monte_carlo(LowPass();samples=2,metric,on_sample=(args...)->error("callback failure"))
    @test failure_rate(callback_failure)==1
    @test length(callback_failure.failures)==2
    @test all(isnothing,callback_failure.values)
    discarded=monte_carlo(LowPass();samples=1,variations,metric,store_parameters=false)
    @test_throws ArgumentError replay_sample(discarded,LowPass(),1;metric)
    @test_throws ArgumentError replay_sample(deserialize_monte_carlo(serialize_monte_carlo(discarded)),LowPass(),1;metric)
    # Legacy snapshots did not record whether empty draws had been discarded.
    delete!(discarded.metadata,:parameters_stored)
    @test_throws ArgumentError replay_sample(discarded,LowPass(),1;metric)
    @test_throws ArgumentError replay_sample(serial,with_parameters(compile(LowPass()),"R1.value"=>5kΩ),1;metric)
    protected=monte_carlo(LowPass();samples=1,variations,metric,on_sample=(_,_,draws)->empty!(draws))
    @test !isempty(protected.parameters[1])
end

@testset "simultaneous initial voltage constraints" begin
    @circuit InitialNetwork(;reverse=false,conflict=false) begin
        gnd=ground(); a=node(); b=node()
        RA=resistor(a,gnd;value=1kΩ); RB=resistor(b,gnd;value=1kΩ)
        if reverse
            C2=capacitor(b,gnd;value=1μF); initial_voltage(C2,2V)
            C1=capacitor(a,b;value=1μF); initial_voltage(C1,1V)
        else
            C1=capacitor(a,b;value=1μF); initial_voltage(C1,1V)
            C2=capacitor(b,gnd;value=1μF); initial_voltage(C2,2V)
        end
        if conflict
            C3=capacitor(a,gnd;value=1μF); initial_voltage(C3,4V)
        end
    end
    for reverse in (false,true)
        result=transient(InitialNetwork(reverse=reverse),0.0 => 1e-6;saveat=1e-6)
        @test voltage(result,:a)[1]≈3
        @test voltage(result,:b)[1]≈2
    end
    @test_throws AnalysisValidationError transient(InitialNetwork(conflict=true),0.0 => 1e-6;saveat=1e-6)
    @test_throws AnalysisValidationError transient(LowPass(),0.0 => 1e-3;initial=:typo)
end

@testset "inductor integration error and failure policy" begin
    @circuit InductorIntegration() begin
        gnd=ground(); input=node()
        V1=voltage_source(input,gnd;waveform=Sine(frequency=1/(2π)))
        L1=inductor(input,gnd;value=1.,winding_resistance=1e-6)
    end
    loose=IntegrationOptions(reltol=1e-2,current_abstol=1e-4)
    tight=IntegrationOptions(reltol=1e-5,current_abstol=1e-8)
    first_run=transient(InductorIntegration(),0.0 => 1.;initial=:discharged,adaptive=true,max_step=.2,integration=loose)
    refined=transient(InductorIntegration(),0.0 => 1.;initial=:discharged,adaptive=true,max_step=.2,integration=tight)
    exact=(1e-6*sin(1.)-cos(1.)+exp(-1e-6))/(1+1e-12)
    @test first_run.stats[:converged]&&refined.stats[:converged]
    @test abs(current(refined,:L1)[end]-exact)<abs(current(first_run,:L1)[end]-exact)
    @test current(refined,:L1)[end]≈exact rtol=2e-3
    limit=IntegrationOptions(max_steps=1)
    partial=transient(LowPass(),0.0 => 1e-3;integration=limit)
    @test partial.stats[:partial]&&!partial.stats[:converged]
    @test last(partial.axis)<1e-3
    @test_throws ConvergenceError transient(LowPass(),0.0 => 1e-3;integration=limit,failure_policy=:throw)
end

@testset "internal switch crossing and coupled charge injection" begin
    @circuit CoupledInjection() begin
        gnd=ground(); control=node(); held=node(); other=node()
        I1=current_source(control,gnd;dc=1.)
        RC=resistor(control,gnd;value=1e12)
        CC=capacitor(control,gnd;value=1.); initial_voltage(CC,1.)
        S1=analog_switch(gnd,held,control,gnd;model=EventSwitch(threshold=.5,ron=1e12,roff=1e12,charge_injection=1e-3))
        C1=capacitor(held,other;value=1e-3)
        C2=capacitor(other,gnd;value=1e-3)
        R1=resistor(held,gnd;value=1e12); R2=resistor(other,gnd;value=1e12)
    end
    result=transient(CoupledInjection(),0.0 => 1.;initial=:discharged,max_step=.2,event_mode=:exact)
    @test result.stats[:converged]
    @test length(result.stats[:event_times])==1
    @test only(result.stats[:event_times])≈.5 atol=1e-8
    @test voltage(result,:held)[end]≈2. rtol=1e-6
    @test voltage(result,:other)[end]≈1. rtol=1e-6
    crossing=findfirst(t->isapprox(t,.5;atol=1e-8),result.axis)
    @test result.stats[:bdf_orders][crossing]==1
    @test result.stats[:bdf_orders][crossing+1]==1
end

@testset "unsupported physical effects fail explicitly" begin
    @test_throws ArgumentError GummelPoonBJT(transit_time=1ns)
    @test_throws ArgumentError with_model_parameter(GummelPoonBJT(),:transit_time,1ns)
    @test_throws ArgumentError ThinFilm(tc1=1e-5)
    @test_throws ArgumentError ThinFilm(temperature_coefficient=1e-5)
    @test_throws ArgumentError ThinFilm(voltage_coefficient=1e-5)
    @test_throws ArgumentError C0G(loss_tangent=1e-4)
    @test_throws ArgumentError BehavioralOpAmp(slew_rate=1e6)
    @test_throws ArgumentError BehavioralOpAmp(output_current_limit=.01)
    @test_throws ArgumentError BehavioralOpAmp(saturation_recovery=1e-6)
end

@testset "analysis serialization retains effective configuration" begin
    solver=SolverOptions(reltol=2e-6,voltage_abstol=3e-8,current_abstol=4e-11,
        state_abstol=5e-9,max_newton_iterations=71,continuation_maxdepth=7,
        line_search_minimum=1/128,linear_solver=SuiteSparseLU(ordering=:natural,pivot_tolerance=.2))
    for analysis in (OperatingPoint(;temperature=315.,solver),
            SmallSignal([100.,200.];source=:V1,solver),
            TransientNoise(;interval=0.0=>1e-3,timestep=1e-5,saveat=1e-5,seed=UInt64(2),
                low_frequency_cutoff=1e3,initial=:discharged,solver),
            PeriodicSteadyState(;period=1e-3,saveat=1e-5,initial=:discharged,solver),
            Transient(0.0 => 1e-4;saveat=1e-5,initial=:discharged,event_mode=:exact,solver,
                integration=IntegrationOptions(reltol=2e-4),failure_policy=:throw))
        restored=Amber._decode_analysis(Amber._encode_analysis(analysis))
        @test Amber._encode_analysis(restored)==Amber._encode_analysis(analysis)
    end
    direct=transient(LowPass(),0.0 => 1e-4;saveat=1e-5,initial=:discharged,event_mode=:exact,
        reltol=2e-6,abstol=3e-9,maxiters=71,
        overrides=Dict(Symbol("R1.value")=>20kΩ))
    repeated=simulate(LowPass(),direct.analysis)
    @test direct.values==repeated.values
    @test direct.analysis.solver.max_newton_iterations==71
    @test direct.analysis.solver.current_abstol==3e-9
    mc=monte_carlo(LowPass();samples=1,analysis=direct.analysis,metric=r->voltage(r,:vout)[end])
    restored=deserialize_monte_carlo(serialize_monte_carlo(mc))
    @test replay_sample(restored,LowPass(),1;metric=r->voltage(r,:vout)[end])==mc.values[1]
end

@testset "sparse periodic assembly matches dense Fourier reference" begin
    gs=[spdiagm(0=>[2.0 + .2cos(t),3.]) for t in range(0,2π;length=9)[1:end-1]]
    cs=[spdiagm(0=>[1.,2.0 + .1sin(t)]) for t in range(0,2π;length=9)[1:end-1]]
    bands=-2:2; coefficients=Amber._periodic_coefficients(gs,cs,bands)
    for offset in (.1,.3)
        result=Amber._lifted_periodic_system(coefficients,bands,offset,1.)
        reference=zeros(ComplexF64,10,10)
        for (i,row) in enumerate(bands),(j,column) in enumerate(bands)
            q=row-column
            g=sum(Matrix(gs[k])*cis(-2π*q*(k-1)/8) for k in 1:8)/8
            c=sum(Matrix(cs[k])*cis(-2π*q*(k-1)/8) for k in 1:8)/8
            reference[2i-1:2i,2j-1:2j]=g+im*2π*(offset+row)*c
        end
        @test result isa SparseMatrixCSC
        @test Matrix(result)≈reference
        @test nnz(result)<=50
    end
end

@testset "adaptive output grid and ideal-source impulses" begin
    @circuit DrivenCapacitor() begin
        gnd=ground(); x=node()
        V1=voltage_source(x,gnd;waveform=Step(at=.5))
        C1=capacitor(x,gnd;value=1e-6)
    end
    result=transient(DrivenCapacitor(),0.0=>1.;initial=:discharged,
        adaptive=true,saveat=.1,event_mode=:exact)
    @test result.stats[:converged]
    @test result.axis==collect(0.:.1:1.)
    @test voltage(result,:x)[end]≈1.
    @test !haskey(result.stats,:bdf_orders)
end

@testset "adaptive saved charge derivatives" begin
    @circuit SineCapacitor() begin
        gnd=ground(); x=node()
        V1=voltage_source(x,gnd;waveform=Sine(frequency=1.))
        C1=capacitor(x,gnd;value=1e-6)
    end
    result=transient(SineCapacitor(),0.0=>1.;initial=:discharged,
        adaptive=true,saveat=.01,max_step=.001)
    @test result.stats[:converged]
    expected=2π*1e-6*cos.(2π.*result.axis)
    @test maximum(abs.(current(result,:C1).-expected))<1e-8
end
