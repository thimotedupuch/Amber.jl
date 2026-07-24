struct Diagnostic
    severity::Symbol
    message::String
end
Base.show(io::IO,d::Diagnostic)=print(io,d.message)

function check(c::Circuit)
    ds=Diagnostic[]; grounds=[n for n in c.nodes if n isa Ground]
    if isempty(grounds)
        push!(ds,Diagnostic(:error,"Circuit has no electrical reference. Add a ground to every electrical connected component."))
        return ds
    end
    adjacency=Dict{Int,Vector{Int}}(n.id=>Int[] for n in c.nodes); adjacency[0]=get(adjacency,0,Int[])
    dc_kinds=(:resistor,:conductance,:voltage_source,:inductor,:diode,:npn,:switch)
    for x in c.components
        if x.kind in dc_kinds
            ids=unique(n.id for n in x.terminals)
        elseif x.kind===:vcvs
            ids=unique(n.id for n in x.terminals[3:4])
        elseif x.kind===:ccvs
            ids=unique(n.id for n in x.terminals)
        elseif x.kind===:opamp
            ids=unique(n.id for n in x.terminals[3:5])
        else
            continue
        end
        for a in ids,b in ids; a==b||push!(get!(adjacency,a,Int[]),b) end
    end
    referenced=Set([0]); queue=[0]
    while !isempty(queue)
        a=popfirst!(queue)
        for b in get(adjacency,a,Int[])
            b in referenced&&continue; push!(referenced,b); push!(queue,b)
        end
    end
    floating=sort([n.name for n in c.nodes if n.id!=0&&!(n.id in referenced)];by=string)
    !isempty(floating)&&push!(ds,Diagnostic(:error,"Nodes $(join(string.(floating), ", ")) have no finite DC path to ground. Capacitors are open circuits and current sources do not establish an absolute potential at DC."))

    vadj=Dict{Int,Vector{Tuple{Int,Float64,Symbol}}}()
    for x in c.components
        x.kind===:voltage_source||continue; get(x.parameters,:series_resistance,0.)==0||continue
        a,b=x.terminals[1].id,x.terminals[2].id; v=Float64(get(x.parameters,:dc,0.))
        push!(get!(vadj,a,Tuple{Int,Float64,Symbol}[]),(b,-v,x.name))
        push!(get!(vadj,b,Tuple{Int,Float64,Symbol}[]),(a,v,x.name))
    end
    potentials=Dict{Int,Float64}(); via=Dict{Int,Symbol}()
    for root in keys(vadj)
        haskey(potentials,root)&&continue; potentials[root]=0.; queue=[root]
        while !isempty(queue)
            a=popfirst!(queue)
            for (b,offset,name) in get(vadj,a,Tuple{Int,Float64,Symbol}[])
                expected=potentials[a]+offset
                if !haskey(potentials,b)
                    potentials[b]=expected; via[b]=name; push!(queue,b)
                elseif !isapprox(potentials[b],expected;atol=1e-12,rtol=1e-12)
                    other=get(via,b,name)
                    msg="Conflicting ideal voltage constraints form an inconsistent loop involving $(other) and $(name). The loop requires both $(potentials[b]) V and $(expected) V at the same node."
                    any(d->d.message==msg,ds)||push!(ds,Diagnostic(:error,msg))
                end
            end
        end
    end

    # Even a numerically consistent closed loop of ideal voltage constraints
    # leaves one or more branch currents undetermined.
    parent=Dict(node.id=>node.id for node in c.nodes); parent[0]=0
    function root(node)
        current=node
        while parent[current]!=current
            parent[current]=parent[parent[current]]; current=parent[current]
        end
        current
    end
    for component in c.components
        ideal_source=component.kind===:voltage_source&&get(component.parameters,:series_resistance,0.)==0
        (ideal_source||component.kind===:inductor)||continue
        a,b=component.terminals[1].id,component.terminals[2].id; ra,rb=root(a),root(b)
        if ra==rb
            push!(ds,Diagnostic(:error,"An ideal voltage-constraint loop contains $(component.name). Ideal voltage sources and inductors in a closed loop leave branch currents undetermined; add a finite series resistance."))
        else
            parent[ra]=rb
        end
    end
    ds
end

function describe(c::Circuit)
    io=IOBuffer(); println(io,"Circuit: ",c.name); println(io,"Nodes: ",length(c.nodes)); println(io,"Components: ",length(c.components))
    for n in c.nodes; println(io,n.name,": ",join([x.name for x in c.components if n in x.terminals],", ")) end
    String(take!(io))
end
