struct SweepFailure
    index::Int
    parameter_value::Any
    error_type::Symbol
    message::String
end

struct SweepResult{A<:AbstractAnalysis}
    selector::String
    parameter_values::Vector{Any}
    metrics::Vector{Any}
    simulations::Vector{Any}
    converged::BitVector
    failures::Vector{SweepFailure}
    analysis::A
    metadata::Dict{Symbol,Any}
end

Base.length(result::SweepResult)=length(result.parameter_values)
Base.getindex(result::SweepResult,index)=result.metrics[index]
Base.iterate(result::SweepResult,state=1)=state>length(result) ? nothing : (result.metrics[state],state+1)
successful(result::SweepResult)=Any[result.metrics[index] for index in eachindex(result.metrics) if result.converged[index]]
failure_rate(result::SweepResult)=isempty(result.converged) ? 0. : count(!,result.converged)/length(result.converged)

"""Repeat an analysis over parameter values while retaining every success and failure."""
function sweep(c,p::Pair;analysis=OperatingPoint(),metric=identity)
    analysis isa AbstractAnalysis||throw(ArgumentError("analysis must be an Amber analysis"))
    cc=compile(c)
    selector=String(first(p)); occursin('.',selector)||(selector=string(selector,".value"))
    parameter_values=Any[collect(last(p))...]
    metrics=Any[nothing for _ in parameter_values]
    simulations=Any[nothing for _ in parameter_values]
    converged=falses(length(parameter_values)); failures=SweepFailure[]
    for (index,value) in enumerate(parameter_values)
        try
            simulation=simulate(with_parameters(cc,selector=>value),analysis)
            simulations[index]=simulation
            get(simulation.stats,:converged,false)||throw(ConvergenceError(
                "sweep point $(index) did not converge",copy(simulation.stats)))
            metrics[index]=metric(simulation); converged[index]=true
        catch error
            error isa InterruptException&&rethrow()
            push!(failures,SweepFailure(index,value,Symbol(nameof(typeof(error))),sprint(showerror,error)))
        end
    end
    metadata=Dict{Symbol,Any}(:selector=>selector,:points=>length(parameter_values),
        :successful_points=>count(converged),:failed_points=>count(!,converged),
        :circuit_fingerprint=>cc.fingerprint)
    SweepResult(selector,parameter_values,metrics,simulations,converged,failures,analysis,metadata)
end

provenance(result::SweepResult)=Dict(:amber_version=>v"0.1.0",:analysis=>string(typeof(result.analysis)),
    :sweep=>copy(result.metadata),:failures=>copy(result.failures),:unit_system=>:SI)
report(result::SweepResult)=Dict(:analysis=>string(typeof(result.analysis)),:selector=>result.selector,
    :points=>length(result),:successful_points=>count(result.converged),
    :failed_points=>count(!,result.converged),:failure_rate=>failure_rate(result))
