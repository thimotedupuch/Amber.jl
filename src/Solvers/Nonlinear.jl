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

function _solver_residual(cc,workspace,state,derivative,t;mode=:time,source_scale=1.,gmin=0.,temperature=300.)
    workspace === nothing ? residual(cc,state,derivative,t;mode,source_scale,gmin,temperature) :
        residual!(workspace,cc,state,derivative,t;mode,source_scale,gmin,temperature)
end
function _finalize_stats!(stats;partial=false)
    stats[:status]=get(stats,:converged,false) ? :converged : :failed
    stats[:partial]=!get(stats,:converged,false)&&partial
    get!(stats,:warnings,String[]); stats
end

function _update_converged(cc,z,delta,reltol,current_abstol,voltage_abstol,state_abstol)
    for index in eachindex(z)
        kind = cc.topology.layout.kinds[index]
        absolute = kind === BranchCurrentUnknown ? current_abstol :
            kind === DeviceStateUnknown ? state_abstol : voltage_abstol
        abs(delta[index])<=absolute+reltol*max(abs(z[index]),abs(z[index]+delta[index]),1.)||return false
    end
    true
end

function _new_factorization(system, solver::SuiteSparseLU)
    control = SparseArrays.UMFPACK.get_umfpack_control(Float64, Int)
    control[SparseArrays.UMFPACK.JL_UMFPACK_PIVOT_TOLERANCE] = solver.pivot_tolerance
    if solver.ordering === :amd
        # SuiteSparse's public control vector uses UMFPACK_ORDERING_AMD = 1.
        control[SparseArrays.UMFPACK.JL_UMFPACK_ORDERING] = 1
    end
    solver.ordering === :amd ? lu(system; control) :
        lu(system; q=collect(axes(system, 2)), control)
end

_new_factorization(system, solver::AbstractLinearSolver) =
    throw(ArgumentError("unsupported linear solver $(typeof(solver))"))

function _newton(cc,z0,previous,t,α;reltol=1e-7,abstol=1e-10,maxiters=60,
        mode=:time,source_scale=1.,gmin=0.,temperature=300.,forcing=nothing,workspace=nothing,
        line_search_minimum=1/256,voltage_abstol=max(abstol,1e-9),state_abstol=abstol,
        linear_solver=SuiteSparseLU(),history=nothing,storage_history=nothing)
    workspace === nothing && (workspace=SimulationWorkspace(cc))
    qhistory=iszero(α) ? nothing : storage_history === nothing ?
        _storage(cc,previous;temperature,workspace) : storage_history
    z=copy(z0); factorization=workspace.factorization
    linear_hierarchy=_all_linear(cc.parameters.batches)
    factorization_key=linear_hierarchy ? (cc.parameters.fingerprint,Float64(α),mode,Float64(gmin),
        linear_solver) : nothing
    for it in 1:maxiters
        r,J=_step_residual_jacobian!(workspace,cc,z,qhistory,t,α;mode,source_scale,gmin,temperature)
        forcing===nothing||(r.-=forcing)
        variable_scales=workspace.variable_scales
        scaled_matrix=workspace.scaled_jacobian
        copyto!(scaled_matrix.nzval,J.nzval)
        for column in 1:cc.n, pointer in nzrange(scaled_matrix,column); scaled_matrix.nzval[pointer]*=variable_scales[column] end
        row_norms=workspace.row_norms
        fill!(row_norms,0.)
        for column in 1:cc.n, pointer in nzrange(scaled_matrix,column)
            row=scaled_matrix.rowval[pointer]; row_norms[row]=max(row_norms[row],abs(scaled_matrix.nzval[pointer]))
        end
        inverse_row_norms=workspace.inverse_row_norms
        @inbounds for index in eachindex(row_norms)
            inverse_row_norms[index]=inv(max(row_norms[index],eps(Float64)))
        end
        system=workspace.system
        copyto!(system.nzval,scaled_matrix.nzval)
        for value_index in eachindex(system.nzval); system.nzval[value_index]*=inverse_row_norms[system.rowval[value_index]] end
        Δ=try
            rhs=workspace.rhs
            @inbounds @simd for index in eachindex(rhs)
                rhs[index]=inverse_row_norms[index]*r[index]
            end
            reuse_numeric=linear_hierarchy && factorization !== nothing &&
                workspace.factorization_key == factorization_key
            if !reuse_numeric
                factorization=factorization===nothing ? _new_factorization(system,linear_solver) :
                    lu!(factorization,system;reuse_symbolic=true)
                workspace.factorization=factorization
                workspace.factorization_key=factorization_key
                workspace.numeric_factorizations+=1
            end
            ldiv!(workspace.update,factorization,rhs)
            @inbounds @simd for index in eachindex(workspace.update)
                workspace.update[index]=-variable_scales[index]*workspace.update[index]
            end
            workspace.update
        catch error
            error isa LinearAlgebra.SingularException||rethrow()
            throw(LinearSolveError("Newton matrix is singular at iteration $(it)"))
        end
        if !all(isfinite,Δ)
            history === nothing || push!(history, (iteration=length(history)+1,
                local_iteration=it,residual_norm=norm(r,Inf),update_norm=Inf,
                damping=0.,source_scale=Float64(source_scale),gmin=Float64(gmin),
                converged=false))
            return z,it,false
        end
        # Account for roundoff in equations containing large, cancelling
        # terms (notably high-gain controlled sources).  This floor alone is
        # not a convergence test: the Newton update below must also be small,
        # which prevents high-impedance circuits from accepting a badly wrong
        # voltage merely because their absolute KCL residual is tiny.
        numerical_floor=32eps(Float64)*max(opnorm(J,Inf)*max(norm(z,Inf),1),1)
        residual_converged=norm(r,Inf)<=abstol+numerical_floor
        if residual_converged&&_update_converged(cc,z,Δ,reltol,abstol,
                voltage_abstol,state_abstol)
            history === nothing || push!(history, (iteration=length(history)+1,
                local_iteration=it,residual_norm=norm(r,Inf),update_norm=norm(Δ,Inf),
                damping=0.,source_scale=Float64(source_scale),gmin=Float64(gmin),
                converged=true))
            return z,it,true
        end
        damping=1.; nr=norm(r)
        while damping>=line_search_minimum
            candidate=workspace.candidate
            @inbounds @simd for index in eachindex(candidate)
                candidate[index]=z[index]+damping*Δ[index]
            end
            candidate_residual,_=_step_residual_jacobian!(workspace,cc,candidate,qhistory,t,α;mode,source_scale,gmin,temperature)
            forcing===nothing||(candidate_residual.-=forcing)
            norm(candidate_residual)<=nr&&break
            damping/=2
        end
        history === nothing || push!(history, (iteration=length(history)+1,
            local_iteration=it,residual_norm=norm(r,Inf),update_norm=norm(Δ,Inf),
            damping=Float64(damping),source_scale=Float64(source_scale),
            gmin=Float64(gmin),converged=false))
        @inbounds @simd for index in eachindex(z); z[index]+=damping*Δ[index] end
        all(isfinite,z)||return z,it,false
    end
    z,maxiters,false
end
