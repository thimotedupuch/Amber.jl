struct Diagnostic
    severity::Symbol
    message::String
end
struct CircuitValidationError <: Exception
    diagnostics::Vector{Diagnostic}
end
Base.showerror(io::IO,error::CircuitValidationError)=print(io,join(getfield.(error.diagnostics,:message),'\n'))

struct AnalysisValidationError <: Exception
    message::String
end
Base.showerror(io::IO,error::AnalysisValidationError)=print(io,error.message)
Base.show(io::IO,d::Diagnostic)=print(io,d.message)

function _check_power_law_noise!(diagnostics,component_name,model)
    fields=propertynames(model.data)
    :flicker_coefficient in fields||return
    coefficient=model.flicker_coefficient
    current_exponent=model.flicker_current_exponent
    frequency_exponent=model.flicker_frequency_exponent
    reference=model.flicker_reference_frequency
    isfinite(coefficient)&&coefficient>=0||push!(diagnostics,Diagnostic(:error,
        "$(component_name) flicker coefficient must be finite and non-negative."))
    isfinite(current_exponent)&&current_exponent>=0||push!(diagnostics,Diagnostic(:error,
        "$(component_name) flicker current exponent must be finite and non-negative."))
    isfinite(frequency_exponent)&&frequency_exponent>=0||push!(diagnostics,Diagnostic(:error,
        "$(component_name) flicker frequency exponent must be finite and non-negative."))
    isfinite(reference)&&reference>0||push!(diagnostics,Diagnostic(:error,
        "$(component_name) flicker reference frequency must be finite and positive."))
end

function check(c::Circuit)
    ds=Diagnostic[]; grounds=[n for n in c.nodes if n isa Ground]
    if isempty(grounds)
        push!(ds,Diagnostic(:error,"Circuit has no electrical reference. Add a ground to every electrical connected component."))
        return ds
    end
    length(grounds)==1||push!(ds,Diagnostic(:error,"Circuit must contain exactly one ground node; found $(length(grounds))."))
    node_names=map(node->node.name,c.nodes)
    length(unique(node_names))==length(node_names)||push!(ds,Diagnostic(:error,"Node names must be unique within a circuit."))
    component_names=map(component->component.name,c.components)
    length(unique(component_names))==length(component_names)||push!(ds,Diagnostic(:error,"Component names must be unique within a circuit."))
    circuit_nodes=IdSet()
    foreach(node->push!(circuit_nodes,node),c.nodes)
    for component in c.components
        spec=get(_DEVICE_SPECS,component.kind,nothing)
        if spec===nothing
            push!(ds,Diagnostic(:error,"$(component.name) has unsupported device kind $(component.kind).")); continue
        end
        length(component.terminals)==spec.terminals||push!(ds,Diagnostic(:error,"$(component.name) ($(component.kind)) requires $(spec.terminals) terminals, but has $(length(component.terminals))."))
        all(terminal->terminal in circuit_nodes,component.terminals)||push!(ds,Diagnostic(:error,"$(component.name) refers to a node that does not belong to this circuit."))
        waveform=get(component.parameters,:waveform,nothing)
        if waveform isa AbstractWaveform
            try _validate_waveform(waveform) catch error
                push!(ds,Diagnostic(:error,"$(component.name): $(sprint(showerror,error))"))
            end
        end
        if component.kind in (:cccs,:ccvs)
            control=get(component.parameters,:control,nothing)
            control_index=findfirst(candidate->candidate.name===control,c.components)
            if control_index===nothing
                push!(ds,Diagnostic(:error,"$(component.name) refers to unknown controlling component $(control)."))
            elseif !_DEVICE_SPECS[c.components[control_index].kind].branch
                push!(ds,Diagnostic(:error,"$(component.name) requires a controlling component with an MNA branch current."))
            end
        end
        if component.kind in (:resistor,:capacitor,:inductor)
            value=get(component.parameters,:value,nothing)
            (value isa Real&&isfinite(value)&&value>0)||push!(ds,Diagnostic(:error,"$(component.name) requires a finite, positive value."))
            if component.kind===:capacitor&&haskey(component.parameters,:leakage_resistance)
                leakage=component.parameters[:leakage_resistance]
                leakage isa Real&&leakage>0||push!(ds,Diagnostic(:error,
                    "$(component.name) leakage resistance must be positive."))
            end
            if component.kind===:resistor
                material=get(component.parameters,:material,nothing)
                if material isa ThinFilm
                    noise_values=(material.excess_noise_coefficient,
                        material.excess_current_exponent,
                        material.excess_frequency_exponent)
                    all(value->isfinite(value)&&value>=0,noise_values)||push!(ds,
                        Diagnostic(:error,"$(component.name) excess-noise parameters must be finite and non-negative."))
                    isfinite(material.excess_reference_frequency)&&
                        material.excess_reference_frequency>0||push!(ds,
                        Diagnostic(:error,"$(component.name) excess-noise reference frequency must be finite and positive."))
                end
            end
        elseif component.kind===:conductance
            value=get(component.parameters,:value,nothing)
            (value isa Real&&isfinite(value)&&value>=0)||push!(ds,Diagnostic(:error,"$(component.name) requires a finite, non-negative conductance."))
        elseif component.kind===:voltage_source
            resistance=get(component.parameters,:series_resistance,0.)
            (resistance isa Real&&isfinite(resistance)&&resistance>=0)||push!(ds,Diagnostic(:error,"$(component.name) requires a finite, non-negative series resistance."))
        elseif component.kind===:diode
            model=get(component.parameters,:model,nothing)
            model isa JunctionDiode||push!(ds,Diagnostic(:error,"$(component.name) requires a JunctionDiode model."))
            if model isa JunctionDiode
                model.saturation_current>0||push!(ds,Diagnostic(:error,"$(component.name) saturation current must be positive."))
                model.ideality>0||push!(ds,Diagnostic(:error,"$(component.name) ideality must be positive."))
                isfinite(model.series_resistance)&&model.series_resistance>=0||
                    push!(ds,Diagnostic(:error,
                        "$(component.name) series resistance must be finite and non-negative."))
                model.junction_capacitance>=0||push!(ds,Diagnostic(:error,"$(component.name) junction capacitance must be non-negative."))
                model.breakdown_voltage>0||push!(ds,Diagnostic(:error,"$(component.name) breakdown voltage must be positive."))
                model.breakdown_current>0||push!(ds,Diagnostic(:error,"$(component.name) breakdown current must be positive."))
                _check_power_law_noise!(ds,component.name,model)
            end
        elseif component.kind===:npn
            model=get(component.parameters,:model,nothing)
            model isa GummelPoonBJT||push!(ds,Diagnostic(:error,"$(component.name) requires a GummelPoonBJT model."))
            if model isa GummelPoonBJT
                model.saturation_current>0||push!(ds,Diagnostic(:error,"$(component.name) saturation current must be positive."))
                model.forward_beta>0||push!(ds,Diagnostic(:error,"$(component.name) forward beta must be positive."))
                model.reverse_beta>0||push!(ds,Diagnostic(:error,"$(component.name) reverse beta must be positive."))
                model.early_voltage>0||push!(ds,Diagnostic(:error,"$(component.name) early voltage must be positive."))
                isfinite(model.base_resistance)&&model.base_resistance>=0||
                    push!(ds,Diagnostic(:error,
                        "$(component.name) base resistance must be finite and non-negative."))
                _check_power_law_noise!(ds,component.name,model)
            end
        elseif component.kind in (:nmos,:pmos)
            model=get(component.parameters,:model,nothing)
            model isa Level1MOSFET||push!(ds,Diagnostic(:error,"$(component.name) requires a Level1MOSFET model."))
            if model isa Level1MOSFET
                model.threshold_voltage>0||push!(ds,Diagnostic(:error,"$(component.name) threshold voltage must be positive."))
                model.transconductance>0||push!(ds,Diagnostic(:error,"$(component.name) transconductance parameter must be positive."))
                model.channel_length_modulation>=0||push!(ds,Diagnostic(:error,"$(component.name) channel-length modulation must be non-negative."))
                model.body_effect>=0||push!(ds,Diagnostic(:error,"$(component.name) body-effect coefficient must be non-negative."))
                model.surface_potential>0||push!(ds,Diagnostic(:error,"$(component.name) surface potential must be positive."))
                all(value->value>=0,(model.gate_source_capacitance,model.gate_drain_capacitance,model.gate_bulk_capacitance))||push!(ds,Diagnostic(:error,"$(component.name) gate capacitances must be non-negative."))
                isfinite(model.channel_thermal_coefficient)&&model.channel_thermal_coefficient>=0||
                    push!(ds,Diagnostic(:error,"$(component.name) channel thermal coefficient must be finite and non-negative."))
                isfinite(model.induced_gate_noise_coefficient)&&model.induced_gate_noise_coefficient>=0||
                    push!(ds,Diagnostic(:error,"$(component.name) induced gate noise coefficient must be finite and non-negative."))
                abs(model.gate_channel_correlation)<=1||push!(ds,Diagnostic(:error,"$(component.name) gate/channel noise correlation magnitude must not exceed one."))
                _check_power_law_noise!(ds,component.name,model)
            end
        elseif component.kind===:switch
            model=get(component.parameters,:model,nothing)
            if model isa Union{VoltageControlledSwitch,EventSwitch,SmoothSwitch}
                model.ron>0&&model.roff>0||push!(ds,Diagnostic(:error,"$(component.name) switch resistances must be positive."))
            else
                push!(ds,Diagnostic(:error,"$(component.name) requires a switch model."))
            end
        elseif component.kind===:opamp
            model=get(component.parameters,:model,nothing)
            if model isa BehavioralOpAmp
                model.dc_gain>0&&model.gain_bandwidth>0&&model.output_resistance>=0||push!(ds,Diagnostic(:error,"$(component.name) has invalid op-amp gain, bandwidth, or output resistance."))
                densities=(model.input_voltage_noise_density,
                    model.positive_input_current_noise_density,
                    model.negative_input_current_noise_density)
                all(value->value>=0&&isfinite(value),densities)||push!(ds,
                    Diagnostic(:error,"$(component.name) op-amp noise densities must be finite and non-negative."))
                corners=(model.input_voltage_flicker_corner,model.input_current_flicker_corner)
                all(value->value>=0&&isfinite(value),corners)||push!(ds,
                    Diagnostic(:error,"$(component.name) op-amp flicker corners must be finite and non-negative."))
                exponents=(model.input_voltage_flicker_exponent,model.input_current_flicker_exponent)
                all(value->value>=0&&isfinite(value),exponents)||push!(ds,
                    Diagnostic(:error,"$(component.name) op-amp flicker exponents must be finite and non-negative."))
                abs(model.voltage_current_noise_correlation)<=1||push!(ds,
                    Diagnostic(:error,"$(component.name) op-amp voltage/current noise correlation magnitude must not exceed one."))
            else
                push!(ds,Diagnostic(:error,"$(component.name) requires a BehavioralOpAmp model."))
            end
        end
    end
    circuit_components=IdSet(); foreach(component->push!(circuit_components,component),c.components)
    for observable in vcat(c.observations,collect(values(get(c.metadata,:named_observations,Dict{Symbol,Any}()))))
        observable isa Observable||continue
        target=observable.target; extra=observable.extra
        target isa AbstractNode&&!(target in circuit_nodes)&&push!(ds,Diagnostic(:error,"An observation refers to a node outside this circuit."))
        target isa Component&&!(target in circuit_components)&&push!(ds,Diagnostic(:error,"An observation refers to a component outside this circuit."))
        extra isa AbstractNode&&!(extra in circuit_nodes)&&push!(ds,Diagnostic(:error,"A differential observation refers to a node outside this circuit."))
    end
    for (name,terminal) in get(c.metadata,:ports,Dict{Symbol,Any}())
        terminal isa AbstractNode&&terminal in circuit_nodes||push!(ds,Diagnostic(:error,"Port $(name) does not refer to a node owned by this circuit."))
    end
    adjacency=Dict{Int,Vector{Int}}(n.id=>Int[] for n in c.nodes); adjacency[0]=get(adjacency,0,Int[])
    for x in c.components
        spec=get(_DEVICE_SPECS,x.kind,nothing)
        spec===nothing&&continue
        if spec.dc_path&&x.kind ∉ (:vcvs,:ccvs,:opamp)
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

"""
    explain(circuit)

Return a concise structural explanation, including actionable corrections for
every diagnostic currently found in the circuit.
"""
function explain(c::Circuit)
    diagnostics = check(c)
    io = IOBuffer()
    println(io, "Circuit $(c.name): $(length(c.nodes)) nodes, $(length(c.components)) components, $(length(c.observations)) observations.")
    kinds = Dict{Symbol,Int}()
    for component in c.components
        kinds[component.kind] = get(kinds, component.kind, 0) + 1
    end
    if !isempty(kinds)
        summary = join(("$(kind)=$(count)" for (kind, count) in sort!(collect(kinds); by=x -> String(first(x)))), ", ")
        println(io, "Device composition: ", summary, ".")
    end
    if isempty(diagnostics)
        println(io, "Structural check: no errors detected; the circuit is ready to compile.")
    else
        println(io, "Structural check: $(count(d -> d.severity === :error, diagnostics)) error(s), $(count(d -> d.severity === :warning, diagnostics)) warning(s).")
        for diagnostic in diagnostics
            println(io, "- [$(uppercase(String(diagnostic.severity)))] ", diagnostic.message)
        end
    end
    chomp(String(take!(io)))
end

function _unknown_label(compiled, row::Integer)
    for (id, index) in compiled.node_index
        index == row || continue
        node = findfirst(candidate -> candidate.id == id, compiled.circuit.nodes)
        return node === nothing ? "node $(id)" : "V($(compiled.circuit.nodes[node].name))"
    end
    for (component_index, index) in compiled.branches
        index == row && return "I($(compiled.circuit.components[component_index].name))"
    end
    for ((component_index, state), index) in compiled.states
        index == row && return "state($(compiled.circuit.components[component_index].name), $(state))"
    end
    "residual row $(row)"
end

"""
    explain_failure(result)

Explain solver convergence status and identify the residual equation that
dominated each recorded failed transient step.
"""
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
    if result.analysis isa Transient
        println(io, "The simulation did not converge; $(length(failed)) accepted step(s) contain unresolved nonlinear residuals.")
    else
        println(io, "The simulation did not converge after $(get(stats, :iterations, "an unknown number of")) nonlinear iteration(s).")
    end
    residuals = get(stats, :failed_residuals, Any[])
    if isempty(residuals) && haskey(stats, :dominant_residual)
        residuals = [stats[:dominant_residual]]
    end
    for (index, detail) in enumerate(residuals)
        label = _unknown_label(result.compiled, detail.row)
        prefix = index <= length(failed) ? "Step $(failed[index]): " : ""
        println(io, "- $(prefix)$(label) dominated the residual (infinity norm $(detail.norm)).")
    end
    if isempty(residuals)
        println(io, "No per-equation residual was recorded. Inspect structural diagnostics with explain(result.compiled.circuit).")
    else
        println(io, "Try a smaller maximum step, looser initial tolerances, realistic parasitics, or inspect the named device/node above.")
    end
    chomp(String(take!(io)))
end
