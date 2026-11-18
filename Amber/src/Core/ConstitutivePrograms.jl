# Experimental instruction DAG for constitutive expressions. Neither node count
# nor graph shape appears in the executable/workspace type.
@enum ConstitutiveOpcode::UInt8 begin
    EquationConstant
    EquationVariable
    EquationAdd
    EquationSubtract
    EquationMultiply
    EquationDivide
    EquationExp
    EquationLog1p
    EquationPower
    EquationPositive
end
struct ConstitutiveInstruction
    opcode::ConstitutiveOpcode
    arguments::NTuple{3,Int32}
    literal::Float64
    input::Symbol
end
struct ConstitutiveRequest
    quantity::Symbol
    variables::Tuple{Vararg{Symbol}}
    function ConstitutiveRequest(quantity::Symbol,variables::Tuple{Vararg{Symbol}}=())
        quantity in (:current,:charge) || throw(ArgumentError("request must target current or charge"))
        new(quantity,variables)
    end
end
struct ConstitutiveProgram
    instructions::Vector{ConstitutiveInstruction}
    roots::Vector{Int32}
    requests::Vector{ConstitutiveRequest}
    input_names::Vector{Symbol}
    input_slots::Vector{Int32}
end
const _EquationInstructionKey = Tuple{ConstitutiveOpcode,NTuple{3,Int32},UInt64,Symbol}
function _intern_equation!(instructions,lookup,opcode,arguments,literal,input,max_nodes)
    key=(opcode,arguments,reinterpret(UInt64,literal),input)
    haskey(lookup,key) && return lookup[key]
    length(instructions) < max_nodes || throw(ArgumentError("constitutive program node budget exceeded"))
    push!(instructions,ConstitutiveInstruction(opcode,arguments,literal,input))
    index=Int32(length(instructions)); lookup[key]=index
    return index
end
function _lower_equation!(instructions,lookup,expression::ConstitutiveExpr,max_nodes)
    Base.@nospecialize expression
    # Postorder traversal is iterative and deliberately type-erased at compile
    # time too; nested expression types must not cause circuit-wide codegen.
    stack=Tuple{ConstitutiveExpr,Int}[(expression,0)]; values=Int32[]; work=0
    while !isempty(stack)
        node,phase=pop!(stack); work+=1
        work <= 20max_nodes || throw(ArgumentError("constitutive expression traversal budget exceeded"))
        if node isa EquationLiteral
            node.value isa Real || throw(ArgumentError("constitutive literals must be real"))
            value=Float64(node.value)
            isfinite(value) && value == node.value ||
                throw(ArgumentError("literal must be exactly representable as finite Float64"))
            push!(values,_intern_equation!(instructions,lookup,EquationConstant,(Int32(0),Int32(0),Int32(0)),value,:_,max_nodes))
        elseif node isa EquationInput
            name=typeof(node).parameters[1]
            name isa Symbol || throw(ArgumentError("equation inputs must use Symbol names"))
            push!(values,_intern_equation!(instructions,lookup,EquationVariable,(Int32(0),Int32(0),Int32(0)),0.0,name,max_nodes))
        elseif node isa EquationCall
            arguments=node.arguments
            if phase == 0
                push!(stack,(node,1))
                for child in reverse(arguments)
                    push!(stack,(child,0))
                end
                continue
            end
            operation=typeof(node).parameters[1]
            opcode=operation === :+ ? EquationAdd : operation === :- ? EquationSubtract :
                operation === :* ? EquationMultiply : operation === :/ ? EquationDivide :
                operation === :exp ? EquationExp : operation === :log1p ? EquationLog1p :
                operation === :power ? EquationPower : operation === :positive ? EquationPositive :
                throw(ArgumentError("unsupported constitutive operation $operation"))
            count=length(arguments)
            expected=opcode in (EquationExp,EquationLog1p) ? 1 : opcode === EquationPositive ? 3 : 2
            count == expected || throw(ArgumentError("invalid constitutive operation arity"))
            slots=ntuple(i -> i <= count ? values[length(values)-count+i] : Int32(0),3)
            resize!(values,length(values)-count)
            push!(values,_intern_equation!(instructions,lookup,opcode,slots,0.0,:_,max_nodes))
        else
            throw(ArgumentError("unsupported constitutive expression"))
        end
    end
    return only(values)
end
function compile_constitutive(law::ConstitutiveLaw;
        requests=[ConstitutiveRequest(:current),ConstitutiveRequest(:charge)],max_nodes=100000)
    Base.@nospecialize law
    max_nodes isa Integer && 0 < max_nodes <= div(typemax(Int32),20) || throw(ArgumentError("invalid constitutive node budget"))
    instructions=ConstitutiveInstruction[]; lookup=Dict{_EquationInstructionKey,Int32}(); roots=Int32[]
    saved=ConstitutiveRequest[requests...]
    for request in saved
        expression=getfield(law,request.quantity)
        for variable in request.variables
            expression=_equation_derivative(expression,Val(variable))
        end
        push!(roots,_lower_equation!(instructions,lookup,expression,max_nodes))
    end
    names=Symbol[]; slots=zeros(Int32,length(instructions))
    for (index,node) in enumerate(instructions)
        node.opcode === EquationVariable || continue
        push!(names,node.input); slots[index]=Int32(length(names))
    end
    return ConstitutiveProgram(instructions,roots,saved,names,slots)
end
mutable struct ConstitutiveWorkspace
    program::ConstitutiveProgram
    values::Vector{Float64}
    stamps::Vector{UInt64}
    epoch::UInt64
    stack::Vector{Int32}
    evaluated_nodes::Int
end
ConstitutiveWorkspace(program::ConstitutiveProgram) = ConstitutiveWorkspace(program,
    zeros(length(program.instructions)),zeros(UInt64,length(program.instructions)),UInt64(0),Int32[],0)
function _constitutive_input(inputs::NamedTuple,name,slot)
    hasproperty(inputs,name) || throw(ArgumentError("missing constitutive input $name"))
    return Float64(getproperty(inputs,name))
end
_constitutive_input(inputs::AbstractVector,name,slot) = Float64(inputs[slot])
function _constitutive_node!(workspace,program,root,inputs)
    stack=workspace.stack; empty!(stack); push!(stack,root)
    values=workspace.values; stamps=workspace.stamps; epoch=workspace.epoch
    while !isempty(stack)
        index=last(stack)
        if stamps[index] == epoch
            pop!(stack); continue
        end
        node=program.instructions[index]; op=node.opcode; args=node.arguments
        if op === EquationConstant
            value=node.literal
        elseif op === EquationVariable
            value=_constitutive_input(inputs,node.input,program.input_slots[index])
        elseif op === EquationPositive
            if stamps[args[1]] != epoch
                push!(stack,args[1]); continue
            end
            selected=values[args[1]] > 0 ? args[2] : args[3]
            if stamps[selected] != epoch
                push!(stack,selected); continue
            end
            value=values[selected]
        else
            count=op in (EquationExp,EquationLog1p) ? 1 : 2
            missing=Int32(0)
            for i in 1:count
                if stamps[args[i]] != epoch
                    missing=args[i]; break
                end
            end
            if !iszero(missing)
                push!(stack,missing); continue
            end
            a=values[args[1]]
            value=op === EquationExp ? exp(a) : op === EquationLog1p ? log1p(a) : begin
                b=values[args[2]]
                op === EquationAdd ? a+b : op === EquationSubtract ? a-b :
                op === EquationMultiply ? a*b : op === EquationDivide ? a/b : a^b
            end
        end
        isfinite(value) || throw(ArgumentError("nonfinite constitutive program value"))
        values[index]=value; stamps[index]=epoch; workspace.evaluated_nodes+=1
        pop!(stack)
    end
    return values[root]
end
_constitutive_scratch_alias(array,workspace) = Base.mightalias(array,workspace.values) ||
    Base.mightalias(array,workspace.stamps) || Base.mightalias(array,workspace.stack)
"""Evaluate requested DAG roots, sharing intermediates and preserving lazy branches.

Each call advances an epoch; no values survive into another input snapshot.
Unrequested outputs and unselected branches are not evaluated. Destination order
matches `outputs`, whose entries index the program's request list. Vector inputs
use `program.input_names` order; inputs, destination and scratch must not alias.
"""
function evaluate_constitutive!(destination::AbstractVector,workspace::ConstitutiveWorkspace,
        program::ConstitutiveProgram,inputs::Union{NamedTuple,AbstractVector};outputs=eachindex(program.roots))
    Base.require_one_based_indexing(destination)
    inputs isa AbstractVector && Base.require_one_based_indexing(inputs)
    inputs isa AbstractVector && length(inputs) != length(program.input_names) &&
        throw(DimensionMismatch("constitutive input vector must match program.input_names"))
    workspace.program === program || throw(ArgumentError("constitutive workspace belongs to another program"))
    _constitutive_scratch_alias(destination,workspace) && throw(ArgumentError("destination aliases constitutive scratch"))
    any(array -> Base.mightalias(destination,array),(program.roots,program.input_slots,program.instructions)) &&
        throw(ArgumentError("destination aliases constitutive program storage"))
    if inputs isa AbstractVector
        (Base.mightalias(destination,inputs) || _constitutive_scratch_alias(inputs,workspace)) &&
            throw(ArgumentError("constitutive input/output/scratch buffers must not alias"))
    end
    if outputs isa AbstractVector
        (Base.mightalias(destination,outputs) || _constitutive_scratch_alias(outputs,workspace)) &&
            throw(ArgumentError("constitutive output indices alias writable buffers"))
    end
    length(destination) == length(outputs) || throw(DimensionMismatch("constitutive destination length"))
    all(i -> i isa Integer && 1 <= i <= length(program.roots),outputs) || throw(ArgumentError("invalid constitutive output index"))
    if workspace.epoch == typemax(UInt64)
        fill!(workspace.stamps,0); workspace.epoch=UInt64(1)
    else
        workspace.epoch+=UInt64(1)
    end
    workspace.evaluated_nodes=0
    for (index,output) in enumerate(outputs)
        destination[index]=_constitutive_node!(workspace,program,program.roots[output],inputs)
    end
    return destination
end
