function _parameter_at(batches,location::ParameterLocation)
    batch=batches[location.batch]; parameters=batch.parameters[location.device]
    if hasproperty(parameters,location.field)
        return getproperty(parameters,location.field)
    end
    model=get(parameters,:model,nothing)
    model === nothing && throw(ArgumentError("parameter dependency references an unknown field"))
    return getproperty(model_parameters(model),location.field)
end
function _parameter_graph_order(rules)
    nodes=ParameterLocation[]; ids=Dict{ParameterLocation,Int}()
    for rule in rules, node in (rule.source,rule.target)
        haskey(ids,node) || (push!(nodes,node);ids[node]=length(nodes))
    end
    incoming=zeros(Int,length(nodes)); outgoing=[Int[] for _ in nodes]
    targets=Set{ParameterLocation}()
    for (index,rule) in enumerate(rules)
        rule.target in targets && throw(ArgumentError("multiple parameter rules write the same target"))
        push!(targets,rule.target)
        incoming[ids[rule.target]]+=1; push!(outgoing[ids[rule.source]],index)
    end
    queue=findall(iszero,incoming); order=Int[]; head=1
    while head <= length(queue)
        node=queue[head];head+=1
        for index in outgoing[node]
            push!(order,index); target=ids[rules[index].target]
            incoming[target]-=1
            iszero(incoming[target]) && push!(queue,target)
        end
    end
    length(order) == length(rules) || throw(ArgumentError("parameter dependency cycle"))
    return order
end
function _validate_parameter_spec(spec,primitive_count)
    1 <= spec.source <= primitive_count && 1 <= spec.target <= primitive_count ||
        throw(ArgumentError("parameter dependency references an unknown primitive"))
    spec.operation in (:affine,:inverse,:calibrated_loss,:rebuild) || throw(ArgumentError("unknown parameter dependency operation"))
    all(isfinite,(spec.scale,spec.offset,spec.divisor)) && spec.divisor > 0 ||
        throw(ArgumentError("invalid parameter dependency coefficients"))
    return nothing
end
function _build_parameter_graph(design,batches)
    isempty(design.root_ir.parameter_relations) && all(t -> isempty(t.body.parameter_relations),design.templates.templates) &&
        return ParameterDependencyGraph()
    locations=Dict{Tuple{UInt32,UInt32,Int32},Tuple{Int,Int}}()
    for (batch_index,batch) in enumerate(batches), (device,locator) in enumerate(batch.locators)
        locations[(locator.instance.value,locator.template.value,locator.primitive)]=(batch_index,device)
    end
    rules=CompiledParameterRule[]; rebuild_sources=Set{ParameterLocation}()
    function add_body(body,instance,template)
        for spec in body.parameter_relations
            _validate_parameter_spec(spec,length(body.primitives))
            source=locations[(instance,template,spec.source)]; target=locations[(instance,template,spec.target)]
            rule=CompiledParameterRule(ParameterLocation(source...,spec.source_field),
                ParameterLocation(target...,spec.target_field),spec)
            for location in (rule.source,rule.target)
                value=_parameter_at(batches,location)
                value isa Real && isfinite(value) || throw(ArgumentError("parameter dependencies require finite real fields"))
            end
            if spec.operation === :rebuild
                push!(rebuild_sources,rule.source)
            else
                expected=_derived_parameter_value(rule,_parameter_at(batches,rule.source))
                actual=_parameter_at(batches,rule.target)
                represented=convert(typeof(actual),expected)
                isapprox(actual,represented;rtol=64eps(Float64),atol=0) ||
                    throw(ArgumentError("initial derived parameter does not satisfy its retained formula"))
                push!(rules,rule)
            end
        end
    end
    add_body(design.root_ir,UInt32(0),UInt32(0))
    for (index,record) in enumerate(design.root.records)
        add_body(design.templates.templates[Int(record.template)].body,UInt32(index),record.template.value)
    end
    _validate_expansion_coverage!(rebuild_sources,rules,batches)
    order=_parameter_graph_order(rules); ranks=zeros(Int,length(rules))
    outgoing=Dict{ParameterLocation,Vector{Int}}()
    for (rank,index) in enumerate(order)
        ranks[index]=rank
        push!(get!(()->Int[],outgoing,rules[index].source),index)
    end
    return ParameterDependencyGraph(rules,order,
        Set(rule.source for rule in rules),Set(rule.target for rule in rules),rebuild_sources,outgoing,ranks)
end
function _validate_expansion_coverage!(rebuild_sources,rules,batches)
    by_source=Dict{ParameterLocation,Vector{CompiledParameterRule}}()
    for rule in rules
        push!(get!(()->CompiledParameterRule[],by_source,rule.source),rule)
    end
    for (batch_index,batch) in enumerate(batches)
        _batch_kind(batch) === :capacitor || continue
        for device in eachindex(batch.parameters)
            parameters=batch.parameters[device]
            _capacitance_has_derived_elements(parameters) || continue
            source=ParameterLocation(batch_index,device,:value)
            expected=Set{Symbol}()
            dielectric=get(parameters,:dielectric,nothing)
            dielectric isa AbstractCapacitorDielectric && dielectric.loss_tangent > 0 && push!(expected,:loss)
            absorption=get(parameters,:dielectric_absorption,nothing)
            if absorption isa DebyeBranches
                for (index,fraction) in enumerate(absorption.fractions)
                    fraction > 0 || continue
                    push!(expected,Symbol(:da_resistor_,index)); push!(expected,Symbol(:da_capacitor_,index))
                end
            end
            seen=Set{Symbol}()
            for rule in get(by_source,source,CompiledParameterRule[])
                role=rule.specification.role
                role === :generic && continue
                role in seen && throw(ArgumentError("duplicate physical expansion role"))
                push!(seen,role)
                role in expected || throw(ArgumentError("unknown physical expansion role"))
                rule.target.field === :value || throw(ArgumentError("physical expansion must bind a value field"))
                target_kind=_batch_kind(batches[rule.target.batch]); spec=rule.specification
                if role === :loss
                    target_kind === :resistor && spec.operation === :calibrated_loss &&
                        spec.scale == dielectric.loss_tangent && spec.divisor == dielectric.reference_frequency ||
                        throw(ArgumentError("invalid dielectric loss dependency"))
                else
                    index=findfirst(i -> role in (Symbol(:da_resistor_,i),Symbol(:da_capacitor_,i)),eachindex(absorption.fractions))
                    fraction=absorption.fractions[index]
                    if role === Symbol(:da_resistor_,index)
                        target_kind === :resistor && spec.operation === :inverse && spec.scale == absorption.time_constants[index] &&
                            spec.divisor == fraction && iszero(spec.offset) || throw(ArgumentError("invalid absorption resistance dependency"))
                    else
                        target_kind === :capacitor && spec.operation === :affine && spec.scale == fraction && iszero(spec.offset) ||
                            throw(ArgumentError("invalid absorption capacitance dependency"))
                    end
                end
            end
            issubset(expected,seen) || push!(rebuild_sources,source)
        end
    end
    return nothing
end
function _derived_parameter_value(rule,source)
    value=Float64(source); spec=rule.specification
    isfinite(value) || throw(ArgumentError("nonfinite source for derived parameter"))
    if spec.operation in (:inverse,:calibrated_loss)
        value > 0 || throw(ArgumentError("inverse parameter dependency requires positive source"))
        value=spec.offset+spec.scale/(spec.operation === :calibrated_loss ? 2pi*spec.divisor*value : spec.divisor*value)
    else
        value=spec.offset+spec.scale*value
    end
    isfinite(value) || throw(ArgumentError("derived parameter is nonfinite"))
    return value
end
function _propagate_parameter_graph!(batches,design,graph,changed,touched,matrix_changed)
    scheduled=Set{Int}(); queue=collect(changed); head=1
    while head <= length(queue)
        source=queue[head];head+=1
        outgoing=get(graph.outgoing,source,nothing)
        outgoing === nothing && continue
        for index in outgoing
            index in scheduled && continue
            push!(scheduled,index); push!(queue,graph.rules[index].target)
        end
    end
    for index in sort!(collect(scheduled);by=i->graph.ranks[i])
        rule=graph.rules[index]
        source=_parameter_at(batches,rule.source)
        _batch_kind(batches[rule.source.batch]) === :capacitor && rule.source.field === :value && source <= 0 &&
            throw(ArgumentError("derived capacitance source must remain positive"))
        value=_derived_parameter_value(rule,source)
        target=rule.target; kind=_batch_kind(batches[target.batch])
        target in graph.rebuild_sources && throw(TopologyParameterError(
            _parameter_device_path(design,batches[target.batch].locators[target.device]),target.field))
        target.field === :value && kind in (:resistor,:capacitor,:inductor) && value <= 0 &&
            throw(ArgumentError("derived passive value must remain positive"))
        batches[target.batch]=_updated_batch(batches[target.batch],design,target.field,[target.device],value;
            owned=touched[target.batch],allow_derived=target in graph.sources)
        touched[target.batch]=true; matrix_changed[target.batch]=true
        push!(changed,target)
    end
    return nothing
end
"""Inspect retained parameter formulas, using hierarchy-qualified device fields."""
function parameter_dependencies(circuit)
    cc=compile(circuit)
    result=[begin
        source=cc.parameters.batches[rule.source.batch].locators[rule.source.device]
        target=cc.parameters.batches[rule.target.batch].locators[rule.target.device]
        spec=rule.specification
        (;source=string(_parameter_device_path(cc.design,source),'.',rule.source.field),
            target=string(_parameter_device_path(cc.design,target),'.',rule.target.field),
            operation=spec.operation,scale=spec.scale,offset=spec.offset,divisor=spec.divisor)
    end for rule in cc.parameters.dependency_graph.rules]
    for location in sort!(collect(cc.parameters.dependency_graph.rebuild_sources);by=x->(x.batch,x.device,String(x.field)))
        locator=cc.parameters.batches[location.batch].locators[location.device]
        path=string(_parameter_device_path(cc.design,locator),'.',location.field)
        push!(result,(;source=path,target=path,operation=:rebuild,scale=0.0,offset=0.0,divisor=1.0))
    end
    return result
end
