struct Diagnostic
    severity::Symbol
    message::String
end

struct CircuitValidationError <: Exception
    diagnostics::Vector{Diagnostic}
end
function Base.showerror(io::IO,error::CircuitValidationError)
    print(io,"Circuit validation failed:")
    for diagnostic in error.diagnostics
        print(io,"\n- ",diagnostic.message)
    end
end

struct AnalysisValidationError <: Exception
    message::String
end
Base.showerror(io::IO,error::AnalysisValidationError)=print(io,"Invalid analysis: ",error.message)
Base.show(io::IO,d::Diagnostic)=print(io,d.message)

struct CircuitLookupError <: Exception
    kind::Symbol
    name::String
    candidates::Vector{String}
end

function _edit_distance(a::AbstractString,b::AbstractString)
    previous=collect(0:length(b))
    for (i,left) in enumerate(a)
        current=Vector{Int}(undef,length(previous)); current[1]=i
        for (j,right) in enumerate(b)
            current[j+1]=min(current[j]+1,previous[j+1]+1,previous[j]+(left!=right))
        end
        previous=current
    end
    last(previous)
end

function Base.showerror(io::IO,error::CircuitLookupError)
    label=replace(String(error.kind),'_'=>' ')
    print(io,"Unknown ",label," `",error.name,"`.")
    isempty(error.candidates)&&return
    ranked=sort(error.candidates;by=candidate->(_edit_distance(lowercase(error.name),lowercase(candidate)),candidate))
    best=first(ranked)
    threshold=max(2,cld(max(length(error.name),length(best)),3))
    if _edit_distance(lowercase(error.name),lowercase(best))<=threshold
        print(io," Did you mean `",best,"`?")
    end
    shown=join(first(ranked,min(5,length(ranked))),", ")
    print(io," Available ",label,"s: ",shown)
    length(ranked)>5&&print(io,", …")
    print(io,'.')
end

function _net_labels(design,topology)
    labels=Dict{Int32,Vector{String}}()
    add(index,label)=index==0 ? nothing : push!(get!(labels,Int32(index),String[]),label)
    mapping=topology.hierarchy.root_net_to_solver
    for (local_index,segment) in enumerate(design.root_ir.net_names)
        name=_render_segment((_name(design.names,segment.base),segment.index))
        add(mapping[local_index],name)
    end
    for (instance_index,record) in enumerate(design.root.records)
        prefix=string(InstancePath(_path_segments(design,record.path)))
        template=design.templates.templates[Int(record.template)]
        for (port_index,port) in enumerate(template.ports)
            actual=design.root.connection_data[Int(record.connections.start)+port_index-1]
            add(mapping[Int(actual)],string(prefix,'.',_name(template.names,port.name)))
        end
        for local_index in (length(template.ports)+1):length(template.body.net_names)
            segment=template.body.net_names[local_index]
            name=_render_segment((_name(template.names,segment.base),segment.index))
            solver_index=topology.hierarchy.instance_internal_base[instance_index]+local_index-length(template.ports)-1
            add(solver_index,string(prefix,'.',name))
        end
    end
    labels
end

"""Validate and compile a design in one hierarchy-elaboration pass."""
function _check_and_compile(design::CircuitDesign)
    diagnostics = Diagnostic[]
    design.root_ir.ground_net == 0 && push!(diagnostics, Diagnostic(:error,
        "Circuit has no electrical reference. Add ground() to the top-level @circuit."))
    bodies = Any[("root", design.root_ir, design.names)]
    append!(bodies, ((_name(template.names, template.name), template.body, template.names)
        for template in design.templates.templates))
    for (scope, body, names) in bodies
        for primitive in body.primitives
            kind = typeof(primitive.kernel).parameters[1]
            contract = device_contract(kind)
            device_name = _name(names, primitive.name)
            if contract === nothing
                push!(diagnostics, Diagnostic(:error, "$(scope).$(device_name) has unsupported device kind $(kind)."))
                continue
            end
            terminal_count = length(body.terminal_data[primitive.terminals])
            terminal_count == contract.terminals || push!(diagnostics, Diagnostic(:error,
                "$(scope).$(device_name) ($(kind)) requires $(contract.terminals) terminals, but has $(terminal_count)."))
        end
    end
    any(diagnostic->diagnostic.severity===:error,diagnostics)&&return diagnostics,nothing,nothing
    topology,parameters = try
        _compile_hierarchy(design)
    catch error
        push!(diagnostics,Diagnostic(:error,sprint(showerror,error)))
        return diagnostics,nothing,nothing
    end
    net_count=topology.hierarchy.solver_net_count
    adjacency=[Int32[] for _ in 0:net_count]
    ideal_edges=Tuple{Int32,Int32,Float64,String}[]
    terminal(batch,index,device)=Int32(_batch_terminal(batch,index,device))
    for batch in parameters.batches, device in eachindex(batch.locators)
        kind=_batch_kind(batch); contract=device_contract(kind)
        if contract.dc_path
            indices = kind===:vcvs ? (3,4) : kind===:opamp ? (3,4,5) : Tuple(1:contract.terminals)
            nets=unique(terminal(batch,index,device) for index in indices)
            for first_net in nets,second_net in nets
                first_net==second_net||push!(adjacency[Int(first_net)+1],second_net)
            end
        end
        if kind===:voltage_source&&iszero(get(batch.parameters[device],:series_resistance,0.))
            instance_name,device_name=_locator_device_name(design,batch.locators[device])
            path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
            push!(ideal_edges,(terminal(batch,1,device),terminal(batch,2,device),Float64(get(batch.parameters[device],:dc,0.)),path))
        elseif kind===:inductor
            instance_name,device_name=_locator_device_name(design,batch.locators[device])
            path=isempty(instance_name) ? device_name : string(instance_name,'.',device_name)
            push!(ideal_edges,(terminal(batch,1,device),terminal(batch,2,device),0.,path))
        end
    end
    reachable=Set{Int32}((0,)); queue=Int32[0]
    while !isempty(queue)
        net=popfirst!(queue)
        for neighbor in adjacency[Int(net)+1]
            neighbor in reachable&&continue
            push!(reachable,neighbor); push!(queue,neighbor)
        end
    end
    if length(reachable)-1<net_count
        labels=_net_labels(design,topology)
        floating=sort!(String[first(get(labels,net,["net #$(net)"])) for net in Int32(1):Int32(net_count) if net ∉ reachable])
        shown=join(first(floating,min(8,length(floating))),", ")
        length(floating)>8&&(shown*=", …")
        push!(diagnostics,Diagnostic(:error,
            "Nets with no finite DC path to ground: $(shown). Capacitors and current sources do not establish an absolute DC potential; add a resistive bias path or another DC connection."))
    end

    voltage_graph=[Tuple{Int32,Float64,String}[] for _ in 0:net_count]
    parent=collect(Int32(0):Int32(net_count))
    root(net)=begin
        index=Int(net)+1
        while parent[index]!=net
            parent[index]=parent[Int(parent[index])+1]; net=parent[index]; index=Int(net)+1
        end
        net
    end
    for (positive,negative,value,path) in ideal_edges
        push!(voltage_graph[Int(positive)+1],(negative,-value,path))
        push!(voltage_graph[Int(negative)+1],(positive,value,path))
        first_root=root(positive); second_root=root(negative)
        if first_root==second_root
            push!(diagnostics,Diagnostic(:error,
                "An ideal voltage-constraint loop contains $(path). Add a finite series resistance."))
        else
            parent[Int(first_root)+1]=second_root
        end
    end
    potentials=Dict{Int32,Float64}()
    for start in Int32(0):Int32(net_count)
        haskey(potentials,start)&&continue
        potentials[start]=0.; pending=Int32[start]
        while !isempty(pending)
            net=popfirst!(pending)
            for (neighbor,offset,path) in voltage_graph[Int(net)+1]
                expected=potentials[net]+offset
                if !haskey(potentials,neighbor)
                    potentials[neighbor]=expected; push!(pending,neighbor)
                elseif !isapprox(potentials[neighbor],expected;atol=1e-12,rtol=1e-12)
                    message="Conflicting ideal voltage constraints form an inconsistent loop involving $(path)."
                    any(item->item.message==message,diagnostics)||push!(diagnostics,Diagnostic(:error,message))
                end
            end
        end
    end
    diagnostics,topology,parameters
end

"""Return structural and compiled-topology diagnostics for an immutable design."""
check(design::CircuitDesign)=first(_check_and_compile(design))

function explain(design::CircuitDesign)
    diagnostics = check(design)
    overview = summary(design)
    io = IOBuffer()
    println(io, "CircuitDesign $(overview.name): $(overview.nets) root nets, $(overview.instances) instances, $(overview.primitive_devices) primitive devices.")
    if isempty(diagnostics)
        println(io, "Structural check: no errors detected; the design is ready to compile.")
    else
        println(io, "Structural check: $(length(diagnostics)) issue(s) detected.")
        for diagnostic in diagnostics
            println(io, uppercase(String(diagnostic.severity)), ": ", diagnostic.message)
        end
    end
    chomp(String(take!(io)))
end

function _unknown_label(compiled, row::Integer)
    1 <= row <= compiled.n || return "residual row $(row)"
    layout = compiled.topology.layout
    kind = layout.kinds[row]
    if kind === NodeVoltageUnknown
        labels=get(_net_labels(compiled.design,compiled.topology),Int32(row),String[])
        return isempty(labels) ? "node-voltage equation $(row)" :
            "KCL at net $(join(unique(labels), " / ")) (equation $(row))"
    end
    locator = layout.locators[row]
    locator === nothing && return "residual row $(row)"
    instance_name, device_name = _locator_device_name(compiled.design, locator)
    path = isempty(instance_name) ? device_name : string(instance_name, '.', device_name)
    kind === BranchCurrentUnknown && return "I($(path))"
    state_name = something(layout.state_names[row], :state)
    "state($(path), $(state_name))"
end

explain_failure(error::Exception) = sprint(showerror, error)

function explain_failure(result)
    stats = result.stats
    converged = get(stats, :converged, false)
    io = IOBuffer()
    if converged
        iterations = get(stats, :iterations, nothing)
        print(io, "The simulation converged")
        iterations === nothing || print(io, " after $(iterations) nonlinear iteration(s)")
        rejected = get(stats, :rejected_steps, 0)
        rejected > 0 && print(io, "; adaptive stepping rejected $(rejected) trial step(s)")
        print(io, ".")
        return String(take!(io))
    end
    failed = get(stats, :failed_steps, Int[])
    if result isa SimulationResult && result.analysis isa Transient
        println(io, "The simulation did not converge. Returned values contain only accepted steps.")
        isempty(result.axis)||println(io,"Saved data ends at $(last(result.axis)) s; requested stop was $(last(result.analysis.interval)) s.")
    else
        println(io, "The simulation did not converge after $(get(stats, :iterations, "an unknown number of")) nonlinear iteration(s).")
    end
    for warning in get(stats,:warnings,String[])
        println(io,"- ",warning)
    end
    if any(w->occursin("max_steps",w),get(stats,:warnings,String[]))
        println(io,"The integration step budget was exhausted. Shorten the interval or increase IntegrationOptions(max_steps=...) after checking timestep and error settings.")
    end
    residuals = get(stats, :failed_residuals, Any[])
    isempty(residuals) && haskey(stats, :dominant_residual) && (residuals = [stats[:dominant_residual]])
    for (index, detail) in enumerate(residuals)
        prefix = index <= length(failed) ? "Step $(failed[index]): " : ""
        println(io, "- $(prefix)$(_unknown_label(result.compiled, detail.row)) dominated the residual (infinity norm $(detail.norm)).")
    end
    if isempty(residuals)
        println(io, "No per-equation residual was recorded. Inspect the design with describe(result.compiled.design).")
    else
        println(io, "Try a smaller maximum step, looser initial tolerances, realistic parasitics, or inspect the named device/node above.")
    end
    chomp(String(take!(io)))
end
