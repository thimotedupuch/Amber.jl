abstract type AbstractNode end

struct Node <: AbstractNode
    circuit::Any
    id::Int
    name::Symbol
end

struct Ground <: AbstractNode
    circuit::Any
    id::Int
    name::Symbol
end

struct Observable
    kind::Symbol
    target::Any
    extra::Any
end

voltage(n::AbstractNode)=Observable(:voltage,n,nothing)
voltage(a::AbstractNode,b::AbstractNode)=Observable(:voltage,a,b)
voltage(name::Union{Symbol,String})=Observable(:voltage,name,nothing)
current(x,branch=nothing)=Observable(:current,x,branch)
power(x)=Observable(:power,x,nothing)
charge(x)=Observable(:charge,x,nothing)
state(x,s)=Observable(:state,x,s)
