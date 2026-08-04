"""Numerically elaborated unknown ordering for the generalized MNA system."""
struct DeviceContract
    terminals::Int
    branch::Bool
    states::Vector{Symbol}
    dc_path::Bool
    noise::Bool
    observables::Tuple
end
_contract(terminals;branch=false,states=Symbol[],dc_path=false,noise=false,observables=(:voltage,:current,:power))=
    DeviceContract(terminals,branch,states,dc_path,noise,observables)
const _DEVICE_SPECS = Dict{Symbol,DeviceContract}(
    :resistor=>_contract(2;dc_path=true,noise=true), :conductance=>_contract(2;dc_path=true,noise=true),
    :capacitor=>_contract(2;observables=(:voltage,:current,:power,:charge)), :current_source=>_contract(2),
    :voltage_source=>_contract(2;branch=true,dc_path=true,noise=true), :inductor=>_contract(2;branch=true,dc_path=true),
    :vccs=>_contract(4), :vcvs=>_contract(4;branch=true,dc_path=true), :cccs=>_contract(2),
    :ccvs=>_contract(2;branch=true,dc_path=true), :diode=>_contract(2;dc_path=true,noise=true,observables=(:voltage,:current,:power,:charge)),
    :npn=>_contract(3;dc_path=true,noise=true),
    :nmos=>_contract(4;dc_path=true,noise=true), :pmos=>_contract(4;dc_path=true,noise=true),
    :switch=>_contract(4;dc_path=true,noise=true),
    :opamp=>_contract(5;branch=true,states=[:dominant_pole],dc_path=true,noise=true),
)
device_contract(kind::Symbol)=get(_DEVICE_SPECS,kind,nothing)
device_contract(::Type{Val{K}}) where {K}=device_contract(K)
