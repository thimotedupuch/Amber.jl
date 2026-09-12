@testset "CMOS characterization and rendering" begin
    model=ChargeBasedMOSFET(width=8μm,length=2μm,channel_length_modulation=.02)
    view=mosfetview(model;vgs=range(.1,1.4;length=31),vds=[.05,.6,1.2])
    @test size(view.points)==(31,3)
    @test view.points[12,2]==mosfet_operating_point(model,:nmos,.6,view.vgs[12],0.,0.)
    @test view.provenance[:parameters].width==8μm
    pview=mosfetview(model;kind=:pmos,vgs=view.vgs,vds=view.vds)
    @test pview.points[12,2].id≈-view.points[12,2].id
    @test pview.points[12,2].gm_over_id≈view.points[12,2].gm_over_id
    @test_throws ArgumentError mosfetview(model;vgs=[1.,0.])
    @test_throws ArgumentError mosfetview(model;vds=[])
    @test_throws ArgumentError mosfetview(model;vgs=[0.,NaN])
    directory=mktempdir()
    for (name,handle) in (("transfer",mosfetplot(Figure()[1,1],view;scale=:log)),
            ("gmid",gmidplot(Figure()[1,1],pview)),
            ("capacitance",capacitanceplot(Figure()[1,1],view.points[12,2])),
            ("output",mosfetplot(Figure()[1,1],mosfetview(model;
                vgs=[.6,.8,1.,1.2],vds=range(0.,1.8;length=41));x=:vds)))
        path=joinpath(directory,name*".png")
        savefigure(path,handle)
        @test filesize(path)>1000
        if name == "capacitance"
            @test any(<(0),handle.plots.capacitance[3][])
            @test handle.plots.capacitance[3][][1,2]≈view.points[12,2].capacitance_matrix[2,1]*1e15
        end
    end
    h=workbench(view)
    selectbias!(h;vgs=view.vgs[20],vds=1.2)
    @test h.measurements[:selected_point][]==view.points[20,3]
    @test h.measurements[:drain_control].i_selected[]==3
    @test h.measurements[:gate_control].value[]==view.vgs[20]
    @test occursin("1.2",h.measurements[:bias_readout][])
    recipe=copyrecipe(h)
    @test occursin("ChargeBasedMOSFET",recipe)
    @test occursin("selectbias!",recipe)
    # Replaying the exported Julia recipe must reconstruct the selected model/bias.
    rebuilt=Core.eval(@__MODULE__,Meta.parse("begin\n"*recipe*"\nhandle\nend"))
    @test rebuilt.measurements[:selected_point][]==h.measurements[:selected_point][]
    close(rebuilt)
    path=joinpath(directory,"cmos.png"); savefigure(path,h)
    metadata=TOML.parsefile(path*".toml")
    @test metadata["provenance"]["parameters"]["width"]==8μm
    @test metadata["measurements"]["selected_drain"]==3
    close(h); close(h)
    @test_throws ArgumentError selectbias!(h;vgs=1.)
end

@testset "plot regression cases" begin
    @circuit PlotRegressionSignal() begin
        gnd=ground(); input=node(); output=node()
        VG=voltage_source(input,gnd;waveform=Sine(amplitude=1.,frequency=1e3))
        R=resistor(input,output;value=1e3)
        C=capacitor(output,gnd;value=1e-7)
    end
    tr=transient(PlotRegressionSignal(),0s=>2ms;saveat=10μs,max_step=10μs)
    h=workbench(tr;signals=[:input,:output,current(:R)])
    setcursor!(h.cursors,:a,.00025); setinterval!(h.cursors,.0001=>.001)
    selectsignal!(h,:output)
    expected=cursor_readout(tr.axis,voltage(tr,:output),h.cursors.a[],h.cursors.b[])
    @test h.cursors.readout[].a.y==expected.a.y
    @test h.cursors.interval_readout[].rms≈interval_readout(tr.axis,voltage(tr,:output),.0001=>.001).rms
    selectsignal!(h,current(:R))
    setcursor!(h.cursors,:a,.0005)
    @test h.cursors.readout[].a.y==nearest_sample(tr.axis,current(tr,:R),.0005).y
    @test occursin("A",h.measurements[:interval_text][])
    @test h.axes.trace.ylabel[] == "A"
    @test maximum(abs,h.axes.trace.limits[][2]) < .01
    showalltraces!(h)
    @test h.axes.trace.ylabel[] == "Value (mixed units)"
    isolatetrace!(h,"[2]")
    @test h.measurements[:selected_signal][] == :output
    @test h.measurements[:signal_control].i_selected[] == 2
    @test h.cursors.readout[].a.y==nearest_sample(tr.axis,voltage(tr,:output),.0005).y
    @test occursin("s",h.measurements[:cursor_text][])
    directory=mktempdir(); savefigure(joinpath(directory,"transient.png"),h); close(h)
    spectrum_result=spectrum(tr;signal=:output)
    @test_throws ArgumentError spectrumplot(Figure()[1,1],spectrum_result;frequency_scale=:log,include_dc=true)
    fig=Figure(size=(1000,450))
    spectrogramplot(fig[1,1],tr;signal=:output,samples=64)
    traceplot(fig[1,2],tr;signals=:output)
    save(joinpath(directory,"spectrogram.png"),fig)
    sweep_result=Amber.SweepResult("bias",Any[0.,1.,2.],Any[0.,nothing,2.],
        Any[nothing,nothing,nothing],BitVector([true,false,true]),
        [Amber.SweepFailure(2,1.,:ConvergenceError,"failed")],Amber.OperatingPoint(),Dict{Symbol,Any}())
    sh=sweepplot(Figure()[1,1],sweep_result)
    @test any(p->isnan(p[2]),sh.plots.curve[1][])
    @test AmberMakie._finite_derivative([0.,1.,3.],[0.,1.,9.])[2]≈2.
    @circuit QuietResistor() begin
        gnd=ground(); output=node()
        R=resistor(output,gnd;value=1.)
    end
    nr=noise(QuietResistor(),[10.,100.,1000.];output=voltage(:output))
    budget=noisebudgetplot(Figure()[1,1],nr)
    @test budget.view.floor_value < minimum(noise_psd(nr))/100
    savefigure(joinpath(directory,"budget.png"),budget)
    @circuit ClampedResistor() begin
        gnd=ground(); output=node()
        R=resistor(output,gnd;value=1.)
        V=voltage_source(output,gnd;dc=0.)
    end
    zero_noise=noise(ClampedResistor(),[10.,100.,1000.];output=voltage(:output))
    @test all(iszero,noise_density(zero_noise))
    nh=noiseplot(Figure()[1,1],zero_noise)
    @test nh.axes.noise.yscale[]===identity
    savefigure(joinpath(directory,"zero-noise.png"),nh)
    savefigure(joinpath(directory,"zero-budget.png"),noisebudgetplot(Figure()[1,1],zero_noise))
end
