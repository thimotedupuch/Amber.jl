"""SI scale constants accepted by Amber's unit-stripping input layer."""
const Ω=1.0; const kΩ=1e3; const MΩ=1e6; const GΩ=1e9; const TΩ=1e12; const mΩ=1e-3
const V=1.0; const mV=1e-3; const μV=1e-6; const nV=1e-9
const A=1.0; const mA=1e-3; const μA=1e-6; const nA=1e-9; const pA=1e-12; const fA=1e-15
const C=1.0; const mC=1e-3; const μC=1e-6; const nC=1e-9; const pC=1e-12; const fC=1e-15
const F=1.0; const mF=1e-3; const μF=1e-6; const nF=1e-9; const pF=1e-12; const fF=1e-15
const H=1.0; const mH=1e-3; const μH=1e-6; const nH=1e-9; const pH=1e-12
const s=1.0; const ms=1e-3; const μs=1e-6; const ns=1e-9; const ps=1e-12
const Hz=1.0; const kHz=1e3; const MHz=1e6; const GHz=1e9
const K=1.0; const m=1.0; const μS=1e-6; const percent=0.01

struct DecibelUnit end
const dB=DecibelUnit()
Base.:*(value::Real,::DecibelUnit)=10.0^(value/20)

struct DegreeUnit end
const °=DegreeUnit()
Base.:*(value::Real,::DegreeUnit)=deg2rad(value)
