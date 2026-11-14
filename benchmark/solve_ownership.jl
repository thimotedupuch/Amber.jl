using Amber, TOML, Statistics
function ownership_fixture(count)
    b=CircuitBuilder(:Ownership);g=ground!(b)
    for i in 1:count
        n=node!(b,Symbol(:n,i))
        add!(b,current_source(n,g;dc=0.001);name=Symbol(:I,i))
        add!(b,resistor(n,g;value=1000.0);name=Symbol(:R,i))
    end
    compile(finish(b))
end
function sample(f;n=21)
    f();f(); times=Float64[];bytes=Int[]
    for _ in 1:n
        stat=@timed f();push!(times,stat.time);push!(bytes,stat.bytes)
    end
    Dict("median_seconds"=>median(times),"median_bytes"=>median(bytes))
end
cc=ownership_fixture(512);plan=compiled_solve_plan(cc)
ws=SimulationWorkspace(plan);x=zeros(cc.n)
ap=parallel_assembly_plan(cc;chunk_size=32)
results=Dict("julia_version"=>string(VERSION),"threads"=>Threads.nthreads(),
    "unknowns"=>cc.n,
    "workspace_default"=>sample(()->SimulationWorkspace(cc)),
    "workspace_shared_plan"=>sample(()->SimulationWorkspace(plan)),
    "assembly_serial"=>sample(()->residual_jacobian!(ws,cc,x,x,0.,0.)),
    "assembly_scheduled_serial"=>sample(()->parallel_residual_jacobian!(ws,cc,ap,x,x,0.,0.;threaded=false)),
    "assembly_threaded"=>sample(()->parallel_residual_jacobian!(ws,cc,ap,x,x,0.,0.)))
TOML.print(stdout,results)
