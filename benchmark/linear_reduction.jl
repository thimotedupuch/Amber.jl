# julia --project=. benchmark/linear_reduction.jl > measurements.toml
using Amber, SparseArrays, LinearAlgebra, TOML
function sample(f,args...)
    f(args...)
    runs=[@timed f(args...) for _ in 1:20]
    Dict("seconds"=>minimum(x.time for x in runs),"bytes"=>minimum(x.bytes for x in runs))
end
native_solve(a,b)=a\b
function matrix_case(n,kind)
    matrix=spdiagm(-1=>fill(-0.3,n-1),0=>fill(2.0,n))
    kind == "cycle" && (matrix[1,n]=-0.3)
    plan=reduce_linear_system(matrix); rhs=ones(n)
    result=solve_reduced(plan,rhs)
    @assert result.stats.converged && isapprox(result.solution,matrix\rhs)
    Dict("unknowns"=>n,"kind"=>kind,"retained"=>length(plan.unknowns),
        "eliminated"=>length(plan.eliminations),"introduced_entries"=>plan.introduced_entries,
        "construction"=>sample(reduce_linear_system,matrix),
        "native_solve"=>sample(native_solve,matrix,rhs),
        "reused_reduction"=>sample(solve_reduced,plan,rhs),
        "componentwise_error"=>result.stats.componentwise_error)
end
function divider(n)
    b=CircuitBuilder(:ReductionBench)
    g=ground!(b); previous=node!(b,:input)
    add!(b,voltage_source(previous,g;dc=1.0);name=:Supply)
    for i in 1:n
        next=node!(b,Symbol(:node,i))
        add!(b,resistor(previous,next;value=1000);name=Symbol(:Series,i))
        add!(b,resistor(next,g;value=1000);name=Symbol(:Shunt,i))
        previous=next
    end
    compile(finish(b))
end
unreduced_bias(cc)=reduced_operating_point(cc;max_eliminations=0)
function bias_case(n)
    cc=divider(n); original=operating_point(cc); reduced=reduced_operating_point(cc)
    @assert reduced.stats[:converged] && isapprox(reduced.values,original.values;rtol=1e-7,atol=1e-12)
    Dict("sections"=>n,"unknowns"=>cc.n,
        "eliminated"=>reduced.stats[:reduction].eliminated,
        "native_operating_point"=>sample(operating_point,cc),
        "direct_unreduced_operating_point"=>sample(unreduced_bias,cc),
        "reduced_operating_point"=>sample(reduced_operating_point,cc))
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,
    "threads"=>Threads.nthreads(),"samples"=>20,
    "matrices"=>[matrix_case(n,kind) for kind in ("feedforward","cycle") for n in (16,64,128)],
    "operating_points"=>[bias_case(8),bias_case(16)]);sorted=true)
