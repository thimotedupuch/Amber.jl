@testset "explicit transient numerical controls" begin
    @circuit ControlDecay() begin
        gnd=ground(); out=node()
        R=resistor(out,gnd;value=1.0); C=capacitor(out,gnd;value=1.0)
    end
    c=ControlDecay()
    for controls in ((;),(;saveat=0.2),(;max_step=0.2),(;max_step=0.2,saveat=0.2))
        r=transient(c,0.0=>1.0;initial=[1.0],controls...)
        @test r.analysis.adaptive
        @test r.stats[:local_error_control]
        @test r.stats[:stepping_mode]===:adaptive
        @test maximum(r.stats[:error_estimates])<=1
        @test abs(r.values[1,end]-exp(-1))<1e-3
        @test simulate(c,r.analysis).values==r.values
    end
    sampled=transient(c,0.0=>1.0;initial=[1.0],saveat=0.1,max_step=0.5)
    @test sampled.axis ≈ collect(0.0:0.1:1.0)
    @test sampled.stats[:maximum_step]==0.5
    @test sampled.stats[:sampling_policy]===:integration_boundaries
    @test sampled.analysis.event_mode===:exact
    @test sampled.analysis.failure_policy===:throw

    fixed=transient(c,0.0=>1.0;initial=[1.0],adaptive=false,max_step=0.1)
    @test !fixed.stats[:local_error_control]
    @test fixed.stats[:stepping_mode]===:fixed
    @test fixed.stats[:integration_tolerances]===nothing
    @test length(fixed.stats[:accepted_step_sizes])==10
    @test fixed.stats[:error_estimates]===nothing
    for kwargs in ((;adaptive=nothing),(;adaptive=1),(;adaptive=false),
            (;adaptive=false,saveat=0.1),
            (;adaptive=false,max_step=0.1,integration=IntegrationOptions(reltol=1e-6)),
            (;adaptive=false,max_step=0.1,integration=IntegrationOptions(min_step=0.01)),
            (;reltol=1e-6),(;abstol=1e-9),(;maxiters=100))
        @test_throws AnalysisValidationError transient(c,0.0=>1.0;kwargs...)
    end
    @test_throws AnalysisValidationError Transient(0.0=>1.0;adaptive=nothing)
    @test_throws AnalysisValidationError Transient(0.0=>1.0;adaptive=false,saveat=0.1)
    @test_throws AnalysisValidationError Transient(0.0=>1.0;failure_policy=:typo)

    loose=transient(c,0.0=>1.0;initial=[1.0],integration=IntegrationOptions(reltol=1e-2))
    tight=transient(c,0.0=>1.0;initial=[1.0],integration=IntegrationOptions(reltol=1e-5))
    @test length(tight.stats[:accepted_step_sizes])>length(loose.stats[:accepted_step_sizes])
    @test abs(tight.values[1,end]-exp(-1))<abs(loose.values[1,end]-exp(-1))
    @test tight.stats[:nonlinear_tolerances].reltol==SolverOptions().reltol
    @test tight.stats[:integration_tolerances].reltol==1e-5

    @test_throws AnalysisValidationError transient(c,0.0=>1.0;max_step=0.1,
        integration=IntegrationOptions(min_step=0.2))
    @test_throws AnalysisValidationError Transient(0.0=>1.0;
        integration=IntegrationOptions(min_step=0.2))
    bounded=transient(c,0.0=>1.0;initial=[1.0],max_step=0.2,
        integration=IntegrationOptions(reltol=1e-2,min_step=0.05))
    @test first(bounded.stats[:accepted_step_sizes])==0.05

    limit=IntegrationOptions(max_steps=1)
    @test_throws ConvergenceError transient(c,0.0=>1.0;initial=[1.0],integration=limit)
    partial=transient(c,0.0=>1.0;initial=[1.0],integration=limit,failure_policy=:return_partial)
    @test partial.stats[:partial] && !partial.stats[:converged]
    @test last(partial.axis)<1.0

    for analysis in (sampled.analysis,fixed.analysis)
        encoded=Amber._encode_analysis(analysis)
        restored=Amber._decode_analysis(encoded)
        @test Amber._encode_analysis(restored)==encoded
        @test simulate(c,restored).values==simulate(c,analysis).values
    end
    # PSS explicitly owns its prescribed integration mesh; sampling the orbit
    # more frequently than max_step must preserve the historical shooting grid.
    cycle=Amber._pss_cycle(compile(c),0.0,1.0,[1.0];saveat=0.1,max_step=0.5,
        method=:bdf2,event_mode=nothing,temperature=300.0)
    @test !cycle.analysis.adaptive
    @test cycle.stats[:maximum_step]==0.1
    @test length(cycle.stats[:accepted_step_sizes])==10
    legacy=Amber._encode_analysis(Transient(0.0=>1.0;saveat=0.2))
    legacy["adaptive"]=Amber._encode_value(nothing)
    delete!(legacy,"failure_policy")
    restored=Amber._decode_analysis(legacy)
    @test !restored.adaptive
    @test restored.max_step==0.2
    @test restored.failure_policy===:return_partial
    @test Transient(0.0=>1.0;saveat=0.2).adaptive
end
