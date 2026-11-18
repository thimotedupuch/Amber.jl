using Amber, Test
@testset "ordered conflict-aware assembly" begin
    b=CircuitBuilder(:Parallel);g=ground!(b)
    for i in 1:32
        n=node!(b,Symbol(:n,i))
        add!(b,current_source(n,g;dc=0.001);name=Symbol(:I,i))
        for j in 1:4
            add!(b,resistor(n,g;value=1000.0+j);name=Symbol(:R,i,:_,j))
        end
        add!(b,capacitor(n,g;value=1e-6);name=Symbol(:C,i))
    end
    cc=compile(finish(b));plan=parallel_assembly_plan(cc;chunk_size=1)
    @test any(length(w)>1 for w in plan.waves)
    ws=SimulationWorkspace(cc);x=collect(range(-1.,1.;length=cc.n));old=x./2
    for alpha in (0.,1e3), threaded in (false,true), gmin in (0.,1e-9)
        residual_jacobian!(ws,cc,x,old,0.1,alpha;gmin)
        r=copy(ws.residual);j=copy(ws.jacobian)
        parallel_residual_jacobian!(ws,cc,plan,x,old,0.1,alpha;gmin,threaded)
        @test isequal(r,ws.residual)
        @test isequal(j,ws.jacobian)
    end
    @test_throws ArgumentError parallel_assembly_plan(cc;chunk_size=0)
    @test_throws ArgumentError parallel_residual_jacobian!(ws,cc,plan,ws.residual,old,0.,0.)
end
@testset "callback barriers preserve serial invocation and cancellation" begin
    calls=Int[]
    b=CircuitBuilder(:Barriers);g=ground!(b);n=node!(b,:n)
    for (i,current) in enumerate((1e16,1.0,-1e16))
        add!(b,behavioral_current_source((),n,g;
            current=(v,t)->(push!(calls,i);current),gradient=(v,t)->(0.,0.,0.,0.));name=Symbol(:B,i))
    end
    add!(b,resistor(n,g;value=1.0);name=:R)
    cc=compile(finish(b));plan=parallel_assembly_plan(cc;chunk_size=1)
    ws=SimulationWorkspace(cc);x=zeros(cc.n)
    residual_jacobian!(ws,cc,x,x,0.,0.); expected=copy(calls);r=copy(ws.residual)
    empty!(calls)
    parallel_residual_jacobian!(ws,cc,plan,x,x,0.,0.)
    @test calls==expected
    @test isequal(ws.residual,r)
    updated=with_parameters(cc,"R.value"=>2.0)
    @test parallel_residual_jacobian!(ws,updated,plan,x,x,0.,0.)[1]==r
end
