@testset "charge-based MOS physics" begin
    m=ChargeBasedMOSFET(width=4μm,length=2μm)
    @test_throws ArgumentError ChargeBasedMOSFET(width=0.)
    @test_throws ArgumentError ChargeBasedMOSFET(slope_factor=.9)
    @test_throws ArgumentError ChargeBasedMOSFET(mobility=NaN)
    @test_throws ArgumentError with_model_parameter(m,:length,-1.)
    @test_throws ArgumentError mosfet_operating_point(m,:nmos,1.,1.,0.,0.;temperature=0.)
    for v in ([1.,-.2,0.,0.], [1.,.7,0.,0.], [1.,1.5,0.,-.2],
              [0.,1.5,1.,-.2], [0.,1.,0.,0.], [1e-10,1.,0.,0.])
        point=mosfet_operating_point(m,:nmos,v...)
        shifted=mosfet_operating_point(m,:nmos,(v .+ 3)...)
        opposite=mosfet_operating_point(m,:pmos,(-v)...)
        @test point.id≈shifted.id rtol=1e-11 atol=1e-20
        @test point.id≈-opposite.id rtol=1e-12 atol=1e-20
        @test collect(values(point.charges))≈-collect(values(opposite.charges))
        @test abs(sum(point.charges))<1e-28
        @test maximum(abs,sum(point.capacitance_matrix;dims=1))<1e-28
        @test maximum(abs,sum(point.capacitance_matrix;dims=2))<1e-28
        reverse=mosfet_operating_point(m,:nmos,v[3],v[2],v[1],v[4])
        @test point.id≈-reverse.id atol=1e-20
        @test point.charges.source≈reverse.charges.drain
        @test point.charges.drain≈reverse.charges.source
        # Independent voltage differences check analytic current and charge derivatives.
        numerical=Amber._jacobian(z->collect(values(terminal_charges(m,:nmos,z...))),v)
        @test norm(point.capacitance_matrix-numerical)<1e-6*max(norm(numerical),1e-20)
        ji=Amber._jacobian(z->[mosfet_operating_point(m,:nmos,z...).id],v)
        analytic=Amber._mosfet_channel(m,:nmos,v...)[2]
        @test norm(vec(ji)-collect(analytic))<1e-6*max(norm(ji),1e-20)
    end
    weak=mosfet_operating_point(m,:nmos,1.,-.2,0.,0.)
    @test weak.id>0
    @test weak.gm_over_id≈1/(m.slope_factor*Amber._thermal_voltage(300.)) rtol=1e-8
    strong=mosfet_operating_point(m,:nmos,100.,50.,0.,0.)
    beta=m.mobility*m.oxide_capacitance*m.width/m.length
    @test strong.id≈beta/(2m.slope_factor)*(50-m.threshold_voltage)^2 rtol=.02
    @test strong.charges.drain/strong.charges.source≈2/3 rtol=.01
    nominal=mosfet_operating_point(m,:nmos,1.,1.,0.,0.)
    for field in (:width,:multiplicity)
        doubled=mosfet_operating_point(with_model_parameter(m,field,2getproperty(m,field)),:nmos,1.,1.,0.,0.)
        @test doubled.id≈2nominal.id
        @test doubled.charges.gate≈2nominal.charges.gate
    end
    longer=mosfet_operating_point(with_model_parameter(m,:length,2m.length),:nmos,1.,1.,0.,0.)
    @test longer.id≈nominal.id/2
    @test longer.charges.gate≈2nominal.charges.gate
    @test mosfet_operating_point(m,:nmos,1.,1.,0.,0.;temperature=350.).id != nominal.id
    clm=with_model_parameter(m,:channel_length_modulation,.05)
    @test mosfet_operating_point(clm,:nmos,1.,1.,0.,0.).gds>nominal.gds
    # Check the nonlinear-charge Hessian directly, without large circuit rows
    # masking the small capacitance derivatives in a global Jacobian norm.
    for v in ([.1,.7,0.,-.1],[1.,1.,0.,0.],[0.,1.,0.,0.])
        e=Amber._charge_mos_evaluate(clm,:nmos,v)
        for terminal in 1:4
            numerical=Amber._jacobian(z->collect(Amber._charge_mos_evaluate(clm,:nmos,z).charges[terminal].gradient),v)
            analytic=[e.charges[terminal].hessian[(i-1)*4+j] for i in 1:4,j in 1:4]
            @test norm(analytic-numerical)<2e-6*max(norm(numerical),1e-20)
        end
    end
    # In equilibrium the channel thermal conductance must equal the DC conductance.
    equilibrium=Amber._charge_mos_evaluate(m,:nmos,(0.,1.,0.,0.))
    @test equilibrium.thermal_conductance≈equilibrium.channel.gradient[1] rtol=1e-12
    # Independently integrate the channel profile and linear terminal partition.
    for (vd,vg) in ((0.,1.),(.1,.8),(2.,1.5))
        op=mosfet_operating_point(m,:nmos,vd,vg,0.,0.)
        a=op.source_inversion; b=op.drain_inversion
        xs=range(0.,1.;length=10001)
        density=[let f=(1-x)*(a*a+a)+x*(b*b+b); 2f/(1+sqrt(1+4f)) end for x in xs]
        integral=sum((xs[k]*density[k]+xs[k+1]*density[k+1])/2 for k in 1:length(xs)-1)/(length(xs)-1)
        scale=-2m.slope_factor*m.oxide_capacitance*m.width*m.length*Amber._thermal_voltage(300.)
        @test op.charges.drain≈scale*integral rtol=2e-6
    end
    junction=ChargeBasedMOSFET(drain_area=1e-12,source_area=2e-12,
        drain_perimeter=4e-6,source_perimeter=6e-6,gate_source_overlap=1e-10,
        gate_drain_overlap=2e-10,gate_bulk_capacitance=1e-15)
    for v in ([1.,-.5,0.,0.],[-.4,-.5,0.,0.],[-.7,-.5,0.,0.])
        e=Amber._charge_mos_evaluate(junction,:nmos,v)
        @test abs(sum(x.value for x in e.currents))<1e-18
        @test abs(sum(x.value for x in e.charges))<1e-28
        numerical=Amber._jacobian(z->collect(values(terminal_charges(junction,:nmos,z...))),v)
        @test norm(numerical-[e.charges[i].gradient[j] for i in 1:4,j in 1:4])<1e-6*norm(numerical)
    end
    forward=mosfet_operating_point(junction,:nmos,-.4,-.5,0.,0.)
    @test forward.currents.bulk>0
    @test forward.currents.drain<0
end

@testset "charge-based MOS circuit integration" begin
    model=ChargeBasedMOSFET(width=4μm,length=2μm,gate_drain_overlap=1e-10,
        drain_area=1e-12,source_area=1e-12)
    @circuit ChargeMOSBias(;gate_voltage=1.,waveform=nothing) begin
        gnd=ground(); drain=node(); gate=node()
        VD=voltage_source(drain,gnd;dc=1.)
        VG=voltage_source(gate,gnd;dc=gate_voltage,ac=1.,waveform)
        M=nmos(drain,gate,gnd,gnd;model,width=8μm)
    end
    design=ChargeMOSBias(); compiled=compile(design)
    result=operating_point(compiled)
    @test result.stats[:converged]
    point=mosfet_operating_point(result,:M)
    @test current(result,:M)[1]≈point.currents.drain
    @test terminal_charges(result,:M).gate[1]≈point.charges.gate
    @test_throws ArgumentError region(result,:M)
    @test point.id≈2mosfet_operating_point(model,:nmos,1.,1.,0.,0.).id
    tuned=with_parameters(compiled,"M.width"=>16μm)
    @test tuned.topology===compiled.topology
    @test mosfet_operating_point(operating_point(tuned),:M).id≈2point.id
    text=serialize_circuit(design); restored=deserialize_circuit(text)
    @test serialize_circuit(restored)==text
    @test current(operating_point(restored),:M)≈current(result,:M)
    state=result.values[:,1]; previous=state .- range(.001,.004;length=compiled.n); alpha=1e6
    _,analytic=Amber.residual_jacobian(compiled,state,previous,0.,alpha)
    numerical=Amber._jacobian(z->Amber.residual(compiled,z,alpha.*(z.-previous),0.),state)
    @test norm(Matrix(analytic)-numerical)<1e-6*norm(numerical)
    # Excite one terminal: AC terminal current must match G + jω dQ/dV at the bias.
    ac=small_signal(design,[1e3,1e6];source=:VG)
    @test current(ac,:M,:gate)≈im.*2π.*ac.axis.*point.capacitance_matrix[2,2]
    @test current(ac,:M,:drain)≈point.gm .+ im.*2π.*ac.axis.*point.capacitance_matrix[1,2]
    @test maximum(abs,sum(current(ac,:M,terminal) for terminal in (:drain,:gate,:source,:bulk)))<1e-18
    @test terminal_charges(ac,:M).gate≈fill(point.capacitance_matrix[2,2],2)
    transient_result=transient(ChargeMOSBias(waveform=Sine(offset=1.,amplitude=.01,frequency=1e5)),
        0. => 2e-5;max_step=1e-7)
    @test transient_result.stats[:converged]
    @test maximum(abs,sum(current(transient_result,:M,terminal) for terminal in (:drain,:gate,:source,:bulk)))<1e-18
    @test maximum(abs,sum(values(terminal_charges(transient_result,:M))))<1e-27
    @circuit ChargeMOSAmplifier() begin
        gnd=ground(); supply=node(); gate=node(); output=node()
        VDD=voltage_source(supply,gnd;dc=1.8)
        VG=voltage_source(gate,gnd;dc=1.,ac=1.)
        R=resistor(supply,output;value=10kΩ)
        M=nmos(output,gate,gnd,gnd;model)
        C=capacitor(output,gnd;value=1pF)
    end
    amplifier=ChargeMOSAmplifier()
    @test real(voltage(small_signal(amplifier,[1e3];source=:VG),:output)[1])<0
    nr=noise(amplifier,[1e3,1e4];output=voltage(:output))
    @test all(>(0),noise_density(nr))
    @test any(contains("ChargeBasedMOSFET"),validity_report(nr)[:warnings])
end

@testset "charge-based CMOS switching" begin
    model=ChargeBasedMOSFET(channel_length_modulation=.02)
    @circuit ChargeInverter() begin
        gnd=ground(); supply=node(); input=node(); output=node()
        VDD=voltage_source(supply,gnd;dc=1.8)
        VG=voltage_source(input,gnd;dc=0.,waveform=Pulse(low=0.,high=1.8,
            frequency=1e7,rise=2ns,fall=2ns))
        MP=pmos(output,input,supply,supply;model,width=4μm)
        MN=nmos(output,input,gnd,gnd;model,width=4μm)
        CL=capacitor(output,gnd;value=10fF)
    end
    for method in (:bdf1,:bdf2)
        tr=transient(ChargeInverter(),0s=>200ns;max_step=.5ns,method,event_mode=:exact)
        @test tr.stats[:converged]
        @test minimum(voltage(tr,:output))<.1
        @test maximum(voltage(tr,:output))>1.7
    end
end
