function _jacobian(f,z;h=sqrt(eps(Float64)))
    y=f(z); J=zeros(eltype(y),length(y),length(z))
    for j in eachindex(z)
        δ=h*max(1,abs(z[j])); zz=copy(z); zz[j]+=δ; J[:,j]=(f(zz)-y)/δ
    end
    J
end

struct ConvergenceError <: Exception
    context::String
    stats::Dict{Symbol,Any}
end
struct LinearSolveError <: Exception
    context::String
end
Base.showerror(io::IO,error::LinearSolveError)=print(io,error.context)
function _solve_linear(system,rhs,context)
    try
        system\rhs
    catch error
        error isa LinearAlgebra.SingularException||rethrow()
        throw(LinearSolveError(String(context)))
    end
end
Base.showerror(io::IO,error::ConvergenceError)=print(io,error.context," did not converge", haskey(error.stats,:dominant_residual) ? "; dominant residual: $(error.stats[:dominant_residual])" : "")

function _require_converged(result,context)
    get(result.stats,:converged,false)||throw(ConvergenceError(String(context),copy(result.stats)))
    result
end
function _finalize_stats!(stats;partial=false)
    stats[:status]=get(stats,:converged,false) ? :converged : :failed
    stats[:partial]=!get(stats,:converged,false)&&partial
    get!(stats,:warnings,String[]); stats
end

function _unknown_scales(cc)
    scales=ones(Float64,cc.n)
    for index in values(cc.branches); scales[index]=1e-3 end
    scales
end

function _newton(cc,z0,previous,t,α;reltol=1e-7,abstol=1e-10,maxiters=60,
        mode=:time,source_scale=1.,gmin=0.,temperature=300.,forcing=nothing)
    z=copy(z0); factorization=nothing
    for it in 1:maxiters
        r,J=residual_jacobian(cc,z,previous,t,α;mode,source_scale,gmin,temperature)
        forcing===nothing||(r.-=forcing)
        numerical_floor=32eps(Float64)*max(opnorm(J,Inf)*max(norm(z,Inf),1),1)
        norm(r,Inf)<=abstol+numerical_floor&&return z,it,true
        variable_scales=_unknown_scales(cc)
        scaled_matrix=copy(J)
        for column in 1:cc.n, pointer in nzrange(scaled_matrix,column); scaled_matrix.nzval[pointer]*=variable_scales[column] end
        row_norms=zeros(Float64,cc.n)
        for column in 1:cc.n, pointer in nzrange(scaled_matrix,column)
            row=scaled_matrix.rowval[pointer]; row_norms[row]=max(row_norms[row],abs(scaled_matrix.nzval[pointer]))
        end
        inverse_row_norms=1 ./ max.(row_norms,eps(Float64)); system=copy(scaled_matrix)
        for value_index in eachindex(system.nzval); system.nzval[value_index]*=inverse_row_norms[system.rowval[value_index]] end
        Δ=try
            rhs=inverse_row_norms.*r
            factorization=factorization===nothing ? lu(system) : lu!(factorization,system)
            variable_scales.*(-(factorization\rhs))
        catch error
            error isa LinearAlgebra.SingularException||rethrow()
            throw(LinearSolveError("Newton matrix is singular at iteration $(it)"))
        end
        all(isfinite,Δ)||return z,it,false
        damping=1.; nr=norm(r)
        while damping>1/128
            candidate=z+damping*Δ
            candidate_residual=residual(cc,candidate,α==0 ? zero(candidate) : α.*(candidate.-previous),t;mode,source_scale,gmin,temperature)
            forcing===nothing||(candidate_residual.-=forcing)
            norm(candidate_residual)<=nr&&break
            damping/=2
        end
        z+=damping*Δ
        all(isfinite,z)||return z,it,false
    end
    z,maxiters,false
end
