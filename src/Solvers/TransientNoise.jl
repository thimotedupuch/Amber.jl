function _integer_multiple(value,base;rtol=64eps(Float64))
    ratio=value/base
    isapprox(ratio,round(ratio);rtol,atol=rtol)
end

function _noise_event_grid_check(cc,t0,t1,timestep,event_mode)
    for event in _waveform_events(cc,t0,t1)
        _integer_multiple(event-t0,timestep)||throw(AnalysisValidationError(
            "event at $(event) s does not lie on the stochastic timestep grid"))
    end
end

function _noise_group_map(sources,groups)
    source_index=Dict(source.id=>index for (index,source) in enumerate(sources))
    grouped=Set(id for group in groups for id in group.source_ids)
    source_index,grouped
end

function _draw_white_noise(rng,sources,groups,frequency,bias,time,timestep)
    source_index,grouped=_noise_group_map(sources,groups)
    amplitudes=zeros(Float64,length(sources))
    for index in eachindex(sources)
        sources[index].id in grouped&&continue
        psd=_noise_source_psd(sources[index],frequency,bias,time)
        amplitudes[index]=sqrt(psd/(2timestep))*randn(rng)
    end
    for group in groups
        indices=[source_index[id] for id in group.source_ids]
        psds=[_noise_source_psd(sources[index],frequency,bias,time)
            for index in indices]
        correlation=ComplexF64.(group.correlation(frequency,bias,time))
        _validate_correlation(correlation,group.id)
        covariance=Diagonal(sqrt.(psds))*real.(correlation)*Diagonal(sqrt.(psds))
        eigen=eigen(Symmetric((covariance+covariance')/2))
        values=max.(eigen.values,0.)
        amplitudes[indices].=(eigen.vectors*Diagonal(sqrt.(values/(2timestep))))*
            randn(rng,length(indices))
    end
    amplitudes
end

function _colored_noise_sequences(rng,sources,groups,count,timestep,low_frequency_cutoff,bias)
    sequences=Dict{Symbol,Vector{Float64}}()
    reference_psd=Dict{Symbol,Float64}()
    colored=findall(source->source.mechanism===:flicker,sources)
    isempty(colored)&&return sequences,reference_psd
    duration=count*timestep
    frequency_step=inv(duration)
    nyquist=inv(2timestep)
    bins=collect(0:frequency_step:nyquist)
    for index in colored
        source=sources[index]
        spectrum=zeros(ComplexF64,length(bins))
        for bin in 2:length(bins)-1
            frequency=bins[bin]
            frequency<low_frequency_cutoff&&continue
            psd=_noise_source_psd(source,frequency,bias,0.)
            gaussian=(randn(rng)+im*randn(rng))/sqrt(2)
            spectrum[bin]=count*sqrt(psd*frequency_step/2)*gaussian
        end
        sequences[source.id]=irfft(spectrum,count)
        reference_psd[source.id]=
            _noise_source_psd(source,low_frequency_cutoff,bias,0.)
    end
    sequences,reference_psd
end

function _complex_correlated_white_sequences(rng,sources,groups,count,timestep,bias)
    sequences=Dict{Symbol,Vector{Float64}}()
    source_index=Dict(source.id=>index for (index,source) in enumerate(sources))
    frequency_step=inv(count*timestep)
    nyquist=inv(2timestep)
    spectrum_length=div(count,2)+1
    for group in groups
        correlation=ComplexF64.(group.correlation(nyquist,bias,0.))
        maximum(abs,imag.(correlation))<=sqrt(eps(Float64))&&continue
        _validate_correlation(correlation,group.id)
        eigen=eigen(Hermitian((correlation+correlation')/2))
        factor=eigen.vectors*Diagonal(sqrt.(max.(eigen.values,0.)))
        spectra=[zeros(ComplexF64,spectrum_length) for _ in group.source_ids]
        for bin in 2:spectrum_length-1
            gaussian=(randn(rng,length(group.source_ids)).+
                im.*randn(rng,length(group.source_ids)))./sqrt(2)
            correlated=factor*gaussian
            for local_index in eachindex(group.source_ids)
                spectra[local_index][bin]=count*sqrt(frequency_step/2)*
                    correlated[local_index]
            end
        end
        for (local_index,id) in enumerate(group.source_ids)
            haskey(source_index,id)||throw(AnalysisValidationError(
                "transient-noise correlation group $(group.id) refers to an unknown source"))
            sequences[id]=irfft(spectra[local_index],count)
        end
    end
    sequences
end

function transient_noise(c,interval::Pair;timestep,saveat=timestep,seed,
        temperature=300.,initial=nothing,event_mode=nothing,reltol=1e-6,
        abstol=1e-9,maxiters=120,
        low_frequency_cutoff=inv(Float64(last(interval))-Float64(first(interval))))
    t0,t1=Float64(first(interval)),Float64(last(interval))
    isfinite(t0)&&isfinite(t1)&&t1>t0||throw(AnalysisValidationError(
        "transient-noise interval must be finite and increasing"))
    timestep=Float64(timestep)
    saveat=Float64(saveat)
    timestep>0&&isfinite(timestep)||throw(AnalysisValidationError(
        "stochastic timestep must be finite and positive"))
    saveat>=timestep&&_integer_multiple(saveat,timestep)||throw(AnalysisValidationError(
        "saveat must be a positive integer multiple of the stochastic timestep"))
    low_frequency_cutoff=Float64(low_frequency_cutoff)
    low_frequency_cutoff>0&&isfinite(low_frequency_cutoff)||throw(AnalysisValidationError(
        "low-frequency cutoff must be finite and positive"))
    low_frequency_cutoff>=inv(t1-t0)||throw(AnalysisValidationError(
        "low-frequency cutoff is below the resolution of the requested record"))
    event_mode in (nothing,:exact)||throw(AnalysisValidationError(
        "event_mode must be nothing or :exact"))
    isfinite(temperature)&&temperature>0||throw(AnalysisValidationError(
        "temperature must be finite and positive"))
    seed isa Integer&&seed>=0||throw(AnalysisValidationError(
        "stochastic seed must be a non-negative integer"))
    resolved_seed=UInt64(seed)
    cc=compile(c)
    _noise_event_grid_check(cc,t0,t1,timestep,event_mode)
    step_count=round(Int,(t1-t0)/timestep)
    isapprox(t0+step_count*timestep,t1;rtol=64eps(Float64),atol=64eps(Float64)*max(abs(t1),1.))||
        throw(AnalysisValidationError("the transient-noise interval must contain an integer number of timesteps"))
    times=collect(range(t0,t1;length=step_count+1))
    state=_initial_transient_state(cc,initial;temperature)
    values=zeros(Float64,cc.n,step_count+1)
    values[:,1]=state
    rng=Random.Xoshiro(resolved_seed)
    initial_sources,initial_groups=noise_sources(cc,state;temperature)
    colored,colored_reference_psd=_colored_noise_sequences(rng,initial_sources,
        initial_groups,step_count,
        timestep,low_frequency_cutoff,state)
    complex_white=_complex_correlated_white_sequences(rng,initial_sources,
        initial_groups,step_count,timestep,state)
    total_iterations=0
    failed_steps=Int[]
    nyquist=inv(2timestep)
    for step in 1:step_count
        previous=copy(state)
        sources,groups=noise_sources(cc,previous;temperature)
        white_sources=filter(source->source.mechanism!==:flicker,sources)
        generated_ids=Set(keys(complex_white))
        direct_sources=filter(source->!(source.id in generated_ids),white_sources)
        direct_ids=Set(source.id for source in direct_sources)
        white_groups=filter(group->all(id->id in direct_ids,group.source_ids),groups)
        amplitudes=_draw_white_noise(rng,direct_sources,white_groups,nyquist,
            previous,times[step+1],timestep)
        forcing=zeros(Float64,cc.n)
        for (index,source) in enumerate(direct_sources)
            forcing .+= real.(source.injection).*amplitudes[index]
        end
        for source in white_sources
            haskey(complex_white,source.id)||continue
            psd=_noise_source_psd(source,nyquist,previous,times[step+1])
            forcing .+=real.(source.injection).*complex_white[source.id][step]*
                sqrt(psd)
        end
        for source in sources
            haskey(colored,source.id)||continue
            initial_psd=colored_reference_psd[source.id]
            current_psd=_noise_source_psd(source,low_frequency_cutoff,previous,
                times[step+1])
            modulation=initial_psd>0 ? sqrt(current_psd/initial_psd) : 0.
            forcing .+=real.(source.injection).*colored[source.id][step]*modulation
        end
        event_history=copy(previous)
        event_mode===:exact&&_apply_switch_events!(event_history,cc,times[step],times[step+1])
        state,iterations,converged=_newton(cc,state,event_history,times[step+1],
            inv(timestep);reltol,abstol,maxiters,temperature,forcing)
        total_iterations+=iterations
        converged||push!(failed_steps,step+1)
        values[:,step+1]=state
    end
    stride=round(Int,saveat/timestep)
    saved_indices=unique(vcat(1,collect(1+stride:stride:step_count+1),step_count+1))
    warnings=String[]
    !isempty(colored)&&push!(warnings,
        "power-law noise below $(low_frequency_cutoff) Hz was excluded")
    !isempty(failed_steps)&&push!(warnings,
        "one or more stochastic backward-Euler steps did not converge")
    analysis=TransientNoise(interval=t0=>t1,timestep=timestep,saveat=saveat,
        seed=resolved_seed,temperature=Float64(temperature),
        low_frequency_cutoff=low_frequency_cutoff,event_mode=event_mode)
    stats=_finalize_stats!(Dict{Symbol,Any}(
        :converged=>isempty(failed_steps),:iterations=>total_iterations,
        :failed_steps=>failed_steps,:rejected_steps=>Int[],
        :seed=>resolved_seed,:timestep=>timestep,
        :nyquist_frequency=>nyquist,:low_frequency_cutoff=>low_frequency_cutoff,
        :high_frequency_cutoff=>nyquist,
        :source_count=>length(initial_sources),
        :source_metadata=>[(id=source.id,owner=source.owner,
            mechanism=source.mechanism,correlation_group=source.correlation_group)
            for source in initial_sources],
        :correlation_group_count=>length(initial_groups),
        :stochastic_interpretation=>:ito,
        :temperature=>Float64(temperature),
        :warnings=>warnings);partial=true)
    SimulationResult(cc,analysis,times[saved_indices],values[:,saved_indices],stats)
end

simulate(c,analysis::TransientNoise)=transient_noise(c,analysis.interval;
    timestep=analysis.timestep,saveat=analysis.saveat,seed=analysis.seed,
    temperature=analysis.temperature,
    low_frequency_cutoff=analysis.low_frequency_cutoff,
    event_mode=analysis.event_mode)
