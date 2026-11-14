using Amber, Test, LinearAlgebra
@subcircuit CachedRC(input,output,reference;R=1.0,C=1.0) begin
    R1=resistor(input,output;value=R)
    C1=capacitor(output,reference;value=C)
end
function cached_ladder(n=20;resistance=1.0,supply=1.0)
    b=CircuitBuilder(:CachedLadder); g=ground!(b); nodes=node_array!(b,:x,0:n)
    add!(b,voltage_source(nodes[0],g;dc=supply);name=:Supply)
    instances!(b,CachedRC,1:n;name=i->(:stage,i),
        connections=i->(input=nodes[i-1],output=nodes[i],reference=g),
        parameters=i->(R=resistance,C=1.0))
    finish(b)
end
@testset "template symbolic cache values and ownership" begin
    cache=SymbolicCompilationCache(); design=cached_ladder()
    cc=compile(design;symbolic_cache=cache)
    @test symbolic_cache_stats(cache).builds == 2 # root and cell, not per instance
    @test symbolic_cache_stats(cache).entries == 2
    again=compile(design;symbolic_cache=cache)
    @test symbolic_cache_stats(cache).hits == 2
    @test again.topology.pattern.colptr == cc.topology.pattern.colptr
    @test again.topology.pattern.rowval == cc.topology.pattern.rowval
    @test again.parameters.batches[1].jacobian_slots !== cc.parameters.batches[1].jacobian_slots
    changed=cached_ladder(;resistance=2.0,supply=3.0)
    updated=compile(changed;symbolic_cache=cache); reference=compile(changed)
    @test symbolic_cache_stats(cache).builds == 2
    @test symbolic_cache_stats(cache).hits == 4
    x=collect(range(0.0,1.0;length=cc.n)); ws=SimulationWorkspace(updated); wr=SimulationWorkspace(reference)
    r,j=residual_jacobian!(ws,updated,x,x,0.0,1.0)
    rr,jr=residual_jacobian!(wr,reference,x,x,0.0,1.0)
    @test r == rr
    @test j == jr
    @test voltage(operating_point(updated),"x[20]")[1] ≈ 3.0V
    @test compile(updated;symbolic_cache=cache) === updated
    empty!(cache)
    @test symbolic_cache_stats(cache).entries == 0
    @test voltage(operating_point(cc),"x[20]")[1] ≈ 1.0V
end
@testset "bounded cache and simultaneous compilation" begin
    @test_throws ArgumentError SymbolicCompilationCache(max_entries=0)
    tiny=SymbolicCompilationCache(max_entries=1)
    compile(cached_ladder(3);symbolic_cache=tiny)
    @test symbolic_cache_stats(tiny).entries <= 1
    @test symbolic_cache_stats(tiny).evictions > 0
    cache=SymbolicCompilationCache(); design=cached_ladder(3)
    tasks=[Threads.@spawn compile(design;symbolic_cache=cache) for _ in 1:2]
    a,b=fetch.(tasks)
    @test a.topology.pattern.rowval == b.topology.pattern.rowval
    @test symbolic_cache_stats(cache).builds == 2
    @test symbolic_cache_stats(cache).hits == 2
end
