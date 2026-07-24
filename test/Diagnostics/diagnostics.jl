@testset "structural diagnostics" begin
    @circuit Bad() begin
        gnd=ground(); n=node(); V1=voltage_source(n,gnd;dc=5V); V2=voltage_source(n,gnd;dc=3V)
    end
    @test any(d->d.severity==:error,check(Bad()))
    c=Circuit(:FloatingIsland); g=ground!(c,:gnd); add!(c,resistor(g,g;value=1kΩ);name=:reference)
    a=node!(c,:a); b=node!(c,:b); add!(c,capacitor(a,b;value=10nF);name=:C1)
    @test any(d->occursin("no finite DC path",d.message),check(c))
    @circuit BadLoop() begin
        gnd=ground(); a=node(); b=node(); V1=voltage_source(a,gnd;dc=1V)
        V2=voltage_source(b,a;dc=1V); V3=voltage_source(b,gnd;dc=3V)
    end
    @test any(d->occursin("inconsistent loop",d.message),check(BadLoop()))
    @circuit IdealInductorLoop() begin
        gnd=ground(); a=node(); b=node()
        L1=inductor(gnd,a;value=1mH); L2=inductor(a,b;value=1mH); L3=inductor(b,gnd;value=1mH)
    end
    @test any(d->occursin("ideal voltage-constraint loop",d.message),check(IdealInductorLoop()))
end
