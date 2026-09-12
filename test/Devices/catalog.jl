@subcircuit CatalogueTemplate(input,output,reference) begin
    T=ideal_transformer(input,reference,output,reference;ratio=2.)
    varistor(output,reference)
end

@testset "expanded device catalogue" begin
    # All constructors must compile, solve and survive a persistence round trip.
    constructors = (
        (:zener,(x,g)->zener(x,g),-.1),
        (:schottky,(x,g)->schottky(x,g),.1),
        (:led,(x,g)->led(x,g),.1),
        (:photodiode,(x,g)->photodiode(x,g;photocurrent=1e-3),-.1),
        (:solar_cell,(x,g)->solar_cell(x,g;photocurrent=.01),.1),
        (:varistor,(x,g)->varistor(x,g;vref=1.),.5),
        (:thermistor,(x,g)->thermistor(x,g),.5),
        (:njfet,(x,g)->njfet(x,g,g),1.),
        (:pjfet,(x,g)->pjfet(x,g,g),-1.),
        (:vcr,(x,g)->voltage_controlled_resistor(x,g,x,g),.5),
        (:crystal,(x,g)->crystal(x,g),.5))
    for (label,constructor,bias) in constructors
        @testset "$label persistence and DC" begin
            b=CircuitBuilder(label); g=ground!(b,:gnd); x=node!(b,:x)
            add!(b,voltage_source(x,g;dc=bias);name=:supply)
            add!(b,constructor(x,g);name=:dut)
            design=finish(b); restored=deserialize_circuit(serialize_circuit(design))
            @test serialize_circuit(restored)==serialize_circuit(design)
            result=operating_point(restored)
            @test result.stats[:converged]
            @test voltage(result,:x)[1]≈bias
        end
    end

    @circuit CatalogSignals begin
        g=ground(); x=node(); y=node(); product=node(); limited=node(); decision=node()
        voltage_source(x,g;dc=.2,ac=1.); voltage_source(y,g;dc=3.)
        analog_multiplier(x,g,y,g,product,g;gain=2.)
        voltage_limiter(x,g,limited,g;low=-2.,high=2.,gain=3.)
        comparator(x,g,decision,g)
        resistor(product,g;value=1e3); resistor(limited,g;value=1e3); resistor(decision,g;value=1e3)
    end
    design=deserialize_circuit(serialize_circuit(CatalogSignals()))
    op=operating_point(design)
    @test voltage(op,:product)[1]≈1.2
    @test voltage(op,:limited)[1]≈2tanh(.3)
    @test voltage(op,:decision)[1]≈5.
    ac=small_signal(design,[100.])
    @test voltage(ac,:product)[1]≈6.
    @test voltage(ac,:limited)[1]≈3/cosh(.3)^2

    @circuit CatalogTransformer begin
        g=ground(); p=node(); s=node(); w=node()
        supply=voltage_source(p,g;dc=10.)
        T=ideal_transformer(p,g,s,g;ratio=2.)
        potentiometer(s,w,g;resistance=100.,position=.25)
    end
    op=operating_point(deserialize_circuit(serialize_circuit(CatalogTransformer())))
    @test voltage(op,:s)[1]≈5.
    @test voltage(op,:w)[1]≈1.25
    @test current(op,:supply)[1]≈-.025

    @circuit CatalogLine begin
        g=ground(); input=node(); output=node()
        voltage_source(input,g;dc=1.,ac=1.,waveform=Step(high=1.,at=1e-7))
        transmission_line(input,output,g;resistance=10.,inductance=1e-6,capacitance=1e-9,sections=4)
        resistor(output,g;value=100.)
    end
    line=deserialize_circuit(serialize_circuit(CatalogLine()))
    @test voltage(operating_point(line),:output)[1]≈100/110
    @test abs(voltage(small_signal(line,[1.]),:output)[1])≈100/110 rtol=1e-6
    tr=transient(line,0. => 2e-6;max_step=1e-8)
    @test tr.stats[:converged]
    @test voltage(tr,:output)[end]≈100/110 rtol=.01

    for bias in (-5.,5.)
        b=CircuitBuilder(:Bridge); g=ground!(b,:gnd); x=node!(b,:x); p=node!(b,:p); n=node!(b,:n)
        add!(b,voltage_source(x,g;dc=bias))
        add!(b,bridge_rectifier(x,g,p,n);name=:bridge)
        add!(b,resistor(p,n;value=1e3))
        op=operating_point(deserialize_circuit(serialize_circuit(finish(b))))
        @test 3. < voltage(op,:p)[1]-voltage(op,:n)[1] < 4.
    end

    # Independent constitutive checks, including source/drain and polarity reversal.
    for polarity in (-1.,1.)
        law=Amber.CatalogLaw(:jfet,(.001,-2.,0.,polarity))
        @test law((polarity*3.,0.,0.,0.),0.)≈polarity*.001
        @test law((polarity*1.,0.,0.,0.),0.)≈polarity*.00075
        @test law((polarity*3.,polarity*(-3.),0.,0.),0.)==0.
        @test law((-polarity*3.,-polarity*3.,0.,0.),0.)≈-polarity*.001
    end
    laws=(Amber.CatalogLaw(:multiplier,(2.,.1)),Amber.CatalogLaw(:limiter,(-2.,3.,4.,.1)),
        Amber.CatalogLaw(:vcr,(1.,100.,.2,.4)),Amber.CatalogLaw(:varistor,(2.,.01,3.)),
        Amber.CatalogLaw(:jfet,(.001,-2.,.02,1.)),Amber.CatalogLaw(:jfet,(.001,-2.,.02,-1.)))
    for law in laws, x in (-4.,-.3,.3,4.), y in (-3.,-.2,2.)
        v=(x,y,0.,0.); analytic=Amber.CatalogGradient(law)(v,0.)
        for j in 1:4
            h=1e-6
            plus=ntuple(i->v[i]+(i==j ? h : 0.),4)
            minus=ntuple(i->v[i]-(i==j ? h : 0.),4)
            numerical=(law(plus,0.)-law(minus,0.))/(2h)
            @test analytic[j]≈numerical atol=1e-8 rtol=1e-5
        end
    end
    @test_throws ArgumentError zener(:a,:b;breakdown_voltage=-1.)
    @test_throws ArgumentError thermistor(:a,:b;temperature=0.)
    @test_throws ArgumentError potentiometer(:a,:w,:b;position=1.)
    @test_throws ArgumentError ideal_transformer(:a,:b,:c,:d;ratio=0.)
    @test_throws ArgumentError transmission_line(:a,:b,:g;sections=0)
    @test_throws ArgumentError njfet(:d,:g,:s;pinch_off=1.)
    @test_throws ArgumentError voltage_limiter(:a,:b,:c,:d;low=1.,high=0.)
    @test_throws ArgumentError varistor(:a,:b;exponent=.5)
end

@testset "catalogue physical references and assembly" begin
    @circuit CrystalReference begin
        g=ground(); x=node()
        supply=voltage_source(x,g;ac=1.)
        crystal(x,g;motional_resistance=20.,motional_inductance=.01,
            motional_capacitance=1e-10,shunt_capacitance=5e-12)
    end
    fs=[1e4,1/(2π*sqrt(.01*1e-10)),1e6]
    ac=small_signal(CrystalReference(),fs)
    for (i,f) in enumerate(fs)
        ω=2π*f
        expected=im*ω*5e-12+inv(20+im*ω*.01+inv(im*ω*1e-10))
        # AC extracts the small capacitance matrix by subtracting Jacobians.
        @test -current(ac,:supply)[i]≈expected rtol=1e-6
    end
    @circuit PhotoReference begin
        g=ground(); x=node()
        supply=voltage_source(x,g;dc=0.)
        photodiode(x,g;photocurrent=2e-3)
        thermistor(x,g;rnom=1e4,temperature=298.15)
    end
    @test current(operating_point(PhotoReference()),:supply)[1]≈2e-3
    # Series resistance must carry photocurrent as well as junction current.
    # With negligible junction conduction, the short-circuit current is set by
    # the photocurrent divider between series and shunt resistances.
    @circuit SolarSeriesReference begin
        g=ground(); x=node()
        supply=voltage_source(x,g;dc=0.)
        solar_cell(x,g;photocurrent=1e-3,shunt_resistance=100.,
            model=JunctionDiode(saturation_current=1e-30,series_resistance=100.))
    end
    solar=deserialize_circuit(serialize_circuit(SolarSeriesReference()))
    @test current(operating_point(solar),:supply)[1]≈.5e-3 rtol=1e-6
    @test thermistor(:a,:b;rnom=1e4,temperature=298.15).parameters.value≈1e4
    @test thermistor(:a,:b;rnom=1e4,temperature=320.).parameters.value<1e4
    @test Amber.CatalogLaw(:varistor,(100.,.001,10.))((100.,0.,0.,0.),0.)≈.001

    @circuit CatalogJacobian begin
        g=ground(); x=node(); y=node(); out=node()
        voltage_source(x,g;dc=.4); voltage_source(y,g;dc=-.2)
        voltage_controlled_resistor(x,g,y,g;rmin=10.,rmax=1e3)
        njfet(x,y,g)
        varistor(x,g;vref=1.,exponent=3.)
        analog_multiplier(x,g,y,g,out,g)
        resistor(out,g;value=100.)
    end
    compiled=compile(CatalogJacobian()); point=operating_point(compiled).values[:,1]
    _,analytic=Amber.residual_jacobian(compiled,point,point,0.,0.)
    numerical=Amber._jacobian(z->Amber.residual(compiled,z,zeros(length(z)),0.),point)
    @test Matrix(analytic)≈numerical atol=1e-7 rtol=1e-5

    b=CircuitBuilder(:CatalogueHierarchy); g=ground!(b,:g); x=node!(b,:x); y=node!(b,:y)
    add!(b,voltage_source(x,g;dc=2.))
    instance!(b,CatalogueTemplate;instance_name=:stage,connections=(input=x,output=y,reference=g))
    add!(b,resistor(y,g;value=1e3))
    restored=deserialize_circuit(serialize_circuit(finish(b)))
    @test voltage(operating_point(restored),:y)[1]≈1.
end
