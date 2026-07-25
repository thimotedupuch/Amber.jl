db20(values)=20 .* log10.(abs.(values))
db10(values)=10 .* log10.(abs.(values))

function _frequency_derivative(frequencies,values)
    length(frequencies)==length(values)||throw(DimensionMismatch("frequency and response vectors must have equal lengths"))
    length(frequencies)>=2||throw(ArgumentError("at least two frequency points are required"))
    all(diff(frequencies).>0)||throw(ArgumentError("frequencies must be strictly increasing"))
    derivative=similar(Float64.(values))
    derivative[1]=(values[2]-values[1])/(frequencies[2]-frequencies[1])
    derivative[end]=(values[end]-values[end-1])/(frequencies[end]-frequencies[end-1])
    for index in 2:length(values)-1
        derivative[index]=(values[index+1]-values[index-1])/(frequencies[index+1]-frequencies[index-1])
    end
    derivative
end

group_delay(frequencies::AbstractVector,response::AbstractVector)=-_frequency_derivative(2π.*Float64.(frequencies),phase(response;unwrap=true))
phase_delay(frequencies::AbstractVector,response::AbstractVector)=[iszero(frequency) ? NaN : -angle(value)/(2π*frequency) for (frequency,value) in zip(frequencies,response)]
group_delay(result::SimulationResult;input,output)=group_delay(frequencies(result),transfer(result;input,output))
phase_delay(result::SimulationResult;input,output)=phase_delay(frequencies(result),transfer(result;input,output))

function crossings(frequencies::AbstractVector,values::AbstractVector;level=0.)
    length(frequencies)==length(values)||throw(DimensionMismatch("frequency and value vectors must have equal lengths"))
    found=Float64[]
    for index in 2:length(values)
        a,b=values[index-1]-level,values[index]-level
        if iszero(a)
            push!(found,Float64(frequencies[index-1]))
        elseif a*b<0
            fraction=-a/(b-a); f1,f2=Float64(frequencies[index-1]),Float64(frequencies[index])
            frequency=f1>0&&f2>0 ? exp(log(f1)+fraction*(log(f2)-log(f1))) : f1+fraction*(f2-f1)
            push!(found,frequency)
        end
    end
    !isempty(values)&&iszero(values[end]-level)&&push!(found,Float64(frequencies[end]))
    unique(found)
end

cutoff_frequencies(frequencies,response;reference=first(abs.(response)),level_db=-3.)=crossings(frequencies,db20(response);level=db20(reference)+level_db)
cutoff_frequencies(result::SimulationResult;input,output,kw...)=cutoff_frequencies(frequencies(result),transfer(result;input,output);kw...)

struct FrequencyBand
    low::Float64
    high::Float64
end

function passbands(frequencies,response;reference=maximum(abs.(response)),level_db=-3.)
    values=db20(response); threshold=db20(reference)+level_db; edges=crossings(frequencies,values;level=threshold)
    boundaries=vcat(Float64(first(frequencies)),edges,Float64(last(frequencies))); bands=FrequencyBand[]
    for index in 1:length(boundaries)-1
        middle=boundaries[index]==0 ? (boundaries[index]+boundaries[index+1])/2 : sqrt(boundaries[index]*boundaries[index+1])
        sample=clamp(searchsortedfirst(frequencies,middle),1,length(values))
        values[sample]>=threshold&&push!(bands,FrequencyBand(boundaries[index],boundaries[index+1]))
    end
    bands
end
passbands(result::SimulationResult;input,output,kw...)=passbands(frequencies(result),transfer(result;input,output);kw...)
bandwidth(band::FrequencyBand)=band.high-band.low
function bandwidth(result::SimulationResult;input,output,which=:largest,kw...)
    bands=passbands(result;input,output,kw...); isempty(bands)&&return 0.
    which===:first ? bandwidth(first(bands)) : which===:last ? bandwidth(last(bands)) : which===:largest ? maximum(bandwidth.(bands)) : throw(ArgumentError("which must be :first, :last, or :largest"))
end

struct Resonance
    frequency::Float64
    magnitude::Float64
    index::Int
end
function resonances(frequencies,response)
    values=abs.(response); output=Resonance[]
    for index in 2:length(values)-1
        values[index]>values[index-1]&&values[index]>=values[index+1]&&push!(output,Resonance(Float64(frequencies[index]),Float64(values[index]),index))
    end
    output
end
resonances(result::SimulationResult;input,output)=resonances(frequencies(result),transfer(result;input,output))
peaking(response;reference=first(abs.(response)))=maximum(db20(response).-db20(reference))
notch_depth(response;reference=maximum(abs.(response)))=db20(reference)-minimum(db20(response))
function quality_factor(frequencies,response;resonance=argmax(abs.(response)))
    peak=abs(response[resonance]); edges=crossings(frequencies,abs.(response);level=peak/sqrt(2))
    lower=filter(<(frequencies[resonance]),edges); upper=filter(>(frequencies[resonance]),edges)
    isempty(lower)||isempty(upper) ? NaN : frequencies[resonance]/(first(upper)-last(lower))
end

function integrated_noise(result::NoiseResult,band::Pair;referred=:output)
    low,high=Float64(first(band)),Float64(last(band)); high>low||throw(ArgumentError("noise integration band must be increasing"))
    density=referred===:output ? output_noise_density(result) : referred===:input ? input_referred_noise_density(result) : throw(ArgumentError("referred must be :output or :input"))
    density===nothing&&throw(ArgumentError("input-referred noise was not computed"))
    indices=findall(f->low<=f<=high,result.frequencies); length(indices)>=2||throw(ArgumentError("noise band contains fewer than two sampled frequencies"))
    fs=result.frequencies[indices]; psd=abs2.(density[indices])
    sqrt(sum((psd[index]+psd[index+1])*(fs[index+1]-fs[index])/2 for index in 1:length(fs)-1))
end
