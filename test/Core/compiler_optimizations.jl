using LinearAlgebra

@testset "residual evaluation and conservative MOS derivatives" begin
    gradient_calls=Ref(0)
    gradient=(v,t)->begin gradient_calls[]+=1; (2v[1],0.,0.,0.) end
    @circuit EvaluationCircuit() begin
        gnd=ground(); gate=node(); drain=node(); output=node()
        VG=voltage_source(gate,gnd;dc=1.,ac=1.)
        R=resistor(drain,gnd;value=1e3)
        C=capacitor(drain,gnd;value=1e-9)
        B=behavioral_current_source(((gate,gnd),),drain,gnd;
            current=(v,t)->v[1]^2,gradient)
        BV=behavioral_voltage_source(((gate,gnd),),output,gnd;
            voltage=(v,t)->v[1]^2,gradient)
        M=nmos(drain,gate,gnd,gnd;model=ChargeBasedMOSFET(
            drain_area=1e-12,source_area=1e-12,gate_drain_overlap=1e-10))
    end
    cc=compile(EvaluationCircuit()); ws=SimulationWorkspace(cc)
    x=collect(range(.1,.8;length=cc.n)); previous=x .- .01
    directions=Matrix{Float64}(I,cc.n,cc.n)
    for temperature in (280.,340.), alpha in (0.,1e6)
        qhistory=Amber._storage(cc,previous;temperature)
        r,j=Amber._step_residual_jacobian!(ws,cc,x,qhistory,.2,alpha;temperature,gmin=1e-8)
        reference=copy(r); matrix=copy(j.nzval); count=gradient_calls[]
        trial=copy(Amber._step_residual!(ws,cc,x,qhistory,.2,alpha;temperature,gmin=1e-8))
        @test trial≈reference rtol=1e-13
        @test gradient_calls[]==count
        @test ws.jacobian.nzval==matrix
        @test ws.residual==reference
        # Differentiate the discrete residual independently of its tangent.
        h=1e-6
        numerical=hcat([(copy(Amber._step_residual!(ws,cc,x+h*directions[:,k],qhistory,.2,alpha;temperature,gmin=1e-8))-
            copy(Amber._step_residual!(ws,cc,x-h*directions[:,k],qhistory,.2,alpha;temperature,gmin=1e-8)))/(2h)
            for k in 1:cc.n]...)
        @test Matrix(j)≈numerical rtol=1e-7 atol=1e-10
    end
    dx=fill(.02,cc.n)
    r,j=residual_jacobian!(ws,cc,x,x-dx,.2,1.)
    reference=copy(r); matrix=copy(j.nzval); count=gradient_calls[]
    @test residual!(ws,cc,x,dx,.2)≈reference
    @test ws.jacobian.nzval==matrix
    @test gradient_calls[]==count
end

@testset "constant contribution and forcing invalidation" begin
    cc=compile(LowPass()); ws=SimulationWorkspace(cc)
    x=zeros(cc.n); alpha=1e5
    Amber._newton(cc,x,x,1e-6,alpha;workspace=ws)
    factors=ws.numeric_factorizations; assemblies=ws.constant_assemblies
    source=with_parameters(cc,"V1.dc"=>2.)
    @test source.parameters.matrix_fingerprint==cc.parameters.matrix_fingerprint
    answer,_,converged=Amber._newton(source,x,x,1e-6,alpha;workspace=ws,mode=:dc)
    @test converged
    # mode is part of the factorization key; repeat using the same mode.
    factors=ws.numeric_factorizations
    source2=with_parameters(source,"V1.dc"=>3.)
    answer2,_,converged=Amber._newton(source2,x,x,1e-6,alpha;workspace=ws,mode=:dc)
    @test converged
    @test answer2≈1.5answer
    @test ws.numeric_factorizations==factors
    @test ws.constant_assemblies==assemblies
    changed=with_parameters(source2,"R1.value"=>2e4,"C1.value"=>2e-8)
    @test changed.parameters.matrix_fingerprint!=source2.parameters.matrix_fingerprint
    answer3,_,converged=Amber._newton(changed,x,x,1e-6,alpha;workspace=ws,mode=:dc)
    @test converged
    @test ws.numeric_factorizations>factors
    @test ws.constant_assemblies==assemblies+1
    fresh,_,_=Amber._newton(changed,x,x,1e-6,alpha;mode=:dc)
    @test answer3≈fresh

    cc=compile(BiasedNPN()); ws=SimulationWorkspace(cc)
    x=operating_point(cc).values[:,1]; q=Amber._storage(cc,x)
    r,j=Amber._step_residual_jacobian!(ws,cc,x,q,0.,1e5)
    assemblies=ws.constant_assemblies
    # Cached passive contributions coexist with temperature-dependent devices.
    for temperature in (290.,330.)
        r,j=Amber._step_residual_jacobian!(ws,cc,x,q,0.,1e5;temperature)
        expected,g=Amber.residual_jacobian(cc,x,x,0.,0.;temperature)
        storage,c=storage_jacobian!(SimulationWorkspace(cc),cc,x;temperature)
        @test r≈expected+1e5*(storage-q)
        @test Matrix(j)≈Matrix(g+1e5*c)
    end
    @test ws.constant_assemblies==assemblies
    tuned=with_parameters(cc,"Q1.forward_beta"=>90.)
    @test tuned.parameters.matrix_fingerprint==cc.parameters.matrix_fingerprint
    r,j=Amber._step_residual_jacobian!(ws,tuned,x,q,0.,1e5)
    expected,g=Amber.residual_jacobian(tuned,x,x,0.,0.)
    storage,c=storage_jacobian!(SimulationWorkspace(tuned),tuned,x)
    @test r≈expected+1e5*(storage-q)
    @test Matrix(j)≈Matrix(g+1e5*c)
    @test ws.constant_assemblies==assemblies
end

@testset "AC symbolic reuse" begin
    cc=compile(LowPass()); fs=[0.,1e2,1e4,1e6]
    ac=small_signal(cc,fs;solver=SolverOptions(linear_solver=SuiteSparseLU(ordering=:natural)))
    @test ac.stats[:symbolic_factorizations]==1
    @test ac.stats[:numeric_factorizations]==length(fs)
    # Independent RC transfer function, including DC.
    @test voltage(ac,:vout)≈1 ./ (1 .+ im*2π.*fs.*1e4.*1e-8)
end

@testset "resolved parameter updates" begin
    cc=compile(compiler_ladder())
    handle=parameter_handle(cc,"stage[1:3].R1.value")
    changed=with_parameters(cc,handle=>2e3,"stage[2].R1.value"=>3e3,handle=>4e3)
    resistors=only(b for b in changed.parameters.batches if b isa ResistorBatch)
    original=only(b for b in cc.parameters.batches if b isa ResistorBatch)
    @test resistors.conductance[1:3]==fill(1/4e3,3)
    @test original.conductance[1:3]==1 ./ [1e3,2e3,3e3]
    @test resistors.p===original.p
    @test with_parameters(changed,handle=>5e3).topology===cc.topology
    @test_throws ArgumentError with_parameters(compile(compiler_ladder()),handle=>2e3)
    @test_throws ParameterUpdateError with_parameters(cc,handle=>1+im)
    @test_throws KeyError parameter_handle(cc,"missing.value")
    @test_throws TopologyParameterError parameter_handle(cc,"stage[1].R1.package")
    # Applying a valid update followed by a bad one must not mutate the input.
    @test_throws KeyError with_parameters(cc,handle=>9e3,"missing.value"=>1.)
    @test original.conductance[1:3]==1 ./ [1e3,2e3,3e3]
    direct=with_parameters(cc,handle=>4e3)
    @test changed.parameters.fingerprint==direct.parameters.fingerprint
    @test changed.parameters.matrix_fingerprint==direct.parameters.matrix_fingerprint
end

@testset "equation structural analysis" begin
    @circuit StructuralRC() begin
        gnd=ground(); a=node()
        G=conductance(a,gnd;value=0.)
        C=capacitor(a,gnd;value=1e-9)
    end
    cc=compile(StructuralRC())
    dc=structural_analysis(cc); dynamic=structural_analysis(cc;mode=:time)
    @test dc.unmatched_equations==[1]
    @test dc.unmatched_unknowns==[1]
    @test !dc.incidence[1,1] # the gmin allocation must not conceal the missing DC equation
    @test isempty(dynamic.unmatched_equations)
    @test dynamic.incidence[1,1]
    @test_throws ArgumentError structural_analysis(cc;mode=:invalid)
    @circuit FeedForward() begin
        gnd=ground(); input=node(); output=node()
        V=voltage_source(input,gnd;dc=1.)
        E=voltage_controlled_voltage_source(input,gnd,output,gnd;gain=2.)
        R=resistor(output,gnd;value=1e3)
    end
    cc=compile(FeedForward()); analysis=structural_analysis(cc)
    @test isempty(analysis.unmatched_equations)
    @test sort(vcat(analysis.blocks...))==collect(1:cc.n)
    block_of=zeros(Int,cc.n)
    for (block,rows) in enumerate(analysis.blocks), row in rows; block_of[row]=block end
    for row in 1:cc.n, column in 1:cc.n
        analysis.incidence[row,column] || continue
        dependency=analysis.unknown_to_equation[column]
        @test block_of[dependency]<=block_of[row]
    end
    # An augmenting path must move an earlier match to find the full rank.
    eq,unknown=Amber._structural_matching([[1,2],[1]],2)
    @test eq==[2,1]
    @test unknown==[2,1]
end
