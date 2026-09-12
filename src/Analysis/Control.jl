struct LinearizedModel
    E::Matrix{Float64}
    A::Matrix{Float64}
    B::Matrix{Float64}
    output_matrix::Matrix{Float64}
    D::Matrix{Float64}
    inputs::Vector{String}
    outputs::Vector{Observable}
    operating_point::Vector{Float64}
    compiled::AbstractCompiledCircuit
    stats::Dict{Symbol,Any}
end

struct LinearFrequencyResponse
    frequencies::Vector{Float64}
    values::Array{ComplexF64,3}
    inputs::Vector{String}
    outputs::Vector{Observable}
    stats::Dict{Symbol,Any}
end
frequencies(result::LinearFrequencyResponse)=result.frequencies

struct TimeResponse
    axis::Vector{Float64}
    values::Array{Float64,3}
    inputs::Vector{String}
    outputs::Vector{Observable}
    stats::Dict{Symbol,Any}
end

_as_observable(value::Observable)=value
_as_observable(value::Union{Symbol,String})=voltage(value)

function _unit_source_excitation(cc,name)
    located=_hierarchical_device(cc,name); located===nothing&&throw(KeyError(name))
    batch,device=located; kind=_batch_kind(batch)
    kind in (:voltage_source,:current_source)||throw(ArgumentError("$(name) is not an independent source"))
    excitation=zeros(Float64,cc.n)
    if kind===:voltage_source
        excitation[Int(batch.branch_unknowns[device])]=1.
    else
        positive=Int(batch.terminals[1][device]); negative=Int(batch.terminals[2][device])
        positive>0&&(excitation[positive]-=1); negative>0&&(excitation[negative]+=1)
    end
    excitation
end

function _linear_output_selector(cc,observable::Observable)
    selector=zeros(Float64,cc.n)
    if observable.kind===:voltage
        target=observable.target isa AbstractNode ? observable.target.name : observable.target
        first_index=_hierarchical_net_index(cc,target); first_index===nothing&&throw(KeyError(target))
        first_index>0&&(selector[Int(first_index)]+=1)
        if observable.extra!==nothing
            other=observable.extra isa AbstractNode ? observable.extra.name : observable.extra
            second_index=_hierarchical_net_index(cc,other); second_index===nothing&&throw(KeyError(other))
            second_index>0&&(selector[Int(second_index)]-=1)
        end
        return selector
    elseif observable.kind in (:state,:current)
        target=observable.target
        located=_hierarchical_device(cc,target); located===nothing&&throw(KeyError(target))
        batch,device=located
        if observable.kind===:state
            contract=device_contract(_batch_kind(batch)); state_index=findfirst(==(observable.extra),contract.states)
            state_index===nothing&&throw(KeyError((target,observable.extra)))
            selector[Int(batch.state_unknowns[device][state_index])]=1.; return selector
        elseif batch isa PrimitiveBatch&&batch.branch_unknowns[device]!=0
            selector[Int(batch.branch_unknowns[device])]=1.; return selector
        elseif _batch_kind(batch) in (:resistor,:conductance)
            conductance=_batch_kind(batch)===:resistor ? batch.conductance[device] : batch.parameters[device].value
            positive=Int(_batch_terminal(batch,1,device)); negative=Int(_batch_terminal(batch,2,device))
            positive>0&&(selector[positive]+=conductance); negative>0&&(selector[negative]-=conductance)
            return selector
        end
        throw(ArgumentError("descriptor outputs currently require voltage, state, branch-current, resistor-current, or conductance-current observables"))
    end
    throw(ArgumentError("unsupported linear output observable $(observable.kind)"))
end

function linearize(c;inputs,outputs,bias=nothing,temperature=300.,kw...)
    cc=compile(c)
    point=bias===nothing ? _require_converged(operating_point(cc;temperature,kw...),"linearization operating point").values[:,1] : bias isa SimulationResult ? bias.values[:,1] : Float64.(bias)
    length(point)==cc.n||throw(DimensionMismatch("bias point does not match the compiled circuit"))
    G,E=_static_dynamic_jacobians(cc,point;mode=:dc,temperature)
    input_names=inputs isa Union{Symbol,String} ? String[String(inputs)] : String.(inputs)
    output_observables=outputs isa Union{Observable,Symbol,String} ? Observable[_as_observable(outputs)] : Observable[_as_observable(output) for output in outputs]
    B=hcat((_unit_source_excitation(cc,name) for name in input_names)...)
    output_matrix=vcat((transpose(_linear_output_selector(cc,observable)) for observable in output_observables)...)
    D=zeros(Float64,length(output_observables),length(input_names))
    stats=Dict{Symbol,Any}(:temperature=>Float64(temperature),:warnings=>String[])
    LinearizedModel(Matrix(E),-Matrix(G),Matrix(B),Matrix(output_matrix),D,input_names,output_observables,Float64.(point),_snapshot_compiled(cc),stats)
end

function frequency_response(model::LinearizedModel,frequency_specification::Union{Pair,AbstractVector};points=100,scale=:log)
    fs=_small_signal_frequencies(frequency_specification;points=frequency_specification isa AbstractVector ? length(frequency_specification) : points,scale)
    values=zeros(ComplexF64,length(model.outputs),length(model.inputs),length(fs))
    for (index,frequency) in enumerate(fs)
        values[:,:,index]=model.output_matrix*((im*2π*frequency*model.E-model.A)\model.B)+model.D
    end
    LinearFrequencyResponse(Float64.(fs),values,copy(model.inputs),copy(model.outputs),Dict{Symbol,Any}(:warnings=>String[]))
end

dcgain(model::LinearizedModel)=model.output_matrix*((-model.A)\model.B)+model.D
function _generalized_values(model::LinearizedModel)
    eigvals(model.A,model.E)
end
poles(model::LinearizedModel;include_infinite=false)=include_infinite ? _generalized_values(model) : filter(isfinite,_generalized_values(model))
natural_frequencies(model::LinearizedModel)=abs.(poles(model))./(2π)
damping_ratios(model::LinearizedModel)=[iszero(abs(value)) ? NaN : -real(value)/abs(value) for value in poles(model)]
isstable(model::LinearizedModel;atol=sqrt(eps(Float64)))=all(value->real(value)<-atol,poles(model))

function transmission_zeros(model::LinearizedModel;input=1,output=1)
    n=size(model.A,1); b=model.B[:,input:input]; c=model.output_matrix[output:output,:]; d=model.D[output:output,input:input]
    pencil_a=[model.A b;c d]; pencil_e=[model.E zeros(n,1);zeros(1,n+1)]
    values=eigvals(pencil_a,pencil_e)
    filter(isfinite,values)
end

function _siso_values(response::LinearFrequencyResponse;input=1,output=1)
    vec(response.values[output,input,:])
end
gain_crossovers(response::LinearFrequencyResponse;input=1,output=1)=crossings(response.frequencies,db20(_siso_values(response;input,output));level=0.)
phase_crossovers(response::LinearFrequencyResponse;input=1,output=1)=crossings(response.frequencies,rad2deg.(phase(_siso_values(response;input,output);unwrap=true));level=-180.)

struct StabilityMargins
    gain_margin::Float64
    phase_margin::Float64
    gain_crossover::Float64
    phase_crossover::Float64
end

function _interpolate_response(response::LinearFrequencyResponse,frequency;input=1,output=1)
    fs=response.frequencies; values=_siso_values(response;input,output); index=searchsortedfirst(fs,frequency)
    index<=1&&return first(values); index>length(fs)&&return last(values)
    fraction=(log(frequency)-log(fs[index-1]))/(log(fs[index])-log(fs[index-1]))
    magnitude=exp(log(abs(values[index-1]))+fraction*(log(abs(values[index]))-log(abs(values[index-1]))))
    phases=phase(values;unwrap=true); magnitude*cis(phases[index-1]+fraction*(phases[index]-phases[index-1]))
end

function stability_margins(response::LinearFrequencyResponse;input=1,output=1)
    gain_crossing=gain_crossovers(response;input,output); phase_crossing=phase_crossovers(response;input,output)
    gc=isempty(gain_crossing) ? NaN : first(gain_crossing); pc=isempty(phase_crossing) ? NaN : first(phase_crossing)
    pm=isnan(gc) ? Inf : 180+rad2deg(angle(_interpolate_response(response,gc;input,output)))
    gm=isnan(pc) ? Inf : -db20(_interpolate_response(response,pc;input,output))
    StabilityMargins(gm,pm,gc,pc)
end
gain_margin(response::LinearFrequencyResponse;kw...)=stability_margins(response;kw...).gain_margin
phase_margin(response::LinearFrequencyResponse;kw...)=stability_margins(response;kw...).phase_margin
sensitivity(loop_gain_values)=inv.(1 .+loop_gain_values)
complementary_sensitivity(loop_gain_values)=loop_gain_values./(1 .+loop_gain_values)

function _time_response(model::LinearizedModel,interval::Pair;saveat,input_index=1,impulse=false)
    start,stop=Float64(first(interval)),Float64(last(interval)); stop>start||throw(ArgumentError("response interval must be increasing"))
    step=Float64(saveat); step>0||throw(ArgumentError("saveat must be positive")); times=collect(start:step:stop)
    states=zeros(Float64,size(model.A,1),length(times)); values=zeros(Float64,length(model.outputs),length(model.inputs),length(times))
    system=model.E/step-model.A; forcing=model.B[:,input_index]
    if impulse
        states[:,1]=(model.E-step*model.A)\forcing
        values[:,input_index,1]=model.output_matrix*states[:,1]
    end
    for index in 2:length(times)
        rhs=model.E/step*states[:,index-1]+(impulse ? zero(forcing) : forcing)
        states[:,index]=system\rhs; values[:,input_index,index]=model.output_matrix*states[:,index]+(impulse ? zero(model.D[:,input_index]) : model.D[:,input_index])
    end
    TimeResponse(Float64.(times),values,copy(model.inputs),copy(model.outputs),Dict{Symbol,Any}(:method=>:bdf1,:warnings=>String[]))
end
step_response(model::LinearizedModel,interval::Pair;saveat,input=1)=_time_response(model,interval;saveat,input_index=input,impulse=false)
impulse_response(model::LinearizedModel,interval::Pair;saveat,input=1)=_time_response(model,interval;saveat,input_index=input,impulse=true)

_time_trace(result::TimeResponse;input=1,output=1)=vec(result.values[output,input,:])
function rise_time(result::TimeResponse;input=1,output=1,levels=(.1,.9))
    values=_time_trace(result;input,output); initial,final=first(values),last(values); low=initial+levels[1]*(final-initial); high=initial+levels[2]*(final-initial)
    _first_crossing(result.axis,values,high)-_first_crossing(result.axis,values,low)
end
function settling_time(result::TimeResponse;input=1,output=1,tolerance=.02)
    values=_time_trace(result;input,output); final=last(values); bound=tolerance*max(abs(final-first(values)),eps())
    last_outside=findlast(value->abs(value-final)>bound,values); last_outside===nothing ? first(result.axis) : last_outside==length(values) ? Inf : result.axis[last_outside+1]
end
peak_time(result::TimeResponse;input=1,output=1)=result.axis[argmax(abs.(_time_trace(result;input,output).-last(_time_trace(result;input,output))))]
steady_state_error(result::TimeResponse;input=1,output=1,target=1.)=target-last(_time_trace(result;input,output))

function root_locus(model::LinearizedModel,gains;input=1,output=1)
    size(model.D)==(length(model.outputs),length(model.inputs))||throw(ArgumentError("invalid feedthrough matrix"))
    [filter(isfinite,eigvals(model.A-gain*model.B[:,input:input]*model.output_matrix[output:output,:],model.E)) for gain in gains]
end
