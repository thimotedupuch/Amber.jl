function sweep(c,p::Pair;analysis=OperatingPoint(),metric=identity)
    cc=compile(c); path=split(String(first(p)),'.')
    component_name=length(path)>1 ? Symbol(join(path[1:end-1],'.')) : Symbol(path[1])
    component=findfirst(x->x.name===component_name,cc.circuit.components)
    component===nothing&&throw(KeyError(first(p))); key=length(path)>1 ? Symbol(path[end]) : :value
    old=cc.circuit.components[component].parameters[key]
    try
        map(last(p)) do value
            cc.circuit.components[component].parameters[key]=value
            metric(simulate(cc,analysis))
        end
    finally
        cc.circuit.components[component].parameters[key]=old
    end
end
