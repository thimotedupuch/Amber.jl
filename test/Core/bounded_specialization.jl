using Amber, Test, LinearAlgebra
struct DiversityLaw{I} end
(::DiversityLaw{I})(v,t) where I = I*1e-6*v[1]
struct DiversityGradient{I} end
(::DiversityGradient{I})(v,t) where I = (I*1e-6,0.0,0.0,0.0)
function diversity_design(n)
    b=CircuitBuilder(:Diversity); g=ground!(b); input=node!(b,:input)
    add!(b,voltage_source(input,g;dc=1.0);name=:Supply)
    for i in 1:n
        output=node!(b,Symbol(:out,i))
        add!(b,resistor(output,g;value=1000.0);name=Symbol(:R,i))
        add!(b,behavioral_current_source(((input,g),),output,g;
            current=DiversityLaw{i}(),gradient=DiversityGradient{i}());name=Symbol(:B,i))
    end
    finish(b)
end
@testset "bounded circuit-wide specialization" begin
    design=diversity_design(4)
    specialized=compile(design;specialization_limit=typemax(Int))
    bounded=compile(design;specialization_limit=0)
    @test batch_execution_plan(specialized).layout === :specialized_tuple
    @test batch_execution_plan(bounded).layout === :bounded_dispatch
    @test typeof(compile(diversity_design(2);specialization_limit=0)) == typeof(bounded)
    @test typeof(compile(diversity_design(40))) == typeof(bounded)
    @test batch_execution_plan(compile(diversity_design(40))).layout === :bounded_dispatch
    for cc in (specialized,bounded)
        result=operating_point(cc)
        @test result.stats[:converged]
        @test voltage(result,:out1)[1] ≈ -0.001V
        updated=with_parameters(cc,"R1.value"=>2000.0)
        @test batch_execution_plan(updated).layout == batch_execution_plan(cc).layout
        @test voltage(operating_point(updated),:out1)[1] ≈ -0.002V
        @test voltage(result,:out1)[1] ≈ -0.001V
    end
    x=collect(range(0.0,0.5;length=bounded.n)); previous=x.-0.01
    wa=SimulationWorkspace(specialized); wb=SimulationWorkspace(bounded)
    ra,ja=residual_jacobian!(wa,specialized,x,previous,0.2,1e3)
    rb,jb=residual_jacobian!(wb,bounded,x,previous,0.2,1e3)
    @test ra ≈ rb
    @test ja ≈ jb
    qa,ca=storage_jacobian!(wa,specialized,x); qb,cb=storage_jacobian!(wb,bounded,x)
    @test qa == qb && ca == cb
    @test_throws ArgumentError compile(design;specialization_limit=-1)
    @test compile(bounded;specialization_limit=32) === bounded
end
@testset "bounded storage, forcing, noise and frequency paths" begin
    b=CircuitBuilder(:BoundedRC); g=ground!(b); input=node!(b,:input); output=node!(b,:output)
    add!(b,voltage_source(input,g;dc=1.0,ac=1.0);name=:Source)
    add!(b,resistor(input,output;value=1000.0);name=:R)
    add!(b,capacitor(output,g;value=1e-6);name=:C)
    design=finish(b); a=compile(design); b=compile(design;specialization_limit=0)
    ta=transient(a,0.0=>0.01;initial=:discharged,max_step=0.001)
    tb=transient(b,0.0=>0.01;initial=:discharged,max_step=0.001)
    @test ta.values ≈ tb.values
    aa=small_signal(a,[1.0,10.0,100.0]); ab=small_signal(b,[1.0,10.0,100.0])
    @test voltage(aa,:output) ≈ voltage(ab,:output)
    na=noise(a,[1.0,10.0];output=voltage(:output),input=:Source)
    nb=noise(b,[1.0,10.0];output=voltage(:output),input=:Source)
    @test noise_psd(na) ≈ noise_psd(nb)
end
