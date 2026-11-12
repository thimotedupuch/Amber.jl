# julia --project=. benchmark/structural_solve_plan.jl > results.toml
# End-to-end linear solves, including extraction/validation in the experimental
# executor. Neither path caches factors. Plan construction is measured separately.
using Amber, SparseArrays, LinearAlgebra, TOML
function plan_for(a)
    n=size(a,1); rows=[Int[] for _ in 1:n]
    for col in 1:n, slot in nzrange(a,col)
        iszero(a.nzval[slot]) || push!(rows[a.rowval[slot]],col)
    end
    e,u=Amber._structural_matching(rows,n)
    analysis=StructuralAnalysis(:dc,sparse(.!iszero.(a)),e,u,findall(iszero,e),findall(iszero,u),Amber._equation_blocks(rows,u))
    Amber._structural_solve_plan(analysis)
end
function sample(f,args...)
    f(args...)
    runs=[@timed f(args...) for _ in 1:20]
    return Dict("seconds"=>minimum(x.time for x in runs),"bytes"=>minimum(x.bytes for x in runs))
end
global_solve(a,b)=a\b
policy_global_solve(a,b)=Amber._new_factorization(a,SuiteSparseLU())\b
permuted_matrix(p,a)=a[p.equation_permutation,p.unknown_permutation]
function measure(n,kind)
    a=spdiagm(-1=>fill(-0.25,n-1),0=>fill(2.0,n))
    kind != "feedforward" && (a+=spdiagm(1=>fill(kind == "symmetric_coupled" ? -0.25 : -0.15,n-1)))
    build=@timed plan_for(a); plan=build.value; rhs=ones(n)
    first=@timed structural_solve(plan,a,rhs)
    @assert first.value.solution ≈ a\rhs
    return Dict("unknowns"=>n,"kind"=>kind,"blocks"=>length(plan.block_ranges),
        "plan_seconds"=>build.time,"first_solve_seconds"=>first.time,
        "first_solve_compile_seconds"=>first.compile_time,
        "structural"=>sample(structural_solve,plan,a,rhs),
        "native_global"=>sample(global_solve,a,rhs),
        "policy_global"=>sample(policy_global_solve,a,rhs),
        "validation"=>sample(Amber._structural_matrix_violation,plan,a),
        "permutation"=>sample(permuted_matrix,plan,a),
        "error_check"=>sample(Amber._structural_backward_error,a,first.value.solution,rhs),
        "backward_error"=>first.value.stats.backward_error)
end
TOML.print(stdout,Dict("julia_version"=>string(VERSION),"cpu"=>Sys.CPU_NAME,"threads"=>Threads.nthreads(),
    "cases"=>[measure(n,kind) for kind in ("feedforward","symmetric_coupled","nonsymmetric_coupled") for n in (1,16,64,128)]);sorted=true)

function bias_design(n;nonlinear=false)
    b=CircuitBuilder(:FeedforwardBias)
    g=ground!(b); previous=node!(b,:input)
    add!(b,voltage_source(previous,g;dc=0.8);name=:Supply)
    for i in 1:n
        output=node!(b,Symbol(:stage,i))
        add!(b,resistor(output,g;value=1000);name=Symbol(:Load,i))
        add!(b,transconductance(previous,g,output,g;gm=-1e-3);name=Symbol(:Gain,i))
        nonlinear && add!(b,diode(output,g);name=Symbol(:Diode,i))
        previous=output
    end
    compile(finish(b))
end
planned_bias(c,p)=operating_point(c;linear_plan=p)
function bias_measure(n,nonlinear)
    cc=bias_design(n;nonlinear); plan=structural_solve_plan(cc)
    baseline=operating_point(cc); candidate=planned_bias(cc,plan)
    @assert baseline.stats[:converged] && candidate.stats[:converged]
    @assert isapprox(candidate.values,baseline.values;rtol=1e-7,atol=1e-10)
    history=candidate.stats[:linear_solve_history]
    return Dict("stages"=>n,"nonlinear"=>nonlinear,
        "global"=>sample(operating_point,cc),"structural"=>sample(planned_bias,cc,plan),
        "global_iterations"=>baseline.stats[:iterations],
        "structural_iterations"=>candidate.stats[:iterations],
        "fallback_solves"=>count(h->h.fallback_reason !== nothing,history),
        "maximum_backward_error"=>maximum(h->h.backward_error,history))
end
TOML.print(stdout,Dict("operating_points"=>[bias_measure(16,nonlinear) for nonlinear in (false,true)]);sorted=true)
