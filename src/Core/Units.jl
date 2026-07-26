const _SI_PREFIX_SCALES=(f=1e-15,p=1e-12,n=1e-9,μ=1e-6,m=1e-3,k=1e3,M=1e6,G=1e9,T=1e12)

for unit in (:Ω,:V,:A,:F,:H,:C,:s,:Hz,:S,:K)
    @eval const $unit=1.0
    for (prefix,scale) in pairs(_SI_PREFIX_SCALES)
        name=Symbol(prefix,unit)
        @eval const $name=$scale
    end
end

# The unprefixed metre is `m`; prefixed metre names still follow SI spelling.
const m=1.0
for (prefix,scale) in pairs(_SI_PREFIX_SCALES)
    prefix===:m&&continue
    name=Symbol(prefix,:m)
    @eval const $name=$scale
end
const mm=1e-3

const percent=0.01

struct DecibelUnit end
const dB=DecibelUnit()
Base.:*(value::Real,::DecibelUnit)=10.0^(value/20)

struct DegreeUnit end
const °=DegreeUnit()
Base.:*(value::Real,::DegreeUnit)=deg2rad(value)
