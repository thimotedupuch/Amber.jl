using Amber, Test
@testset "shared equation DAG and derivative requests" begin
    v=Amber.EquationInput{:voltage}(); g=Amber.EquationInput{:conductance}(); c=Amber.EquationInput{:capacitance}()
    law=Amber.ConstitutiveLaw(g*v,c*v)
    requests=[ConstitutiveRequest(:current),ConstitutiveRequest(:charge),
        ConstitutiveRequest(:current,(:voltage,)),ConstitutiveRequest(:charge,(:voltage,))]
    program=compile_constitutive(law;requests); workspace=ConstitutiveWorkspace(program); output=zeros(4)
    inputs=(;voltage=2.0,conductance=0.01,capacitance=1e-9)
    @test evaluate_constitutive!(output,workspace,program,inputs) ≈ [0.02,2e-9,0.01,1e-9]
    @test length(program.instructions) == 5
    @test workspace.evaluated_nodes == 5
    @test evaluate_constitutive!(zeros(1),workspace,program,(;voltage=2.0,conductance=0.02);outputs=(1,)) ≈ [0.04]
    @test workspace.evaluated_nodes == 3
    @test evaluate_constitutive!(output,workspace,program,inputs) ≈ [0.02,2e-9,0.01,1e-9]
    ordered=Float64[getproperty(inputs,name) for name in program.input_names]
    @test evaluate_constitutive!(output,workspace,program,ordered) ≈ [0.02,2e-9,0.01,1e-9]
    workspace.epoch=typemax(UInt64)
    @test evaluate_constitutive!(output,workspace,program,inputs)[1] ≈ 0.02
    @test workspace.epoch == 1
    @test_throws DimensionMismatch evaluate_constitutive!(zeros(1),workspace,program,inputs)
    @test_throws ArgumentError evaluate_constitutive!(zeros(1),workspace,program,inputs;outputs=(0,))
    @test_throws ArgumentError evaluate_constitutive!(output,ConstitutiveWorkspace(compile_constitutive(law)),program,inputs)
    @test_throws ArgumentError compile_constitutive(law;max_nodes=1)
end
@testset "DAG lazy branches, failure recovery and scalar rules" begin
    v=Amber.EquationInput{:voltage}()
    law=Amber.ConstitutiveLaw(Amber._equation_positive(v,v,exp(v)),Amber.EquationLiteral(0.0))
    program=compile_constitutive(law); workspace=ConstitutiveWorkspace(program)
    @test evaluate_constitutive!(zeros(2),workspace,program,(;voltage=1000.0)) == [1000.0,0.0]
    @test workspace.evaluated_nodes < length(program.instructions)
    @test evaluate_constitutive!(zeros(2),workspace,program,(;voltage=-1000.0)) == [0.0,0.0]
    bad=compile_constitutive(Amber.ConstitutiveLaw(log1p(v),v)); wb=ConstitutiveWorkspace(bad)
    @test_throws DomainError evaluate_constitutive!(zeros(2),wb,bad,(;voltage=-2.0))
    @test evaluate_constitutive!(zeros(2),wb,bad,(;voltage=1.0)) ≈ [log(2),1.0]
    @test_throws ArgumentError evaluate_constitutive!(zeros(2),workspace,program,(;voltage=NaN))
    @test_throws ArgumentError evaluate_constitutive!(zeros(2),workspace,program,NamedTuple())
    @test_throws ArgumentError ConstitutiveRequest(:unknown)
    polynomial=compile_constitutive(Amber.ConstitutiveLaw(v^3,v);requests=[ConstitutiveRequest(:current,(:voltage,:voltage))])
    @test evaluate_constitutive!(zeros(1),ConstitutiveWorkspace(polynomial),polynomial,(;voltage=-2.0)) ≈ [-12.0]
end
@testset "complete diode DAG matches independent kernels" begin
    model=JunctionDiode(junction_capacitance=2e-12,transit_time=1e-9,breakdown_voltage=5.0)
    law=Amber._diode_constitutive_ir(model)
    requests=[ConstitutiveRequest(:current),ConstitutiveRequest(:charge),
        ConstitutiveRequest(:current,(:voltage,)),ConstitutiveRequest(:charge,(:voltage,)),
        ConstitutiveRequest(:charge,(:voltage,:voltage))]
    program=compile_constitutive(law;requests); workspace=ConstitutiveWorkspace(program)
    for voltage in (-10.0,-0.1,0.4,0.64,3.0), temperature in (280.0,340.0)
        point=(;voltage,temperature,saturation_current=model.saturation_current)
        output=evaluate_constitutive!(zeros(5),workspace,program,point)
        current,conductance=Amber._diode_conduction(model,voltage,temperature)
        @test output ≈ [current,charge(model,voltage;temperature),conductance,
            differential_capacitance(model,voltage;temperature),Amber._capacitance_slope(model,voltage;temperature)] rtol=1e-11 atol=1e-25
    end
    @test typeof(program) == typeof(compile_constitutive(Amber.ConstitutiveLaw(Amber.EquationLiteral(1.0),Amber.EquationLiteral(0.0))))
end
@testset "constitutive buffer ownership" begin
    a=Amber.EquationInput{:a}(); b=Amber.EquationInput{:b}()
    program=compile_constitutive(Amber.ConstitutiveLaw(Amber.EquationLiteral(1.0),a*b))
    workspace=ConstitutiveWorkspace(program); values=[2.0,3.0]
    @test_throws ArgumentError evaluate_constitutive!(values,workspace,program,values)
    @test values == [2.0,3.0]
    @test_throws ArgumentError evaluate_constitutive!(view(workspace.values,1:2),workspace,program,values)
    @test_throws ArgumentError evaluate_constitutive!(zeros(2),workspace,program,view(workspace.values,1:2))
    @test evaluate_constitutive!(zeros(2),workspace,program,values) == [1.0,6.0]
end
@testset "output indices and program arrays cannot be overwritten" begin
    a=Amber.EquationInput{:a}(); b=Amber.EquationInput{:b}()
    program=compile_constitutive(Amber.ConstitutiveLaw(a,b)); workspace=ConstitutiveWorkspace(program)
    append!(workspace.stack,Int32[1,2])
    @test_throws ArgumentError evaluate_constitutive!(zeros(2),workspace,program,[2.0,3.0];outputs=workspace.stack)
    @test_throws ArgumentError evaluate_constitutive!(program.roots,workspace,program,[2.0,3.0])
    @test evaluate_constitutive!(zeros(2),workspace,program,[2.0,3.0]) == [2.0,3.0]
end
struct ProgramZeroVector{T} <: AbstractVector{T}
    data::Vector{T}
end
Base.size(x::ProgramZeroVector)=size(x.data)
Base.axes(x::ProgramZeroVector)=(0:(length(x.data)-1),)
Base.getindex(x::ProgramZeroVector,i::Int)=x.data[i+1]
Base.setindex!(x::ProgramZeroVector,value,i::Int)=(x.data[i+1]=value;x)
@testset "constitutive slot indexing contract" begin
    a=Amber.EquationInput{:a}(); b=Amber.EquationInput{:b}()
    program=compile_constitutive(Amber.ConstitutiveLaw(a,b)); workspace=ConstitutiveWorkspace(program)
    @test_throws ArgumentError evaluate_constitutive!(zeros(2),workspace,program,ProgramZeroVector([2.0,3.0]))
    @test_throws ArgumentError evaluate_constitutive!(ProgramZeroVector(zeros(2)),workspace,program,[2.0,3.0])
end
