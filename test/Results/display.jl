@testset "interactive result display" begin
    plain(r)=sprint(show,MIME"text/plain"(),r;context=:limit=>true)
    @test occursin("3 devices",plain(LowPass()))
    @test occursin("check(circuit)",plain(LowPass()))
    @test occursin("unknowns",plain(compile(LowPass())))
    @test length(plain(compile(LowPass())))<500
    op=operating_point(LowPass())
    before=deepcopy(op.stats)
    shown=plain(op)
    @test occursin("solver converged",shown)
    @test occursin("vout = 0.0 V",shown)
    @test !occursin("CompiledCircuit",shown)
    @test !occursin("residual_history",shown)
    @test length(shown)<1000
    @test op.stats==before
    @test !occursin('\n',sprint(show,op))
    @test length(sprint(show,[op]))<1000

    partial=transient(LowPass(),0s=>1ms;max_step=1μs,saveat=10μs,
        integration=IntegrationOptions(max_steps=1))
    shown=plain(partial)
    @test occursin("PARTIAL",shown)
    @test occursin("Requested stop: 0.001 s",shown)
    @test occursin("max_steps",shown)
    @test occursin("explain_failure(result)",shown)
    explanation=explain_failure(partial)
    @test occursin("only accepted steps",explanation)
    @test occursin("Saved data ends",explanation)
    @test occursin("IntegrationOptions(max_steps=...)",explanation)
    @test !occursin("accepted step(s) contain unresolved",explanation)

    ac=small_signal(LowPass(),10Hz=>1MHz;points=5)
    @test occursin("Hz",plain(ac))
    observable_error=try
        transfer(ac;input=:vin,output=voltage(:vout))
    catch error
        error
    end
    @test observable_error isa ArgumentError
    @test occursin("voltage(:out)",sprint(showerror,observable_error))
    n=noise(LowPass(),10Hz=>1kHz;output=voltage(:vout),points=3)
    @test occursin("integrated_noise",plain(n))
    @test occursin("solver converged",plain(n))
    @test length(plain(n))<1000

    study=sweep(LowPass(),"R1.value"=>[1kΩ,2kΩ];metric=r->error("measurement unavailable"))
    @test occursin("0 successful, 2 failed",plain(study))
    @test occursin("measurement unavailable",plain(study))
    @test occursin("result.failures",plain(study))
    mc=monte_carlo(LowPass();samples=2,seed=42,metric=r->0.0)
    @test occursin("2 successful, 0 failed",plain(mc))
    @test !occursin("First failure",plain(mc))

    err=ConvergenceError("sweep point 1 did not converge",Dict{Symbol,Any}(:warnings=>["check bias"]))
    message=sprint(showerror,err)
    @test length(findall("did not converge",message))==1
    @test occursin("check bias",message)
    @test occursin("error.stats",message)

    # Long records/warning lists must not flood a notebook cell.
    warned_stats=copy(op.stats)
    warned_stats[:warnings]=["warning $i" for i in 1:20]
    warned=SimulationResult(op.compiled,op.analysis,op.axis,op.values,warned_stats)
    @test occursin("17 more warning(s)",plain(warned))
    @test !occursin("warning 20",plain(warned))
end
