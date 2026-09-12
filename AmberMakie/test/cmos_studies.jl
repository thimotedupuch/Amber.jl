@testset "CMOS study measurements and plots" begin
    x=collect(range(0,1.8;length=1001)); y=1.8./(1 .+ exp.(12 .* (x.-.9)))
    v=inverterview(x,y); m=v.measurements
    @test m.vm≈.9
    q=(1-sqrt(1-4/(1.8*12)))/2
    @test m.vil≈.9-log((1-q)/q)/12 atol=2e-5
    @test m.nml≈m.nmh atol=1e-12
    @test 0<m.vil<m.vm<m.vih<1.8
    @test m.voh≈AmberMakie._cmos_interp(x,y,m.vil)
    z=copy(y); z[500]=NaN
    @test isnan(inverterview(x,z).measurements.nml)
    roundoff=copy(y); roundoff[2]=roundoff[1]+1e-13
    @test isfinite(inverterview(x,roundoff).measurements.nml)
    @test isnan(inverterview(x,roundoff;monotonic_atol=0).measurements.nml)
    @test isnan(inverterview([0.,1.],[1.,0.]).measurements.nml)
    @test_throws ArgumentError inverterview([0.,0.],[1.,0.])
    @test_throws ArgumentError inverterview(x,[0.])
    # Piecewise linear input: rises at 1, falls at 3; output delays .2/.4.
    t=sort(unique(vcat(collect(0.:.05:5.),[.9,1.1,2.9,3.1,1.1,1.3,3.3,3.5])))
    vin=[q<2 ? clamp((q-.9)/.2,0,1) : clamp((3.1-q)/.2,0,1) for q in t]
    vout=[q<2 ? 1-clamp((q-1.1)/.2,0,1) : clamp((q-3.3)/.2,0,1) for q in t]
    p=2 .* t .+ 1
    s=switchingmetrics(t,vin,vout,p;vdd=1.,window=.25=>4.75)
    @test s.tphl≈.2 atol=1e-12
    @test s.tplh≈.4 atol=1e-12
    @test s.energy≈27.
    @test isnan(switchingmetrics(t,vin,ones(length(t)),p;vdd=1.,window=.25=>4.75).tphl)
    ring=copy(vout); ring[1.8 .< t .< 2.2].=1.
    @test isnan(switchingmetrics(t,vin,ring,p;vdd=1.,window=.25=>4.75).tphl)
    @test_throws ArgumentError switchingmetrics(t,vin,vout,p;vdd=1.,window=-1=>4)
    @test_throws ArgumentError switchingmetrics(t,vin,vout,p;vdd=0.,window=0=>4)
    sw=switchingview(;loads=[1e-14,2e-14],supplies=[1.,1.8]) do load,vdd
        load==2e-14 && vdd==1. && error("test failure")
        s
    end
    @test length(sw.failures)==1
    @test sw.points[2,1]===nothing
    @test occursin("test failure",only(sw.failures).message)
    mm=mismatchview([(temperature=300.,width=1e-6,length=1e-6,samples=[-1.,0.,1.,missing]),
        (temperature=350.,width=1e-6,length=1e-6,samples=[nothing,NaN])])
    @test mm.groups[1].mean==0
    @test mm.groups[1].std==1
    @test mm.groups[1].failed==1
    @test isnan(mm.groups[2].mean)
    @test_throws ArgumentError mismatchview([mm.groups[1].source,mm.groups[1].source])
    fig=Figure(size=(1400,1000))
    @test inverterplot(fig[1,1],v).view===v
    @test switchingplot(fig[2,:],sw).view===sw
    @test mismatchplot(fig[1,2],mm).view===mm
    mktempdir() do dir
        save(joinpath(dir,"studies.png"),fig)
        @test filesize(joinpath(dir,"studies.png"))>1000
    end
end
