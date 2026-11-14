using Amber, Test, LinearAlgebra
function identity_circuit()
    b=CircuitBuilder(:IdentityCircuit); g=ground!(b); input=node!(b,:input); output=node!(b,:output)
    add!(b,voltage_source(input,g;dc=1.0,ac=1.0);name=:Supply)
    add!(b,resistor(input,output;value=1.0);name=:Top)
    add!(b,resistor(output,g;value=1.0);name=:Bottom)
    add!(b,capacitor(output,g;value=1.0);name=:C)
    compile(finish(b))
end
@testset "coefficient identities separate forcing and matrix changes" begin
    cc=identity_circuit(); token=cc.parameters.matrix_identity
    forcing=with_parameters(cc,"Supply.dc"=>2.0)
    @test forcing.parameters.matrix_identity === token
    @test with_parameters(cc,"Top.value"=>1.0).parameters.matrix_identity === token
    changed=with_parameters(cc,"Top.value"=>2.0)
    @test changed.parameters.matrix_identity !== token
    @test with_parameters(cc,"C.value"=>2.0).parameters.matrix_identity !== token
    ws=SimulationWorkspace(cc); x=zeros(cc.n)
    Amber._step_residual_jacobian!(ws,cc,x,nothing,0.0,0.0)
    @test ws.constant_assemblies == 1
    Amber._step_residual_jacobian!(ws,forcing,x,nothing,0.0,0.0)
    @test ws.constant_assemblies == 1
    # Emulate equal content digests: runtime reuse must depend on the exact
    # coefficient identity, not a hash collision or malformed provenance ID.
    p=changed.parameters
    forged=Amber.ParameterStore(p.batches,p.fingerprint,cc.parameters.matrix_fingerprint,
        p.batch_fingerprints,p.matrix_batch_fingerprints,p.dependency_graph,p.matrix_identity)
    same_digest=CompiledCircuit(changed.design,changed.topology,forged,changed.fingerprint)
    Amber._step_residual_jacobian!(ws,same_digest,x,nothing,0.0,0.0)
    @test ws.constant_assemblies == 2
    @test Amber.device_contract(:capacitor).dependencies.matrix_fields == (:value,:leakage_resistance)
end
@testset "factor reuse includes variable scales" begin
    cc=identity_circuit(); ws=SimulationWorkspace(cc); z=zeros(cc.n)
    x,_,ok=Amber._newton(cc,z,z,0.0,0.0;workspace=ws,mode=:dc)
    @test ok; @test x[2] ≈ 0.5
    count=ws.numeric_factorizations
    forcing=with_parameters(cc,"Supply.dc"=>2.0)
    y,_,ok=Amber._newton(forcing,z,z,0.0,0.0;workspace=ws,mode=:dc)
    @test ok && y[2] ≈ 1.0
    @test ws.numeric_factorizations == count
    ws.variable_scales[2] *= 3.0
    y2,_,ok=Amber._newton(forcing,z,z,0.0,0.0;workspace=ws,mode=:dc)
    @test ok && y2 ≈ y
    @test ws.numeric_factorizations == count+1
    ws.variable_scales[1]=0.0
    @test_throws ArgumentError Amber._newton(forcing,z,z,0.0,0.0;workspace=ws)
end
@testset "workspace topology binding prevents sparse slot misuse" begin
    cc=identity_circuit(); other=identity_circuit(); ws=SimulationWorkspace(cc); z=zeros(cc.n)
    @test_throws ArgumentError residual_jacobian!(ws,other,z,z,0.0,0.0)
    @test_throws ArgumentError residual!(ws,other,z,z,0.0)
    @test_throws ArgumentError storage_jacobian!(ws,other,z)
    @test_throws ArgumentError Amber._step_residual!(ws,other,z,nothing,0.0,0.0)
    @test operating_point(with_parameters(cc,"Supply.dc"=>2.0);workspace=ws).stats[:converged]
end
@testset "controlled-source coefficient dependency declarations" begin
    b=CircuitBuilder(:CoefficientFields); g=ground!(b); input=node!(b,:input)
    sense=add!(b,voltage_source(input,g;dc=1.0);name=:Sense)
    add!(b,resistor(input,g;value=1000.0);name=:Bias)
    v=node!(b,:v); add!(b,voltage_controlled_voltage_source(input,g,v,g;gain=2.0);name=:E)
    add!(b,resistor(v,g;value=1000.0);name=:Rv)
    o=node!(b,:o); add!(b,transconductance(input,g,o,g;gm=0.001);name=:G)
    add!(b,resistor(o,g;value=1000.0);name=:Ro)
    f=node!(b,:f); add!(b,current_controlled_current_source(sense,f,g;gain=2.0);name=:F)
    add!(b,resistor(f,g;value=1000.0);name=:Rf)
    h=node!(b,:h); add!(b,current_controlled_voltage_source(sense,h,g;transresistance=1000.0);name=:H)
    add!(b,resistor(h,g;value=1000.0);name=:Rh)
    cc=compile(finish(b))
    for (path,value) in (("E.gain",3.0),("G.gm",0.002),("F.gain",3.0),("H.transresistance",2000.0))
        updated=with_parameters(cc,path=>value)
        @test updated.parameters.matrix_identity !== cc.parameters.matrix_identity
        oldg,_=Amber._static_dynamic_jacobians(cc,zeros(cc.n))
        newg,_=Amber._static_dynamic_jacobians(updated,zeros(cc.n))
        @test oldg != newg
    end
end
