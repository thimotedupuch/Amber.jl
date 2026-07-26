struct SpectrumResult
    frequencies::Vector{Float64}
    coefficients::Vector{ComplexF64}
    amplitude_rms::Vector{Float64}
    psd::Vector{Float64}
    sample_rate::Float64
    window::Symbol
    signal_rms::Float64
    signal_peak::Float64
    stats::Dict{Symbol,Any}
end

frequencies(result::SpectrumResult)=result.frequencies

struct HarmonicComponent
    order::Int
    frequency::Float64
    amplitude_rms::Float64
    phase::Float64
    bin::Int
end

struct HarmonicResult
    spectrum::SpectrumResult
    fundamental::HarmonicComponent
    harmonics::Vector{HarmonicComponent}
    thd::Float64
    thdn::Float64
    snr::Float64
    sinad::Float64
    sfdr::Float64
    enob::Float64
    stats::Dict{Symbol,Any}
end

thd(result::HarmonicResult)=result.thd
thdn(result::HarmonicResult)=result.thdn
snr(result::HarmonicResult)=result.snr
sinad(result::HarmonicResult)=result.sinad
sfdr(result::HarmonicResult)=result.sfdr
enob(result::HarmonicResult)=result.enob

function _window_values(kind::Symbol,count::Int)
    count>=2||throw(ArgumentError("a spectrum requires at least two samples"))
    n=collect(0:count-1); denominator=count-1
    kind===:rectangular&&return ones(Float64,count)
    kind===:hann&&return .5 .- .5cos.(2π.*n./denominator)
    kind===:hamming&&return .54 .- .46cos.(2π.*n./denominator)
    kind===:blackman_harris&&return .35875 .- .48829cos.(2π.*n./denominator) .+ .14128cos.(4π.*n./denominator) .- .01168cos.(6π.*n./denominator)
    kind===:flat_top&&return .21557895 .- .41663158cos.(2π.*n./denominator) .+ .277263158cos.(4π.*n./denominator) .- .083578947cos.(6π.*n./denominator) .+ .006947368cos.(8π.*n./denominator)
    throw(ArgumentError("window must be :rectangular, :hann, :hamming, :blackman_harris, or :flat_top"))
end

function _uniform_signal(result::SimulationResult,signal,interval)
    result.analysis isa Union{Transient,TransientNoise}||throw(ArgumentError(
        "spectrum requires a deterministic or stochastic transient result"))
    indices=interval===nothing ? collect(eachindex(result.axis)) : findall(time->first(interval)<=time<=last(interval),result.axis)
    length(indices)>=4||throw(ArgumentError("selected spectrum interval must contain at least four samples"))
    times=result.axis[indices]; values=Float64.(real.(_signal(result,signal)[indices])); steps=diff(times)
    step=median(steps); step>0||throw(ArgumentError("transient timestamps must be strictly increasing"))
    jitter=maximum(abs.(steps.-step))/step
    if jitter<=sqrt(eps(Float64))
        return Float64.(times),values,false,jitter
    end
    uniform_times=collect(range(first(times),last(times);step=step)); length(uniform_times)>=4||throw(ArgumentError("resampled interval is too short"))
    uniform_values=similar(uniform_times)
    source_index=1
    for (index,time) in enumerate(uniform_times)
        while source_index<length(times)-1&&times[source_index+1]<time; source_index+=1 end
        fraction=(time-times[source_index])/(times[source_index+1]-times[source_index])
        uniform_values[index]=values[source_index]+fraction*(values[source_index+1]-values[source_index])
    end
    uniform_times,uniform_values,true,jitter
end

function spectrum(result::SimulationResult;signal,window=:hann,interval=nothing,nfft=nothing,detrend=:mean)
    times,values,resampled,jitter=_uniform_signal(result,signal,interval)
    detrend===:mean ? (values.-=mean(values)) : detrend===:none || throw(ArgumentError("detrend must be :mean or :none"))
    count=length(values); transform_length=nfft===nothing ? count : Int(nfft)
    transform_length>=count||throw(ArgumentError("nfft must be at least the selected sample count"))
    weights=_window_values(Symbol(window),count); weighted=zeros(Float64,transform_length); weighted[1:count].=values.*weights
    transformed=AbstractFFTs.rfft(weighted); sample_rate=inv(median(diff(times))); fs=collect(AbstractFFTs.rfftfreq(transform_length,sample_rate))
    factors=fill(2.,length(transformed)); factors[1]=1.; iseven(transform_length)&&(factors[end]=1.)
    coefficients=ComplexF64.(transformed).*factors./sum(weights)
    amplitude_rms=abs.(coefficients)./sqrt(2); amplitude_rms[1]=abs(coefficients[1]); iseven(transform_length)&&(amplitude_rms[end]=abs(coefficients[end]))
    psd=factors.*abs2.(transformed)./(sample_rate*sum(abs2,weights))
    warnings=String[]
    resampled&&push!(warnings,"nonuniform transient samples were linearly resampled before the FFT")
    jitter>.01&&push!(warnings,"original timestamp jitter exceeds 1%; inspect resampling sensitivity")
    stats=Dict{Symbol,Any}(:samples=>count,:nfft=>transform_length,:resampled=>resampled,:relative_timestamp_jitter=>jitter,
        :coherent_gain=>sum(weights)/count,:equivalent_noise_bandwidth=>sample_rate*sum(abs2,weights)/sum(weights)^2,:warnings=>warnings)
    SpectrumResult(Float64.(fs),coefficients,Float64.(amplitude_rms),Float64.(psd),sample_rate,Symbol(window),sqrt(mean(abs2,values)),maximum(abs,values),stats)
end

crest_factor(result::SpectrumResult)=result.signal_rms==0 ? NaN : result.signal_peak/result.signal_rms
function band_power(result::SpectrumResult,band::Pair)
    indices=findall(f->first(band)<=f<=last(band),result.frequencies); length(indices)>=2||throw(ArgumentError("band contains fewer than two spectrum bins"))
    f=result.frequencies[indices]; p=result.psd[indices]
    sum((p[index]+p[index+1])*(f[index+1]-f[index])/2 for index in 1:length(f)-1)
end

function _quadratic_peak(values,index)
    index in (1,length(values))&&return 0.,Float64(values[index])
    left,center,right=log(max(values[index-1],eps())),log(max(values[index],eps())),log(max(values[index+1],eps()))
    denominator=left-2center+right; iszero(denominator)&&return 0.,Float64(values[index])
    offset=clamp(.5*(left-right)/denominator,-.5,.5)
    offset,exp(center-.25*(left-right)*offset)
end

function harmonic_analysis(result::SimulationResult;signal,fundamental=:auto,harmonics=10,window=:hann,interval=nothing,nfft=nothing)
    spectral=spectrum(result;signal,window,interval,nfft)
    amplitudes=spectral.amplitude_rms; bin_width=spectral.sample_rate/(2*(length(spectral.frequencies)-1))
    fundamental_index=fundamental===:auto ? argmax(@view amplitudes[2:end])+1 : clamp(round(Int,Float64(fundamental)/bin_width)+1,2,length(amplitudes))
    offset,amplitude=_quadratic_peak(amplitudes,fundamental_index); fundamental_frequency=spectral.frequencies[fundamental_index]+offset*bin_width
    base=HarmonicComponent(1,fundamental_frequency,amplitude,angle(spectral.coefficients[fundamental_index]),fundamental_index)
    components=HarmonicComponent[]
    for order in 2:Int(harmonics)
        frequency=order*fundamental_frequency; frequency>last(spectral.frequencies)&&break
        index=clamp(round(Int,frequency/bin_width)+1,2,length(amplitudes)); local_offset,local_amplitude=_quadratic_peak(amplitudes,index)
        push!(components,HarmonicComponent(order,spectral.frequencies[index]+local_offset*bin_width,local_amplitude,angle(spectral.coefficients[index]),index))
    end
    harmonic_power=sum(component.amplitude_rms^2 for component in components); fundamental_power=base.amplitude_rms^2
    total_ac_power=sum(abs2,@view amplitudes[2:end]); distortion_noise=max(total_ac_power-fundamental_power,0.)
    noise_power=max(distortion_noise-harmonic_power,0.)
    ratio_db(numerator,denominator)=denominator==0 ? Inf : 10log10(numerator/denominator)
    thd_value=base.amplitude_rms==0 ? NaN : sqrt(harmonic_power)/base.amplitude_rms
    thdn_value=base.amplitude_rms==0 ? NaN : sqrt(distortion_noise)/base.amplitude_rms
    snr_value=ratio_db(fundamental_power,noise_power); sinad_value=ratio_db(fundamental_power,distortion_noise)
    excluded=Set(vcat(1,fundamental_index,[component.bin for component in components])); spur=maximum((amplitudes[index] for index in eachindex(amplitudes) if !(index in excluded));init=0.)
    sfdr_value=spur==0 ? Inf : 20log10(base.amplitude_rms/spur); enob_value=(sinad_value-1.76)/6.02
    cycles=fundamental_frequency*(last(result.axis)-first(result.axis)); warnings=copy(spectral.stats[:warnings]); cycles<4&&push!(warnings,"the selected record contains fewer than four fundamental cycles")
    stats=Dict{Symbol,Any}(:warnings=>warnings,:fundamental_cycles=>cycles)
    HarmonicResult(spectral,base,components,thd_value,thdn_value,snr_value,sinad_value,sfdr_value,enob_value,stats)
end
