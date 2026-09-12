# Run with Amber, AmberMakie, CairoMakie and Random available.
using Amber, AmberMakie, CairoMakie, Random
CairoMakie.activate!()
set_theme!(theme_amber_light())
output_dir=get(ENV,"AMBERMAKIE_DEMO_OUTPUT",joinpath(@__DIR__,"generated"))
mkpath(output_dir)

@circuit StudyInverter(;vdd=1.8,load=10e-15,switching=false) begin
    gnd=ground(); supply=node(); input=node(); output=node()
    model=ChargeBasedMOSFET(channel_length_modulation=.02)
    VDD=voltage_source(supply,gnd;dc=vdd)
    VG=voltage_source(input,gnd;dc=0.,waveform=switching ?
        Pulse(low=0.,high=vdd,frequency=1e7,rise=2e-9,fall=2e-9) : nothing)
    MN=nmos(output,input,gnd,gnd;model,width=4e-6)
    MP=pmos(output,input,supply,supply;model,width=4e-6)
    CL=capacitor(output,gnd;value=load)
end

transfer_sweep=sweep(StudyInverter(),"VG.dc"=>range(0,1.8;length=401))
transfer=inverterview(transfer_sweep;output=:output)
@assert isempty(transfer.warnings)
fig=Figure(size=(800,800)); inverterplot(fig[1,1],transfer)
save(joinpath(output_dir,"34_inverter_noise_margins.png"),fig)

switching=switchingview(;loads=[5e-15,20e-15,80e-15],supplies=[1.5,1.8,2.1]) do load,vdd
    result=transient(StudyInverter(;load,vdd,switching=true),0.0 =>210e-9;
        max_step=.5e-9,method=:bdf2,event_mode=:exact)
    measurements=switchingmetrics(result;input=:input,output=:output,supply=:VDD,vdd,
        window=100e-9=>200e-9)
    merge(measurements,(result=result,))
end
@assert isempty(switching.failures)
@assert all(p->isfinite(p.tphl)&&isfinite(p.tplh)&&p.energy>0,switching.points)
fig=Figure(size=(1400,500)); switchingplot(fig[1,1],switching)
save(joinpath(output_dir,"35_cmos_delay_energy.png"),fig)

# Input-referred mismatch of a pair with ideal source/drain clamps:
# both sources/bulks at 0 V, drains at 1 V, gates at 1 V ± offset/2.
# Find the differential gate voltage that balances drain currents.
# Illustrative independent threshold and mobility variation; NOT a process kit.
@circuit OffsetPair(;left,right,offset) begin
    gnd=ground(); drain=node(); ga=node(); gb=node()
    VD=voltage_source(drain,gnd;dc=1.)
    VA=voltage_source(ga,gnd;dc=1.0 + offset/2)
    VB=voltage_source(gb,gnd;dc=1.0 - offset/2)
    MA=nmos(drain,ga,gnd,gnd;model=left)
    MB=nmos(drain,gb,gnd,gnd;model=right)
end
function offset_sample(width,len,temperature,z)
    area_um2=width*len/1e-12
    left=ChargeBasedMOSFET(;width,length=len,threshold_voltage=.7+.003z[1]/sqrt(area_um2),
        mobility=.04*(1+.01z[2]/sqrt(area_um2)))
    right=ChargeBasedMOSFET(;width,length=len,threshold_voltage=.7+.003z[3]/sqrt(area_um2),
        mobility=.04*(1+.01z[4]/sqrt(area_um2)))
    residual(v)=mosfet_operating_point(left,:nmos,1.,1.0 + v/2,0.,0.;temperature).id-
        mosfet_operating_point(right,:nmos,1.,1.0 - v/2,0.,0.;temperature).id
    lo,hi=-.2,.2
    residual(lo)<0<residual(hi) || error("offset outside bracket")
    for _ in 1:42
        mid=(lo+hi)/2
        if residual(mid)>0; hi=mid; else; lo=mid; end
    end
    offset=(lo+hi)/2
    result=operating_point(OffsetPair(;left,right,offset);temperature)
    result.stats[:converged] || error("pair bias failed")
    @assert isapprox(only(current(result,:MA,:drain)),only(current(result,:MB,:drain));rtol=1e-8)
    (offset=offset,left=left,right=right,result=result)
end
# Reuse each random draw across conditions to track the same virtual pair.
seeds=rand(MersenneTwister(2026),UInt64,32)
groups=map(Iterators.product([275.,350.],[1e-6,4e-6])) do (temperature,width)
    records=Any[]; samples=Union{Nothing,Float64}[]; failures=NamedTuple[]
    for seed in seeds
        try
            sample=offset_sample(width,1e-6,temperature,randn(MersenneTwister(seed),4))
            push!(records,sample); push!(samples,sample.offset)
        catch e
            e isa InterruptException && rethrow()
            push!(records,nothing); push!(samples,nothing)
            push!(failures,(seed=seed,message=sprint(showerror,e)))
        end
    end
    (temperature=temperature,width=width,length=1e-6,samples=samples,seeds=seeds,
        records=records,failures=failures)
end
mismatch=mismatchview(vec(groups))
@assert all(g->g.failed==0,mismatch.groups)
fig=Figure(size=(1300,750)); mismatchplot(fig[1,1],mismatch)
save(joinpath(output_dir,"36_cmos_offset_mismatch.png"),fig)
println("Saved CMOS studies to ",output_dir)
