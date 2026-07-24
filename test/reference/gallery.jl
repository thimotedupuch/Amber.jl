@testset "on-disk example gallery" begin
    root=normpath(joinpath(@__DIR__,"..","..","examples"))
    files=[
        "01_practical_rc/circuit.jl",
        "02_diode_rectifier/circuit.jl",
        "03_common_emitter/circuit.jl",
        "04_differential_pair/circuit.jl",
        "05_wien_oscillator/circuit.jl",
        "06_sample_and_hold/circuit.jl",
        "07_rlgc_line/generator.jl",
        "08_diagnostics/invalid_circuits.jl",
    ]
    modules=Module[]
    for file in files
        example_module=Module(gensym(:AmberExample))
        Base.include(example_module,joinpath(root,file)); push!(modules,example_module)
    end
    @test isempty(check(getfield(modules[1],:PracticalLowPass)()))
    @test isempty(check(getfield(modules[2],:HalfWaveRectifier)()))
    amplifier=getfield(modules[3],:CommonEmitterAmplifier)()
    amplifier_op=operating_point(amplifier)
    @test amplifier_op.stats[:converged]
    @test region(amplifier_op,:Q1)==ForwardActive
    amplifier_ac=small_signal(amplifier,1kHz=>1kHz;source=:Input)
    amplifier_gain=transfer(amplifier_ac;input=voltage(:src),output=voltage(:out))
    @test abs(amplifier_gain[1])>10
    @test operating_point(getfield(modules[4],:DifferentialPair)()).stats[:converged]
    @test isempty(check(getfield(modules[5],:WienOscillator)()))
    @test isempty(check(getfield(modules[6],:SampleAndHold)()))
    @test length(getfield(modules[7],:RLGCLine)(sections=5).components)==22
    @test !isempty(check(getfield(modules[8],:ContradictorySources)()))
    @test !isempty(check(getfield(modules[8],:FloatingInput)()))
end
