struct PhaseNoiseResult
    offset_frequencies::Vector{Float64}
    output::Observable
    phase_noise_ratio::Vector{Float64}
    phase_noise_dbc_per_hz::Vector{Float64}
    phase_diffusion_coefficient::Float64
    amplitude_noise_psd::Vector{Float64}
    contributions::Vector{NoiseSourceContribution}
    phase_sensitivity::Matrix{Float64}
    neutral_floquet_multiplier::ComplexF64
    compiled::AbstractCompiledCircuit
    stats::Dict{Symbol,Any}
end

frequencies(result::PhaseNoiseResult)=result.offset_frequencies
noise_psd(result::PhaseNoiseResult)=result.phase_noise_ratio
noise_density(result::PhaseNoiseResult)=sqrt.(max.(result.phase_noise_ratio,0.))

function noise_contributions(result::PhaseNoiseResult;component=nothing,mechanism=nothing)
    filter(result.contributions) do contribution
        (component===nothing||contribution.component===Symbol(component))&&
            (mechanism===nothing||contribution.mechanism===Symbol(mechanism))
    end
end

function _orbit_tangents(times,values,period)
    count=length(times)
    tangents=zeros(Float64,size(values))
    for index in 1:count
        previous=index==1 ? count : index-1
        following=index==count ? 1 : index+1
        previous_time=index==1 ? times[previous]-period : times[previous]
        following_time=index==count ? times[following]+period : times[following]
        tangents[:,index].=(values[:,following]-values[:,previous])./
            (following_time-previous_time)
    end
    tangents
end

function _phase_sensitivity(pss,times,values,temperature)
    multipliers=pss.floquet_multipliers
    distances=abs.(multipliers.-1)
    neutral_index=argmin(distances)
    distances[neutral_index]<=1e-2||throw(AnalysisValidationError(
        "autonomous oscillator has no neutral Floquet multiplier near unity"))
    sorted=sort(distances)
    length(sorted)==1||sorted[2]>=10*max(sorted[1],1e-8)||throw(AnalysisValidationError(
        "autonomous oscillator neutral Floquet mode is not isolated"))
    eigen_decomposition=eigen(pss.monodromy')
    left_index=argmin(abs.(eigen_decomposition.values.-1))
    sensitivity=real.(eigen_decomposition.vectors[:,left_index])
    tangents=_orbit_tangents(times,values,pss.period)
    normalization=dot(sensitivity,tangents[:,1])
    abs(normalization)>sqrt(eps(Float64))||throw(AnalysisValidationError(
        "oscillator phase sensitivity cannot be normalized against the orbit tangent"))
    sensitivity./=normalization
    waveform=zeros(Float64,length(sensitivity),length(times))
    cc=pss.orbit.compiled
    extended_times=vcat(times,first(times)+pss.period)
    extended_values=hcat(values,values[:,1])
    # Discrete adjoint of conservative backward Euler:
    # J_n δx_n = C_(n-1) δx_(n-1)/h + B_n δnoise_n.
    # A state covector p_n must be mapped to residual space by J_n'^(-1)/h
    # before projection onto B_n. This also works for singular MNA C.
    systems=SparseMatrixCSC{Float64,Int}[]
    previous_dynamics=SparseMatrixCSC{Float64,Int}[]
    workspace=SimulationWorkspace(cc)
    for step in 2:length(extended_times)
        h=extended_times[step]-extended_times[step-1]
        point=extended_values[:,step]
        g,c=_static_dynamic_jacobians!(workspace,cc,point,extended_times[step];temperature)
        push!(systems,g+c/h)
        _,cprevious=_static_dynamic_jacobians!(workspace,cc,extended_values[:,step-1],extended_times[step-1];temperature)
        push!(previous_dynamics,copy(cprevious))
    end
    adjoint_at_next=sensitivity
    for step in length(times):-1:1
        h=extended_times[step+1]-extended_times[step]
        residual_adjoint=_solve_linear(systems[step]',adjoint_at_next,
            "oscillator discrete adjoint is singular at time $(extended_times[step+1])")/h
        # The residual is evaluated at the endpoint of this step.
        endpoint=step==length(times) ? 1 : step+1
        waveform[:,endpoint]=residual_adjoint
        adjoint_at_next=previous_dynamics[step]'*residual_adjoint
    end
    waveform,multipliers[neutral_index]
end

function _phase_projection_spectrum(pss,times,values,sensitivity,temperature,
        frequencies)
    reference_sources=nothing
    source_spectra=zeros(Float64,0,length(frequencies))
    for time_index in eachindex(times)
        sources,groups=noise_sources(pss.orbit.compiled,values[:,time_index];temperature)
        if reference_sources===nothing
            reference_sources=sources
            source_spectra=zeros(Float64,length(sources),length(frequencies))
        elseif getfield.(sources,:id)!=getfield.(reference_sources,:id)
            throw(AnalysisValidationError(
                "oscillator noise inventory changed over the periodic orbit"))
        end
        projections=ComplexF64[dot(sensitivity[:,time_index],source.injection)
            for source in sources]
        for (frequency_index,frequency) in enumerate(frequencies)
            covariance=_instantaneous_source_covariance(sources,groups,
                frequency,values[:,time_index],times[time_index])
            terms=real.(projections.*(covariance*conj.(projections)))
            source_spectra[:,frequency_index].+=terms
        end
    end
    source_spectra./=length(times)
    reference_sources,source_spectra
end

function phase_noise(pss::PSSResult,offset_specification;output,sidebands=-5:5,
        temperature=pss.stats[:temperature],points=100,scale=:log)
    get(pss.stats,:converged,false)||throw(ConvergenceError(
        "phase noise requires a converged periodic steady state",copy(pss.stats)))
    pss.autonomous||throw(AnalysisValidationError(
        "phase noise requires an autonomous periodic steady-state result"))
    pss.orbit.analysis.method===:bdf1||throw(AnalysisValidationError(
        "phase noise requires a backward-Euler orbit for its discrete adjoint"))
    offsets=_frequency_grid(offset_specification;points,scale)
    any(iszero,offsets)&&throw(AnalysisValidationError(
        "phase-noise offset frequencies must be positive"))
    times,values=_periodic_orbit_samples(pss)
    sensitivity,neutral=_phase_sensitivity(pss,times,values,temperature)
    sources,source_projection=_phase_projection_spectrum(pss,times,values,
        sensitivity,temperature,offsets)
    angular_frequency=2π/pss.period
    white_indices=findall(source->source.mechanism!==:flicker,sources)
    phase_diffusion=angular_frequency^2*
        sum(source_projection[white_indices,1])
    phase_psd=angular_frequency^2 .* vec(sum(source_projection;dims=1)) ./
        (2π.*offsets).^2
    single_sideband=phase_psd./2
    dbc=10 .* log10.(single_sideband)
    periodic=periodic_noise(pss,offsets;output,input=nothing,output_harmonic=1,
        sidebands,temperature)
    contributions=NoiseSourceContribution[]
    for (index,source) in enumerate(sources)
        source_ratio=angular_frequency^2 .* vec(source_projection[index,:]) ./
            (2π.*offsets).^2 ./ 2
        push!(contributions,NoiseSourceContribution(source.id,source.owner,
            source.mechanism,source_ratio,nothing))
    end
    warnings=copy(periodic.stats[:warnings])
    stats=_finalize_stats!(Dict{Symbol,Any}(
        :converged=>true,:temperature=>Float64(temperature),
        :neutral_multiplier=>neutral,:phase_diffusion_coefficient=>phase_diffusion,
        :source_count=>length(sources),
        :correlation_group_count=>begin
            _,groups=noise_sources(pss.orbit.compiled,values[:,1];temperature)
            length(groups)
        end,
        :warnings=>warnings))
    PhaseNoiseResult(offsets,_as_observable(output),single_sideband,dbc,
        phase_diffusion,periodic.output_psd,contributions,sensitivity,neutral,
        _snapshot_compiled(pss.orbit.compiled),stats)
end

provenance(result::PhaseNoiseResult)=Dict(
    :amber_version=>v"0.1.0",
    :topology_fingerprint=>result.compiled.fingerprint,
    :analysis=>"PhaseNoise",
    :statistics=>copy(result.stats),:unit_system=>:SI,
    :warnings=>copy(result.stats[:warnings]))

report(result::PhaseNoiseResult)=Dict(
    :analysis=>"PhaseNoise",:statistics=>copy(result.stats),
    :neutral_floquet_multiplier=>result.neutral_floquet_multiplier)

validity_report(result::PhaseNoiseResult)=Dict(
    :devices=>Dict{Symbol,Any}(),
    :warnings=>_noise_validity_warnings(result.compiled,result.stats[:warnings]))
