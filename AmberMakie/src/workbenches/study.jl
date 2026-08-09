mutable struct StudyHandle{F,P,R,S,C,L}
    figure::F
    parameters::P
    result::R
    status::S
    cache::C
    task::Union{Nothing,Task}
    generation::Int
    pinned::Vector{Any}
    runner::L
    controls::Dict{Symbol,Any}
    subscriptions::Vector{Any}
    closed::Bool
end

function _parameter_initial(spec)
    spec isa Tuple || return spec
    length(spec) >= 2 || throw(ArgumentError("parameter ranges need at least lower and upper bounds"))
    sqrt(float(spec[1]) * float(spec[2]))
end

function explore(runner::Function; parameters=NamedTuple(), autorun=false)
    values = Dict{Symbol,Any}(Symbol(name) => _parameter_initial(spec) for (name, spec) in pairs(parameters))
    figure = Makie.Figure(size=(900, 600))
    status = Makie.Observable{Any}(:idle); result = Makie.Observable{Any}(nothing)
    handle = StudyHandle(figure, values, result, status, Dict{Any,Any}(), nothing, 0,
        Any[], runner, Dict{Symbol,Any}(), Any[], false)
    row = 1
    for (name, spec) in pairs(parameters)
        spec isa Tuple && length(spec) >= 2 || continue
        lower, upper = float(spec[1]), float(spec[2])
        scale = length(spec) >= 3 ? spec[3] : :linear
        grid = scale === :log ? exp.(range(log(lower), log(upper); length=101)) : range(lower, upper; length=101)
        Makie.Label(figure[row, 1], String(name); halign=:right)
        slider = Makie.Slider(figure[row, 2]; range=grid, startvalue=values[Symbol(name)])
        push!(handle.subscriptions, Makie.on(slider.value) do value
            handle.parameters[Symbol(name)] = value
        end)
        handle.controls[Symbol(name)] = slider
        row += 1
    end
    button = Makie.Button(figure[row, 2]; label="Run analysis")
    push!(handle.subscriptions, Makie.on(button.clicks) do _; runstudy!(handle) end)
    handle.controls[:run] = button
    autorun && runstudy!(handle)
    handle
end

function explore(builder, analysis; parameters=NamedTuple(), outputs=Any[], autorun=false)
    runner = values -> begin
        circuit = applicable(builder, values) ? builder(values) : builder(; values...)
        Amber.simulate(circuit, analysis)
    end
    explore(runner; parameters, autorun)
end

function setparameter!(handle::StudyHandle, name, value; run=false)
    handle.closed && throw(ArgumentError("study is closed"))
    key = Symbol(name); haskey(handle.parameters, key) || throw(KeyError(key))
    handle.parameters[key] = value
    run && runstudy!(handle)
    handle
end

function runstudy!(handle::StudyHandle)
    handle.closed && throw(ArgumentError("study is closed"))
    handle.generation += 1
    names = sort!(collect(keys(handle.parameters)))
    snapshot = NamedTuple{Tuple(names)}(Tuple(handle.parameters[key] for key in names))
    key = Tuple(pairs(snapshot))
    if haskey(handle.cache, key)
        handle.result[] = handle.cache[key]; handle.status[] = :ready; return handle
    end
    handle.status[] = :running
    handle.task !== nothing && !istaskdone(handle.task) && return handle
    handle.task = @async while !handle.closed
        active_generation = handle.generation
        active_names = sort!(collect(keys(handle.parameters)))
        active_snapshot = NamedTuple{Tuple(active_names)}(Tuple(handle.parameters[key] for key in active_names))
        active_key = Tuple(pairs(active_snapshot))
        try
            value = get!(handle.cache, active_key) do
                handle.runner(active_snapshot)
            end
            if active_generation == handle.generation
                handle.result[] = value; handle.status[] = :ready
            end
        catch error
            error isa InterruptException && return
            active_generation == handle.generation &&
                (handle.status[] = (:error, sprint(showerror, error)))
        end
        active_generation == handle.generation && break
        handle.status[] = :running
    end
    handle
end

function pin!(handle::StudyHandle)
    handle.result[] === nothing && throw(ArgumentError("there is no result to pin"))
    push!(handle.pinned, handle.result[]); handle
end

function Base.close(handle::StudyHandle)
    handle.closed && return nothing
    handle.generation += 1
    handle.closed = true
    foreach(Makie.off, handle.subscriptions)
    empty!(handle.subscriptions)
    handle.status[] = :closed
    nothing
end
