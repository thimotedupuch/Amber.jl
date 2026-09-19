abstract type AbstractVariation end

struct Gaussian <: AbstractVariation
    mean::Float64
    sigma::Float64
    function Gaussian(mean::Real,sigma::Real)
        isfinite(mean)&&isfinite(sigma)&&sigma>=0||throw(ArgumentError("Gaussian parameters must be finite and sigma must be non-negative"))
        new(Float64(mean),Float64(sigma))
    end
end

struct LogNormal <: AbstractVariation
    logmean::Float64
    logsigma::Float64
    function LogNormal(logmean::Real,logsigma::Real)
        isfinite(logmean)&&isfinite(logsigma)&&logsigma>=0||throw(ArgumentError("LogNormal parameters must be finite and logsigma must be non-negative"))
        new(Float64(logmean),Float64(logsigma))
    end
end

struct UniformVariation <: AbstractVariation
    low::Float64
    high::Float64
    function UniformVariation(low::Real,high::Real)
        isfinite(low)&&isfinite(high)&&low<=high||throw(ArgumentError("UniformVariation bounds must be finite and low must not exceed high"))
        new(Float64(low),Float64(high))
    end
end

struct ProcessVariation
    variations::Dict{Symbol,AbstractVariation}
end
ProcessVariation(variations::AbstractDict)=ProcessVariation(Dict{Symbol,AbstractVariation}(Symbol(path)=>variation for (path,variation) in pairs(variations)))
ProcessVariation(;kw...)=ProcessVariation(Dict(Symbol(path)=>variation for (path,variation) in pairs(kw)))

struct CorrelatedVariation
    paths::Vector{Symbol}
    means::Vector{Float64}
    covariance::Matrix{Float64}
    factor::Matrix{Float64}
    function CorrelatedVariation(paths,means,covariance)
        normalized_paths=Symbol.(paths); normalized_means=Float64.(means); matrix=Matrix{Float64}(covariance)
        length(normalized_paths)==length(normalized_means)==size(matrix,1)==size(matrix,2)||throw(ArgumentError("correlated variation dimensions must agree"))
        all(isfinite,normalized_means)&&all(isfinite,matrix)||throw(ArgumentError("correlated variation values must be finite"))
        factor=Matrix(cholesky(Symmetric(matrix)).L)
        new(normalized_paths,normalized_means,matrix,factor)
    end
end

_draw(rng,variation::Gaussian)=variation.mean+variation.sigma*randn(rng)
_draw(rng,variation::LogNormal)=exp(variation.logmean+variation.logsigma*randn(rng))
_draw(rng,variation::UniformVariation)=variation.low+(variation.high-variation.low)*rand(rng)

struct MonteCarloFailure
    sample::Int
    seed::UInt64
    exception_type::Symbol
    message::String
end

struct MonteCarloResult{T,A<:AbstractAnalysis}
    analysis::A
    values::Vector{Union{Nothing,T}}
    parameters::Vector{Dict{Symbol,Float64}}
    seeds::Vector{UInt64}
    converged::BitVector
    failures::Vector{MonteCarloFailure}
    metadata::Dict{Symbol,Any}
end

sample_values(result::MonteCarloResult)=result.values
sample_parameters(result::MonteCarloResult)=result.parameters
successful(result::MonteCarloResult{T}) where T=T[result.values[index]::T for index in eachindex(result.values) if result.converged[index]]
failure_rate(result::MonteCarloResult)=isempty(result.values) ? 0. : count(!,result.converged)/length(result.values)
yield_rate(result::MonteCarloResult,predicate::Function)=isempty(result.values) ? NaN : count(index->result.converged[index]&&predicate(result.values[index]),eachindex(result.values))/length(result.values)

function Statistics.mean(result::MonteCarloResult)
    values=successful(result); isempty(values)&&throw(ArgumentError("Monte Carlo result has no successful samples")); Statistics.mean(values)
end
function Statistics.std(result::MonteCarloResult;kw...)
    values=successful(result); isempty(values)&&throw(ArgumentError("Monte Carlo result has no successful samples")); Statistics.std(values;kw...)
end
function Statistics.quantile(result::MonteCarloResult,p;kw...)
    values=successful(result); isempty(values)&&throw(ArgumentError("Monte Carlo result has no successful samples")); Statistics.quantile(values,p;kw...)
end
function _normal_quantile_for_level(level)
    0<level<1||throw(ArgumentError("confidence level must lie in (0, 1)"))
    # Accurate to better than 4e-4 for conventional confidence levels.
    p=.5+level/2; a=.147; y=2p-1; logarithm=log(1-y^2)
    sqrt(2)*sign(y)*sqrt(sqrt((2/(π*a)+logarithm/2)^2-logarithm/a)-(2/(π*a)+logarithm/2))
end
function confidence_interval(result::MonteCarloResult;level=.95)
    values=successful(result); length(values)>1||throw(ArgumentError("at least two successful samples are required"))
    z=_normal_quantile_for_level(level)
    center=Statistics.mean(values); half=z*Statistics.std(values)/sqrt(length(values)); center-half=>center+half
end
function yield_confidence_interval(result::MonteCarloResult,predicate::Function;level=.95)
    n=length(result.values); n>0||throw(ArgumentError("at least one sample is required")); z=_normal_quantile_for_level(level)
    successes=count(index->result.converged[index]&&predicate(result.values[index]),eachindex(result.values)); estimate=successes/n
    denominator=1+z^2/n; center=(estimate+z^2/(2n))/denominator
    half=z/denominator*sqrt(estimate*(1-estimate)/n+z^2/(4n^2)); max(0.,center-half)=>min(1.,center+half)
end

function _normalized_variations(variations)
    variations===nothing&&return Pair{Symbol,AbstractVariation}[]
    source=variations isa AbstractDict || variations isa NamedTuple ? pairs(variations) : variations
    output=Pair{Symbol,AbstractVariation}[]
    for (path,variation) in source
        variation isa AbstractVariation||throw(ArgumentError("variation for $(path) must be Gaussian, LogNormal, or UniformVariation"))
        push!(output,Symbol(path)=>variation)
    end
    output
end

function _compiled_device_records(compiled)
    records=NamedTuple[]
    for batch in compiled.parameters.batches, device in eachindex(batch.parameters)
        instance_name,device_name=_locator_device_name(compiled.design,batch.locators[device])
        path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
        push!(records,(batch,device,path,kind=_batch_kind(batch),parameters=batch.parameters[device]))
    end
    records
end

function _automatic_tolerance_draws!(draws,compiled,rng,explicit_paths,records=_compiled_device_records(compiled))
    for component in records
        hasproperty(component.parameters,:tolerance)||continue
        path=Symbol(component.path,".value"); path in explicit_paths&&continue
        nominal=get(component.parameters,:value,nothing); tolerance=component.parameters.tolerance
        nominal isa Real&&tolerance isa Real||throw(ArgumentError("$(component.path) tolerance requires a numeric value and tolerance"))
        isfinite(tolerance)&&tolerance>=0||throw(ArgumentError("$(component.path) tolerance must be finite and non-negative"))
        draws[path]=Float64(nominal)*(1+(2rand(rng)-1)*Float64(tolerance))
    end
end

function _matched_group_draws!(draws,compiled,rng,explicit_paths,records=_compiled_device_records(compiled))
    groups=Dict{Symbol,Vector{Any}}()
    definitions=Dict{Symbol,MatchedGroup}()
    for component in records
        match=get(component.parameters,:match,nothing)
        match isa MatchedGroup||continue
        component.kind===:npn||throw(ArgumentError("matched groups are currently supported only for NPN devices"))
        push!(get!(groups,match.name,Any[]),component); definitions[match.name]=match
    end
    for (name,components) in groups
        match=definitions[name]; 0<=match.correlation<=1||throw(ArgumentError("matched-group correlation must lie in [0, 1]"))
        common_vbe=randn(rng); common_beta=randn(rng)
        common_weight=sqrt(match.correlation); local_weight=sqrt(1-match.correlation)
        for component in components
            model=component.parameters[:model]
            saturation_path=Symbol(component.path,".saturation_current")
            beta_path=Symbol(component.path,".forward_beta")
            if saturation_path ∉ explicit_paths
                delta_vbe=match.sigma_vbe*(common_weight*common_vbe+local_weight*randn(rng))
                draws[saturation_path]=Float64(model.saturation_current)*exp(-delta_vbe/.025852)
            end
            if beta_path ∉ explicit_paths
                delta_log_beta=match.sigma_log_beta*(common_weight*common_beta+local_weight*randn(rng))
                draws[beta_path]=Float64(model.forward_beta)*exp(delta_log_beta)
            end
        end
    end
end

_apply_monte_carlo_draws(compiled,draws)=with_parameters(compiled,collect(pairs(draws))...)
_apply_monte_carlo_draws(compiled,draws,handles)=
    with_parameters(compiled,(get(handles,path,path)=>value for (path,value) in draws)...)

function _monte_carlo_handles(compiled,paths,records)
    selectors=Set(paths)
    for component in records
        hasproperty(component.parameters,:tolerance) && push!(selectors,Symbol(component.path,".value"))
        if get(component.parameters,:match,nothing) isa MatchedGroup && component.kind===:npn
            push!(selectors,Symbol(component.path,".saturation_current"))
            push!(selectors,Symbol(component.path,".forward_beta"))
        end
    end
    handles=Dict{Symbol,ParameterHandle}()
    for path in selectors
        try
            handles[path]=parameter_handle(compiled,path)
        catch error
            # Preserve the per-sample reporting of invalid structural updates.
            error isa TopologyParameterError || error isa KeyError || rethrow()
        end
    end
    handles
end

function _validate_variation_paths(compiled,paths)
    for path in paths
        selector=_parse_parameter_selector(String(path))
        matched_device=false; matched_parameter=false
        for batch in compiled.parameters.batches, device in eachindex(batch.parameters)
            instance_name,device_name=_locator_device_name(compiled.design,batch.locators[device])
            _matches_selector(instance_name,device_name,selector[1],selector[2],selector[3])||continue
            matched_device=true
            parameters=batch.parameters[device]
            matched_parameter |= selector[4]===:value&&batch isa ResistorBatch ||
                hasproperty(parameters,selector[4]) ||
                hasproperty(parameters,:model)&&hasproperty(model_parameters(parameters.model),selector[4])
        end
        matched_device||throw(ArgumentError("variation path $(path) refers to an unknown component"))
        matched_parameter||throw(ArgumentError("variation path $(path) refers to an unknown parameter"))
    end
end

function _monte_carlo_metric(metric,metrics)
    metrics===nothing&&return metric
    metric===identity||throw(ArgumentError("specify either metric or metrics, not both"))
    metrics isa NamedTuple&&return result->map(function_->function_(result),metrics)
    metrics isa AbstractDict&&return result->Dict(name=>function_(result) for (name,function_) in pairs(metrics))
    metrics isa AbstractVector&&return result->map(function_->function_(result),metrics)
    throw(ArgumentError("metrics must be a vector, dictionary, or named tuple of functions"))
end

"""Run reproducible parameter-variation trials and retain metrics, draws, seeds, and failures."""
function monte_carlo(circuit;analysis=OperatingPoint(),samples::Integer=1000,seed::Integer=0,
        variations=nothing,process=nothing,correlated=CorrelatedVariation[],metric=identity,metrics=nothing,
        parallel::Bool=false,store_parameters::Bool=true,on_sample=nothing)
    samples>=0||throw(ArgumentError("samples must be non-negative"))
    analysis isa AbstractAnalysis||throw(ArgumentError("analysis must be an Amber analysis"))
    process===nothing||process isa ProcessVariation||throw(ArgumentError("process must be a ProcessVariation"))
    combined=process===nothing ? _normalized_variations(variations) : vcat(_normalized_variations(process.variations),_normalized_variations(variations))
    correlated isa CorrelatedVariation&&(correlated=[correlated])
    all(group->group isa CorrelatedVariation,correlated)||throw(ArgumentError("correlated entries must be CorrelatedVariation objects"))
    correlated_paths=Symbol[path for group in correlated for path in group.paths]
    all_paths=vcat(first.(combined),correlated_paths)
    length(unique(all_paths))==length(all_paths)||throw(ArgumentError("variation paths must be unique across independent and correlated variations"))
    base=compile(circuit); normalized=combined
    _validate_variation_paths(base,all_paths)
    explicit_paths=Set(all_paths); metric_function=_monte_carlo_metric(metric,metrics)
    records=_compiled_device_records(base)
    handles=_monte_carlo_handles(base,all_paths,records)
    master=Random.Xoshiro(seed); seeds=rand(master,UInt64,samples)
    values=Any[nothing for _ in 1:samples]; parameters=[Dict{Symbol,Float64}() for _ in 1:samples]
    # Threads own distinct bytes; packed BitVector writes share storage words.
    converged=fill(false,samples); failures=MonteCarloFailure[]
    failure_lock=ReentrantLock()
    function run_sample(sample)
        rng=Random.Xoshiro(seeds[sample]); draws=parameters[sample]
        try
            for (path,variation) in normalized; draws[path]=_draw(rng,variation) end
            for group in correlated
                group_draw=group.means+group.factor*randn(rng,length(group.paths))
                for (path,value) in zip(group.paths,group_draw); draws[path]=value end
            end
            _automatic_tolerance_draws!(draws,base,rng,explicit_paths,records)
            _matched_group_draws!(draws,base,rng,explicit_paths,records)
            trial=_apply_monte_carlo_draws(base,draws,handles)
            simulation=_require_converged(simulate(trial,analysis),"Monte Carlo sample $(sample)")
            value=metric_function(simulation)
            on_sample===nothing||on_sample(sample,value,copy(draws))
            values[sample]=value; converged[sample]=true
        catch error
            error isa InterruptException&&rethrow()
            lock(failure_lock) do
                push!(failures,MonteCarloFailure(sample,seeds[sample],Symbol(nameof(typeof(error))),sprint(showerror,error)))
            end
        end
    end
    if parallel&&samples>1
        Threads.@threads for sample in 1:samples; run_sample(sample) end
    else
        for sample in 1:samples; run_sample(sample) end
    end
    sort!(failures;by=failure->failure.sample)
    store_parameters||foreach(empty!,parameters)
    metadata=Dict{Symbol,Any}(:seed=>seed,:samples=>samples,:circuit_fingerprint=>base.fingerprint,
        :successful_samples=>count(converged),:failed_samples=>count(!,converged),
        :parameters_stored=>store_parameters)
    successful_values=Any[values[index] for index in eachindex(values) if converged[index]]
    value_type=isempty(successful_values) ? Any : all(value->typeof(value)===typeof(first(successful_values)),successful_values) ? typeof(first(successful_values)) : Any
    typed_values=Vector{Union{Nothing,value_type}}(values)
    MonteCarloResult(analysis,typed_values,parameters,seeds,BitVector(converged),failures,metadata)
end

function replay_sample(result::MonteCarloResult,circuit,index::Integer;metric=identity)
    checkbounds(result.values,index)
    get(result.metadata,:parameters_stored,false)||throw(ArgumentError(
        "sample replay requires verified parameter draws; run monte_carlo with store_parameters=true"))
    base=compile(circuit)
    base.fingerprint==result.metadata[:circuit_fingerprint]||throw(ArgumentError(
        "sample replay requires the original base circuit"))
    result.converged[index]||throw(ArgumentError("cannot replay an unsuccessful sample"))
    trial=_apply_monte_carlo_draws(base,result.parameters[index])
    simulation=_require_converged(simulate(trial,result.analysis),"Monte Carlo replay $(index)")
    metric(simulation)
end

function provenance(result::MonteCarloResult)
    Dict(:amber_version=>v"0.1.0",:analysis=>string(typeof(result.analysis)),:monte_carlo=>copy(result.metadata),
        :seeds=>copy(result.seeds),:failures=>copy(result.failures),:unit_system=>:SI)
end

function report(result::MonteCarloResult)
    Dict(:analysis=>string(typeof(result.analysis)),:samples=>length(result.values),
        :successful_samples=>count(result.converged),:failed_samples=>count(!,result.converged),
        :failure_rate=>failure_rate(result))
end

function _encode_analysis(analysis::OperatingPoint)
    Dict("kind"=>"operating_point","temperature"=>analysis.temperature,"solver"=>_encode_value(analysis.solver))
end
function _encode_analysis(analysis::Transient)
    Dict("kind"=>"transient","interval"=>[first(analysis.interval),last(analysis.interval)],
        "saveat"=>_encode_value(analysis.saveat),"max_step"=>_encode_value(analysis.max_step),
        "method"=>String(analysis.method),"adaptive"=>_encode_value(analysis.adaptive),
        "temperature"=>analysis.temperature,"overrides"=>_encode_value(analysis.overrides),
        "solver"=>_encode_value(analysis.solver),"initial"=>_encode_value(analysis.initial),
        "event_mode"=>_encode_value(analysis.event_mode),"integration"=>_encode_value(analysis.integration),
        "failure_policy"=>String(analysis.failure_policy))
end
function _encode_analysis(analysis::TransientNoise)
    Dict("kind"=>"transient_noise",
        "interval"=>[first(analysis.interval),last(analysis.interval)],
        "timestep"=>analysis.timestep,"saveat"=>analysis.saveat,
        "seed"=>string(analysis.seed),"temperature"=>analysis.temperature,
        "low_frequency_cutoff"=>analysis.low_frequency_cutoff,
        "event_mode"=>_encode_value(analysis.event_mode),"initial"=>_encode_value(analysis.initial),
        "solver"=>_encode_value(analysis.solver))
end
function _encode_analysis(analysis::SmallSignal)
    Dict("kind"=>"small_signal","frequency_grid"=>_encode_value(analysis.frequencies),
        "source"=>_encode_value(analysis.source),"temperature"=>analysis.temperature,"solver"=>_encode_value(analysis.solver))
end

function _encode_analysis(analysis::PeriodicSteadyState)
    fields=fieldnames(typeof(analysis))
    Dict("kind"=>"periodic_steady_state","options"=>_encode_value(
        NamedTuple{fields}(Tuple(getfield(analysis,name) for name in fields))))
end

_decode_setting(encoded,key,default)=haskey(encoded,key) ? _decode_value(encoded[key],Dict(),Dict()) : default

function _decode_analysis(encoded)
    kind=encoded["kind"]
    kind=="periodic_steady_state"&&return PeriodicSteadyState(;_decode_value(encoded["options"],Dict(),Dict())...)
    kind=="operating_point"&&return OperatingPoint(temperature=get(encoded,"temperature",300.),solver=_decode_setting(encoded,"solver",SolverOptions()))
    if kind=="transient"
        interval=Float64(encoded["interval"][1])=>Float64(encoded["interval"][2])
        return Transient(interval;saveat=_decode_value(encoded["saveat"],Dict(),Dict()),max_step=_decode_value(encoded["max_step"],Dict(),Dict()),
            method=Symbol(encoded["method"]),adaptive=_decode_value(encoded["adaptive"],Dict(),Dict()),temperature=Float64(encoded["temperature"]),
            overrides=_decode_value(encoded["overrides"],Dict(),Dict()),
            solver=_decode_setting(encoded,"solver",SolverOptions()),initial=_decode_setting(encoded,"initial",nothing),
            event_mode=_decode_setting(encoded,"event_mode",nothing),integration=_decode_setting(encoded,"integration",IntegrationOptions()),
            failure_policy=Symbol(get(encoded,"failure_policy","return_partial")))
    elseif kind=="transient_noise"
        interval=Float64(encoded["interval"][1])=>Float64(encoded["interval"][2])
        return TransientNoise(interval=interval,
            timestep=Float64(encoded["timestep"]),saveat=Float64(encoded["saveat"]),
            seed=parse(UInt64,encoded["seed"]),temperature=Float64(encoded["temperature"]),
            low_frequency_cutoff=Float64(encoded["low_frequency_cutoff"]),
            event_mode=_decode_value(encoded["event_mode"],Dict(),Dict()),
            initial=_decode_setting(encoded,"initial",nothing),
            solver=_decode_setting(encoded,"solver",SolverOptions(reltol=1e-6,current_abstol=1e-9,voltage_abstol=1e-9,state_abstol=1e-9,max_newton_iterations=120)))
    elseif kind=="small_signal"
        frequencies=Float64.(_decode_value(encoded["frequency_grid"],Dict(),Dict()))
        return SmallSignal(frequencies;source=_decode_value(encoded["source"],Dict(),Dict()),temperature=Float64(encoded["temperature"]),solver=_decode_setting(encoded,"solver",SolverOptions()))
    end
    throw(CircuitSerializationError("unsupported serialized Monte Carlo analysis $(kind)"))
end

function serialize_monte_carlo(result::MonteCarloResult)
    snapshot=Dict{String,Any}("schema"=>"amber-monte-carlo","schema_version"=>2,
        "analysis"=>_encode_analysis(result.analysis),"values"=>_encode_value(result.values),
        "parameters"=>_encode_value(result.parameters),"seeds"=>string.(result.seeds),
        "converged"=>collect(result.converged),"failures"=>[Dict("sample"=>failure.sample,"seed"=>string(failure.seed),
            "exception_type"=>String(failure.exception_type),"message"=>failure.message) for failure in result.failures],
        "metadata"=>_encode_value(result.metadata))
    io=IOBuffer(); TOML.print(io,snapshot;sorted=true); String(take!(io))
end

function deserialize_monte_carlo(text::AbstractString;max_bytes=64*1024*1024,max_samples=10_000_000)
    sizeof(text)<=max_bytes||throw(CircuitSerializationError("serialized Monte Carlo result exceeds the byte limit"))
    snapshot=try TOML.parse(text) catch error; throw(CircuitSerializationError("invalid Monte Carlo serialization: $(sprint(showerror,error))")) end
    get(snapshot,"schema",nothing)=="amber-monte-carlo"||throw(CircuitSerializationError("not an Amber Monte Carlo serialization"))
    get(snapshot,"schema_version",nothing)==2||throw(CircuitSerializationError("unsupported Monte Carlo schema version"))
    converged=BitVector(snapshot["converged"]); length(converged)<=max_samples||throw(CircuitSerializationError("serialized Monte Carlo result exceeds the sample limit"))
    decoded_values=_decode_value(snapshot["values"],Dict(),Dict()); raw_values=Any[decoded_values...]
    successful_values=Any[raw_values[index] for index in eachindex(raw_values) if converged[index]]
    value_type=isempty(successful_values) ? Any : all(value->typeof(value)===typeof(first(successful_values)),successful_values) ? typeof(first(successful_values)) : Any
    values=Vector{Union{Nothing,value_type}}(raw_values)
    raw_parameters=_decode_value(snapshot["parameters"],Dict(),Dict())
    parameters=[Dict{Symbol,Float64}(Symbol(path)=>Float64(value) for (path,value) in pairs(draw)) for draw in raw_parameters]
    seeds=parse.(UInt64,snapshot["seeds"])
    failures=[MonteCarloFailure(Int(item["sample"]),parse(UInt64,item["seed"]),Symbol(item["exception_type"]),String(item["message"])) for item in snapshot["failures"]]
    metadata=Dict{Symbol,Any}(_decode_value(snapshot["metadata"],Dict(),Dict()))
    MonteCarloResult(_decode_analysis(snapshot["analysis"]),values,parameters,seeds,converged,failures,metadata)
end

save_monte_carlo(path::AbstractString,result::MonteCarloResult)=(open(io->write(io,serialize_monte_carlo(result)),path,"w");path)
load_monte_carlo(path::AbstractString;kw...)=deserialize_monte_carlo(read(path,String);kw...)
