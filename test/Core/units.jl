@testset "SI unit scales" begin
    prefixes=(:f=>1e-15,:p=>1e-12,:n=>1e-9,:μ=>1e-6,:m=>1e-3,
        :k=>1e3,:M=>1e6,:G=>1e9,:T=>1e12)
    for unit in (:Ω,:V,:A,:F,:H,:C,:s,:Hz,:S,:K)
        @test getfield(Amber,unit)==1.0
        @test unit in names(Amber)
        for (prefix,scale) in prefixes
            name=Symbol(prefix,unit)
            @test getfield(Amber,name)==scale
            @test name in names(Amber)
        end
    end
    @test m==1.0
    @test mm==1e-3
    @test μm==1e-6
    @test km==1e3
    @test all(name->name in names(Amber),(:m,:fm,:pm,:nm,:μm,:mm,:km,:Mm,:Gm,:Tm))
end
