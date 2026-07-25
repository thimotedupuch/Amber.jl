Base.@kwdef struct MatchedGroup
    name::Symbol
    sigma_vbe::Float64=0.
    sigma_log_beta::Float64=0.
    correlation::Float64=0.
end
matched_group(name::Symbol;kw...)=MatchedGroup(;name,kw...)

struct Differential
    positive::Symbol
    negative::Symbol
end

mutable struct Component
    kind::Symbol
    terminals::Vector{AbstractNode}
    parameters::Dict{Symbol,Any}
    name::Symbol
end

mutable struct Circuit
    name::Symbol
    nodes::Vector{AbstractNode}
    components::Vector{Component}
    observations::Vector{Any}
    metadata::Dict{Symbol,Any}
end

Circuit(name::Symbol=:anonymous)=Circuit(name,AbstractNode[],Component[],Any[],Dict{Symbol,Any}())
circuit(f::Function,name::Symbol=:anonymous)=f(Circuit(name))
circuit(name::Symbol,f::Function)=f(Circuit(name))

function _unique_name(existing,name::Symbol)
    all(!=(name),existing)&&return name
    suffix=2
    while Symbol(name,suffix) in existing; suffix+=1 end
    Symbol(name,suffix)
end

function node!(c::Circuit,name::Symbol=Symbol(:n,length(c.nodes)+1))
    name=_unique_name(map(node->node.name,c.nodes),name)
    id=maximum((n.id for n in c.nodes);init=0)+1
    n=Node(c,id,name); push!(c.nodes,n); n
end
function ground!(c::Circuit,name::Symbol=:gnd)
    name=_unique_name(map(node->node.name,c.nodes),name)
    n=Ground(c,0,name); push!(c.nodes,n); n
end
node()=error("node() is available inside @circuit; use node!(c, name) in builder code")
ground()=error("ground() is available inside @circuit; use ground!(c, name) in builder code")

function add!(c::Circuit,x::Component;name::Symbol=Symbol(x.kind,length(c.components)+1))
    x.name=name
    if x.kind===:resistor
        _elaborate_resistor!(c,x,name)
    elseif x.kind===:capacitor
        _elaborate_capacitor!(c,x,name)
    elseif x.kind===:inductor
        _elaborate_inductor!(c,x,name)
    elseif x.kind===:diode
        _elaborate_diode!(c,x,name)
    elseif x.kind===:npn
        _elaborate_bjt!(c,x,name)
    elseif x.kind===:switch
        _elaborate_switch!(c,x,name)
    elseif x.kind===:opamp
        _elaborate_opamp!(c,x,name)
    else
        push!(c.components,x)
    end
    x
end

_model_value(model,key,default=0.)=model===nothing ? default : get(model.data,key,default)
_hidden_component!(c,kind,terminals,parameters,name)=push!(c.components,Component(kind,AbstractNode[terminals...],Dict{Symbol,Any}(parameters),name))

function _elaborate_resistor!(c,x,name)
    p,n=x.terminals; package=get(x.parameters,:package,nothing)
    series_inductance=_model_value(package,:series_inductance)
    parallel_capacitance=_model_value(package,:parallel_capacitance)
    if series_inductance>0
        internal=node!(c,Symbol(name,".__series")); x.terminals=AbstractNode[p,internal]
        push!(c.components,x)
        _hidden_component!(c,:inductor,(internal,n),(:value=>series_inductance,),Symbol(name,".package_inductance"))
    else
        push!(c.components,x)
    end
    parallel_capacitance>0&&_hidden_component!(c,:capacitor,(p,n),(:value=>parallel_capacitance,),Symbol(name,".package_capacitance"))
end

function _elaborate_capacitor!(c,x,name)
    external_p,external_n=x.terminals; package=get(x.parameters,:package,nothing)
    esr=Float64(get(x.parameters,:esr,_model_value(package,:esr)))
    esl=Float64(get(x.parameters,:esl,_model_value(package,:esl)))
    terminal=external_p
    if esr>0
        next=node!(c,Symbol(name,".__esr"))
        _hidden_component!(c,:resistor,(terminal,next),(:value=>esr,),Symbol(name,".esr")); terminal=next
    end
    if esl>0
        next=node!(c,Symbol(name,".__esl"))
        _hidden_component!(c,:inductor,(terminal,next),(:value=>esl,),Symbol(name,".esl")); terminal=next
    end
    x.parameters[:external_terminals]=(external_p,external_n)
    x.terminals=AbstractNode[terminal,external_n]; push!(c.components,x)
    absorption=get(x.parameters,:dielectric_absorption,nothing)
    if absorption isa DebyeBranches
        length(absorption.time_constants)==length(absorption.fractions)||throw(ArgumentError("Debye time_constants and fractions must have equal lengths"))
        for (index,(time_constant,fraction)) in enumerate(zip(absorption.time_constants,absorption.fractions))
            fraction>0||continue; branch_capacitance=Float64(x.parameters[:value])*fraction
            branch_node=node!(c,Symbol(name,".__da",index)); resistance=time_constant/branch_capacitance
            _hidden_component!(c,:resistor,(terminal,branch_node),(:value=>resistance,),Symbol(name,".da",index,"_resistor"))
            _hidden_component!(c,:capacitor,(branch_node,external_n),(:value=>branch_capacitance,),Symbol(name,".da",index,"_capacitor"))
        end
    end
end

function _elaborate_inductor!(c,x,name)
    p,n=x.terminals; resistance=Float64(get(x.parameters,:winding_resistance,get(x.parameters,:series_resistance,0.)))
    parallel_capacitance=Float64(get(x.parameters,:parallel_capacitance,0.))
    if resistance>0
        internal=node!(c,Symbol(name,".__winding")); x.parameters[:external_terminals]=(p,n); x.terminals=AbstractNode[p,internal]
        push!(c.components,x)
        _hidden_component!(c,:resistor,(internal,n),(:value=>resistance,),Symbol(name,".winding_resistance"))
    else
        push!(c.components,x)
    end
    parallel_capacitance>0&&_hidden_component!(c,:capacitor,(p,n),(:value=>parallel_capacitance,),Symbol(name,".parallel_capacitance"))
end

function _elaborate_diode!(c,x,name)
    p,n=x.terminals; resistance=Float64(x.parameters[:model].series_resistance)
    if resistance>0
        internal=node!(c,Symbol(name,".__series")); x.parameters[:external_terminals]=(p,n); x.terminals=AbstractNode[internal,n]
        _hidden_component!(c,:resistor,(p,internal),(:value=>resistance,),Symbol(name,".series_resistance"))
    end
    push!(c.components,x)
end

function _elaborate_bjt!(c,x,name)
    collector,base,emitter=x.terminals; resistance=Float64(x.parameters[:model].base_resistance)
    if resistance>0
        internal=node!(c,Symbol(name,".__base")); x.parameters[:external_terminals]=(collector,base,emitter); x.terminals=AbstractNode[collector,internal,emitter]
        _hidden_component!(c,:resistor,(base,internal),(:value=>resistance,),Symbol(name,".base_resistance"))
    end
    push!(c.components,x)
end

function _elaborate_switch!(c,x,name)
    push!(c.components,x); model=x.parameters[:model]
    model.clock_feedthrough>0&&_hidden_component!(c,:capacitor,(x.terminals[3],x.terminals[2]),(:value=>model.clock_feedthrough,),Symbol(name,".clock_feedthrough"))
end

function _elaborate_opamp!(c,x,name)
    push!(c.components,x); model=x.parameters[:model]; positive,negative,_,_,negative_rail=x.terminals
    model.input_capacitance>0&&_hidden_component!(c,:capacitor,(positive,negative),(:value=>model.input_capacitance,),Symbol(name,".input_capacitance"))
    if model.input_bias_current!=0
        _hidden_component!(c,:current_source,(positive,negative_rail),(:dc=>model.input_bias_current,:ac=>0.,:waveform=>nothing),Symbol(name,".positive_bias_current"))
        _hidden_component!(c,:current_source,(negative,negative_rail),(:dc=>model.input_bias_current,:ac=>0.,:waveform=>nothing),Symbol(name,".negative_bias_current"))
    end
end

function _attach!(parent::Circuit,child::Circuit;name::Symbol=child.name)
    nodemap=IdDict{Any,AbstractNode}()
    for n in child.nodes
        if n isa Ground
            existing=findfirst(x->x isa Ground,parent.nodes)
            mapped=existing===nothing ? ground!(parent,Symbol(name,".",n.name)) : parent.nodes[existing]
        else
            mapped=node!(parent,Symbol(name,".",n.name))
        end
        nodemap[n]=mapped
    end
    componentmap=IdDict{Any,Component}()
    for x in child.components
        terminals=AbstractNode[get(nodemap,n,n) for n in x.terminals]
        parameters=Dict{Symbol,Any}(key=>(key===:control&&value isa Symbol ? Symbol(name,".",value) : _remap_parameter(value,nodemap)) for (key,value) in x.parameters)
        copied=Component(x.kind,terminals,parameters,Symbol(name,".",x.name))
        push!(parent.components,copied); componentmap[x]=copied
    end
    for o in child.observations
        if o isa Observable
            target=o.target isa AbstractNode ? get(nodemap,o.target,o.target) : o.target isa Component ? get(componentmap,o.target,o.target) : o.target
            extra=o.extra isa AbstractNode ? get(nodemap,o.extra,o.extra) : o.extra
            push!(parent.observations,Observable(o.kind,target,extra))
        else
            push!(parent.observations,o)
        end
    end
    for (alias,o) in get(child.metadata,:named_observations,Dict{Symbol,Any}())
        target=o.target isa AbstractNode ? get(nodemap,o.target,o.target) : o.target isa Component ? get(componentmap,o.target,o.target) : o.target
        extra=o.extra isa AbstractNode ? get(nodemap,o.extra,o.extra) : o.extra
        get!(parent.metadata,:named_observations,Dict{Symbol,Any}())[Symbol(name,".",alias)]=Observable(o.kind,target,extra)
    end
    for (port,terminal) in get(child.metadata,:ports,Dict{Symbol,Any}())
        mapped=terminal isa AbstractNode ? get(nodemap,terminal,terminal) : terminal
        mapped isa AbstractNode||continue
        get!(parent.metadata,:named_observations,Dict{Symbol,Any}())[Symbol(name,".",port)]=voltage(mapped)
    end
    child.metadata[:instance_path]=name
    child
end
_attach!(::Circuit,x;name=:value)=x
_remap_parameter(value,nodemap)=value
_remap_parameter(value::AbstractNode,nodemap)=get(nodemap,value,value)
_remap_parameter(value::Tuple,nodemap)=map(item->_remap_parameter(item,nodemap),value)

function observe!(c::Circuit,xs...;name=nothing)
    normalized=map(x->x isa AbstractNode ? voltage(x) : x,xs)
    append!(c.observations,normalized)
    if name!==nothing
        length(normalized)==1||throw(ArgumentError("a named observation must contain exactly one signal"))
        get!(c.metadata,:named_observations,Dict{Symbol,Any}())[Symbol(name)]=first(normalized)
    end
    isempty(normalized) ? c : last(normalized)
end
observe(args...)=error("observe is available inside @circuit; use observe!(c, ...) in builder code")
initial_voltage(x::Component,v)=(x.parameters[:initial_voltage]=v;x)

function _macro_rewrite(ex,c)
    ex isa Expr||return ex
    if ex.head===:(=)&&ex.args[1] isa Symbol&&ex.args[2] isa Expr&&ex.args[2].head===:call
        name=ex.args[1]; call=ex.args[2]; f=call.args[1]
        f===:node&&return :($name=node!($c,$(QuoteNode(name))))
        f===:ground&&return :($name=ground!($c,$(QuoteNode(name))))
        if f in (:resistor,:capacitor,:inductor,:conductance,:voltage_source,:current_source,:transconductance,:voltage_controlled_voltage_source,:current_controlled_current_source,:current_controlled_voltage_source,:diode,:npn,:nmos,:pmos,:opamp,:analog_switch)
            return :($name=add!($c,$call;name=$(QuoteNode(name))))
        end
        attach=GlobalRef(@__MODULE__,:_attach!)
        return :($name=$attach($c,$call;name=$(QuoteNode(name))))
    elseif ex.head===:call&&ex.args[1]===:observe
        return Expr(:call,:observe!,c,ex.args[2:end]...)
    elseif ex.head===:call&&ex.args[1] in (:resistor,:capacitor,:inductor,:conductance,:voltage_source,:current_source,:transconductance,:voltage_controlled_voltage_source,:current_controlled_current_source,:current_controlled_voltage_source,:diode,:npn,:nmos,:pmos,:opamp,:analog_switch)
        return :(add!($c,$ex))
    elseif ex.head===:call
        attach=GlobalRef(@__MODULE__,:_attach!)
        return :($attach($c,$ex))
    elseif ex.head===:block
        return Expr(:block,map(x->_macro_rewrite(x,c),ex.args)...)
    elseif ex.head===:for
        return Expr(:for,ex.args[1],_macro_rewrite(ex.args[2],c))
    elseif ex.head===:while
        return Expr(:while,ex.args[1],_macro_rewrite(ex.args[2],c))
    elseif ex.head===:if
        return Expr(:if,ex.args[1],map(x->_macro_rewrite(x,c),ex.args[2:end])...)
    elseif ex.head===:let
        return Expr(:let,ex.args[1:end-1]...,_macro_rewrite(ex.args[end],c))
    end
    ex
end

macro circuit(sig,block)
    c=gensym(:c); body=_macro_rewrite(block,c)
    name=sig isa Symbol ? Expr(:call,sig) : sig
    circuit_name=name.args[1]
    ports=Symbol[]
    for argument in name.args[2:end]
        argument isa Expr&&argument.head===:parameters&&continue
        port=argument isa Symbol ? argument : argument isa Expr&&argument.head===:(::) ? argument.args[1] : nothing
        port isa Symbol&&push!(ports,port)
    end
    port_entries=[:($(QuoteNode(port))=>$port) for port in ports]
    fnbody=quote
        $c=Circuit($(QuoteNode(circuit_name)))
        $c.metadata[:ports]=Dict{Symbol,Any}($(port_entries...))
        $body
        $c
    end
    esc(Expr(:function,name,fnbody))
end
