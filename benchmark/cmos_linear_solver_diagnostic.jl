# Diagnostic only: run in a separate Julia process. This redefines a private
# Newton method in memory to isolate sparse-versus-dense factorization overhead;
# it does not change Amber's solver policy or edit its source.
using Amber,TOML,LinearAlgebra
BLAS.set_num_threads(1)
include("ngspice_cmos.jl")
function run_case(n,topology)
    d,_=cmos_design(n,"transient";topology);cc=compile(d)
    o=SolverOptions(reltol=1e-6,current_abstol=1e-12,voltage_abstol=1e-9)
    f()=transient(cc,0.0=>210e-9; adaptive=false,max_step=62.5e-12,saveat=62.5e-12,event_mode=:exact,solver=o)
    f();r=f();t=minimum([@elapsed f() for _ in 1:5])
    return r,t
end
function main()
    base=[run_case(n,topology) for (n,topology) in [(1,"bank"),(10,"chain"),(100,"bank")]]
    src=read("src/Solvers/Nonlinear.jl",String)
    a=findfirst("            if linear_plan === nothing\n",src).start
    b=findnext("            @inbounds @simd for index in eachindex(workspace.update)",src,a).start
    src=src[1:a-1]*"""
                workspace.numeric_factorizations += 1
                copyto!(workspace.update, Matrix(system) \\ rhs)
    """*src[b:end]
    start=findfirst("function _newton(",src).start
    Base.include_string(Amber,src[start:end],"dense_diagnostic_newton.jl")
    results=[]
    for (i,(n,topology)) in enumerate([(1,"bank"),(10,"chain"),(100,"bank")])
        r,t=Base.invokelatest(run_case,n,topology);b,bt=base[i]
        @assert r.axis==b.axis
        err=maximum(abs.(r.values.-b.values))
        @assert err<1e-7
        push!(results,Dict("inverters"=>n,"topology"=>topology,"sparse_seconds"=>bt,"dense_prototype_seconds"=>t,"max_difference"=>err))
    end
    TOML.print(stdout,Dict("cases"=>results);sorted=true)
end
main()
