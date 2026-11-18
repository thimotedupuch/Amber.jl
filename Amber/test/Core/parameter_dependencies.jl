using Amber, Test
function dependent_capacitor(value=1e-6;loss=0.02,frequency=1000.0,base_esr=3.0,absorption=true)
    b=CircuitBuilder(:DependentCapacitor); g=ground!(b); input=node!(b,:input)
    add!(b,voltage_source(input,g;ac=1.0);name=:Supply)
    dielectric=Polypropylene(loss_tangent=loss,reference_frequency=frequency)
    if absorption
        add!(b,capacitor(input,g;value,esr=base_esr,dielectric,
            dielectric_absorption=DebyeBranches(time_constants=[0.01],fractions=[0.1]));name=:C)
    else
        add!(b,capacitor(input,g;value,esr=base_esr,dielectric);name=:C)
    end
    finish(b)
end
function dependency_value(cc,path)
    batch,device=Amber._hierarchical_device(cc,path)
    batch.parameters[device].value
end
@testset "retained physical parameter formulas" begin
    for limit in (0,8)
        cc=compile(dependent_capacitor();specialization_limit=limit)
        @test length(parameter_dependencies(cc)) == 3
        updated=with_parameters(cc,"C.value"=>4e-6)
        @test dependency_value(updated,"C") ≈ 4e-6
        @test dependency_value(updated,"C.esr") ≈ 3+0.02/(2pi*1000*4e-6)
        @test dependency_value(updated,"C.da1_capacitor") ≈ 4e-7
        @test dependency_value(updated,"C.da1_resistor") ≈ 0.01/4e-7
        @test dependency_value(cc,"C") ≈ 1e-6
        @test batch_execution_plan(updated).layout == batch_execution_plan(cc).layout
        again=with_parameters(updated,"C.value"=>2e-6)
        @test dependency_value(again,"C.da1_resistor") ≈ 0.01/2e-7
        fresh=compile(dependent_capacitor(4e-6))
        a=small_signal(updated,[100.0,1000.0,10000.0]); b=small_signal(fresh,[100.0,1000.0,10000.0])
        @test current(a,:Supply) ≈ current(b,:Supply)
        @test_throws ArgumentError with_parameters(cc,"C.value"=>0.0)
        @test dependency_value(cc,"C") ≈ 1e-6
        rule=first(cc.parameters.dependency_graph.rules)
        handle=ParameterHandle(cc.topology,("",nothing,"C.esr",:value),[rule.target.batch=>[rule.target.device]])
        @test_throws ArgumentError with_parameters(cc,handle=>1.0)
    end
end
@testset "dependency serialization and schema-three compatibility" begin
    design=dependent_capacitor(); text=serialize_circuit(design)
    @test occursin("schema_version = 4",text)
    restored=deserialize_circuit(text)
    @test serialize_circuit(restored) == text
    @test parameter_dependencies(compile(restored)) == parameter_dependencies(compile(design))
    updated=with_parameters(compile(restored),"C.value"=>2e-6)
    @test dependency_value(updated,"C.da1_capacitor") ≈ 2e-7
    old=Amber.TOML.parse(text); old["schema_version"]=3
    delete!(old["root_body"],"parameter_relations")
    io=IOBuffer(); Amber.TOML.print(io,old)
    legacy=compile(deserialize_circuit(String(take!(io))))
    @test isempty(parameter_dependencies(legacy))
    @test_throws TopologyParameterError with_parameters(legacy,"C.value"=>2e-6)
    invalid=Amber.TOML.parse(text); invalid["root_body"]["parameter_relations"][1]["source"]=999
    io=IOBuffer(); Amber.TOML.print(io,invalid)
    @test_throws CircuitSerializationError deserialize_circuit(String(take!(io)))
end
@testset "structural guards and dependency cycles" begin
    # An expansion absent because of floating-point range cannot be introduced
    # by a numerical-only update, even if other children depend on that source.
    cc=compile(dependent_capacitor(1e305;base_esr=0.0))
    @test any(r->r.operation===:rebuild,parameter_dependencies(cc))
    @test_throws TopologyParameterError with_parameters(cc,"C.value"=>1e-6)
    extreme=compile(dependent_capacitor(1.0;frequency=1e308,base_esr=1.0,absorption=false))
    @test dependency_value(with_parameters(extreme,"C.value"=>2.0),"C.esr") == 1.0
    a=Amber.ParameterLocation(1,1,:value); b=Amber.ParameterLocation(1,2,:value)
    spec=Amber.DerivedParameterSpec(1,:value,2,:value,:affine,1.0,0.0,1.0)
    r1=Amber.CompiledParameterRule(a,b,spec); r2=Amber.CompiledParameterRule(b,a,spec)
    @test_throws ArgumentError Amber._parameter_graph_order([r1,r2])
    @test_throws ArgumentError Amber._parameter_graph_order([r1,r1])
end
@testset "partial expansion declarations cannot enable stale updates" begin
    snapshot=circuit_snapshot(dependent_capacitor())
    pop!(snapshot["root_body"]["parameter_relations"])
    io=IOBuffer(); Amber.TOML.print(io,snapshot)
    cc=compile(deserialize_circuit(String(take!(io))))
    @test_throws TopologyParameterError with_parameters(cc,"C.value"=>2e-6)
    @test dependency_value(cc,"C.da1_capacitor") ≈ 1e-7
end
@testset "propagation respects structural rebuild guards" begin
    b=CircuitBuilder(:GuardedPropagation); g=ground!(b); n=node!(b,:n)
    r=add!(b,resistor(n,g;value=1.0);name=:R)
    c=add!(b,capacitor(n,g;value=1.0);name=:C)
    push!(b.parameter_relations,Amber.DerivedParameterSpec(r.id,:value,c.id,:value,:affine,1.0,0.0,1.0))
    push!(b.parameter_relations,Amber.DerivedParameterSpec(c.id,:value,c.id,:value,:rebuild,0.0,0.0,1.0))
    cc=compile(finish(b))
    @test_throws TopologyParameterError with_parameters(cc,"C.value"=>2.0)
    @test_throws TopologyParameterError with_parameters(cc,"R.value"=>2.0)
    @test dependency_value(cc,"R") == 1.0
    @test dependency_value(cc,"C") == 1.0
end
@testset "transitive dependency updates are ordered and transactional" begin
    b=CircuitBuilder(:ParameterChain); g=ground!(b); n=node!(b,:n)
    add!(b,voltage_source(n,g;dc=1.0);name=:Supply)
    r1=add!(b,resistor(n,g;value=1.0);name=:R1)
    r2=add!(b,resistor(n,g;value=2.0);name=:R2)
    r3=add!(b,resistor(n,g;value=4.0);name=:R3)
    # Declare reverse order to exercise topological scheduling.
    push!(b.parameter_relations,Amber.DerivedParameterSpec(r2.id,:value,r3.id,:value,:affine,2.0,0.0,1.0))
    push!(b.parameter_relations,Amber.DerivedParameterSpec(r1.id,:value,r2.id,:value,:affine,2.0,0.0,1.0))
    cc=compile(finish(b)); updated=with_parameters(cc,"Supply.dc"=>2.0,"R1.value"=>3.0)
    @test dependency_value(updated,"R2") == 6.0
    @test dependency_value(updated,"R3") == 12.0
    @test dependency_value(cc,"R2") == 2.0
    @test_throws ArgumentError with_parameters(cc,"R2.value"=>5.0)
end
@subcircuit DependencyCell(input,reference) begin
    C=capacitor(input,reference;value=1e-6,dielectric=Polypropylene(loss_tangent=0.02,reference_frequency=1000.0))
end
@testset "template instances retain independent parameter graphs" begin
    b=CircuitBuilder(:HierarchicalDependencies); g=ground!(b); n=node!(b,:n)
    add!(b,voltage_source(n,g;ac=1.0);name=:Supply)
    instance!(b,DependencyCell,n,g;instance_name=:First)
    instance!(b,DependencyCell,n,g;instance_name=:Second)
    design=deserialize_circuit(serialize_circuit(finish(b))); cc=compile(design)
    @test length(parameter_dependencies(cc)) == 2
    changed=with_parameters(cc,"First.C.value"=>2e-6)
    @test dependency_value(changed,"First.C.esr") ≈ 0.02/(2pi*1000*2e-6)
    @test dependency_value(changed,"Second.C.esr") ≈ 0.02/(2pi*1000*1e-6)
    @test dependency_value(cc,"First.C") == 1e-6
end
