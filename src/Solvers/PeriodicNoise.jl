struct PeriodicNoiseResult
    offset_frequencies::Vector{Float64}
    output::Observable
    input_source::Union{Nothing,Symbol}
    output_harmonic::Int
    sidebands::Vector{Int}
    output_psd::Vector{Float64}
    input_referred_psd::Union{Nothing,Vector{Float64}}
    sideband_psd::Matrix{Float64}
    contributions::Vector{NoiseSourceContribution}
    compiled::AbstractCompiledCircuit
    stats::Dict{Symbol,Any}
end

frequencies(result::PeriodicNoiseResult)=result.offset_frequencies
noise_psd(result::PeriodicNoiseResult)=result.output_psd
noise_density(result::PeriodicNoiseResult)=sqrt.(max.(result.output_psd,0.))
input_referred_noise_psd(result::PeriodicNoiseResult)=result.input_referred_psd
input_referred_noise_density(result::PeriodicNoiseResult)=
    result.input_referred_psd===nothing ? nothing :
    sqrt.(max.(result.input_referred_psd,0.))

function noise_contributions(result::PeriodicNoiseResult;component=nothing,mechanism=nothing)
    filter(result.contributions) do contribution
        (component===nothing||contribution.component===Symbol(component))&&
            (mechanism===nothing||contribution.mechanism===Symbol(mechanism))
    end
end

function _periodic_orbit_samples(pss)
    _require_converged(pss.orbit,"periodic noise orbit")
    times=pss.orbit.axis
    values=pss.orbit.values
    if length(times)>1&&isapprox(last(times)-first(times),pss.period;
            rtol=1e-8,atol=eps(Float64)*max(pss.period,1.))
        sample_times=times[1:end-1]
        sample_values=values[:,1:end-1]
        steps=diff(times)
        isempty(steps)||maximum(abs.(steps.-first(steps)))<=
            1e-8*max(abs(first(steps)),eps(Float64))||
            throw(AnalysisValidationError(
                "periodic noise requires a uniformly sampled PSS orbit"))
        return sample_times,sample_values
    end
    steps=diff(times)
    isempty(steps)||maximum(abs.(steps.-first(steps)))<=
        1e-8*max(abs(first(steps)),eps(Float64))||
        throw(AnalysisValidationError(
            "periodic noise requires a uniformly sampled PSS orbit"))
    times,values
end

function _periodic_jacobians(pss,temperature)
    times,values=_periodic_orbit_samples(pss)
    cc=pss.orbit.compiled
    conductance=SparseMatrixCSC{Float64,Int}[]
    dynamics=SparseMatrixCSC{Float64,Int}[]
    inventories=Tuple{Vector{NoiseSource},Vector{NoiseCorrelationGroup}}[]
    workspace=SimulationWorkspace(cc)
    for index in eachindex(times)
        point=values[:,index]
        g,c=_static_dynamic_jacobians!(workspace,cc,point,times[index];temperature)
        push!(conductance,copy(g))
        push!(dynamics,copy(c))
        push!(inventories,noise_sources(cc,point;temperature))
    end
    times,values,conductance,dynamics,inventories
end

function _fourier_coefficient(samples,q)
    count=length(samples)
    sum(samples[index]*cis(-2π*q*(index-1)/count) for index in 1:count)/count
end

function _periodic_coefficients(conductance,dynamics,sidebands)
    differences=sort!(unique([row-column for row in sidebands for column in sidebands]))
    Dict(q=>(sparse(_fourier_coefficient(conductance,q)),
        sparse(_fourier_coefficient(dynamics,q))) for q in differences)
end

function _lifted_periodic_system(conductance,dynamics,sidebands,offset,period)
    coefficients=_periodic_coefficients(conductance,dynamics,sidebands)
    _lifted_periodic_system(coefficients,sidebands,offset,period)
end

function _lifted_periodic_system(coefficients,sidebands,offset,period)
    state_count=size(first(values(coefficients))[1],1)
    dimension=state_count*length(sidebands)
    rows=Int[]; columns=Int[]; entries=ComplexF64[]
    for (row_block,row_harmonic) in enumerate(sidebands)
        for (column_block,column_harmonic) in enumerate(sidebands)
            gq,cq=coefficients[row_harmonic-column_harmonic]
            # d(C(t)*x(t))/dt uses the output (row) harmonic.
            block=gq+im*2π*(offset+row_harmonic/period)*cq
            for column in axes(block,2), pointer in nzrange(block,column)
                value=block.nzval[pointer]; iszero(value)&&continue
                push!(rows,(row_block-1)*state_count+block.rowval[pointer])
                push!(columns,(column_block-1)*state_count+column)
                push!(entries,value)
            end
        end
    end
    sparse(rows,columns,entries,dimension,dimension)
end

function _instantaneous_source_covariance(sources,groups,frequency,bias,time)
    source_index=Dict(source.id=>index for (index,source) in enumerate(sources))
    covariance=zeros(ComplexF64,length(sources),length(sources))
    for (index,source) in enumerate(sources)
        covariance[index,index]=_noise_source_psd(source,frequency,bias,time)
    end
    for group in groups
        indices=[source_index[id] for id in group.source_ids]
        correlation=ComplexF64.(group.correlation(frequency,bias,time))
        _validate_correlation(correlation,group.id)
        scales=sqrt.(real.(diag(covariance)[indices]))
        covariance[indices,indices].=Diagonal(scales)*correlation*Diagonal(scales)
    end
    covariance
end

function _instantaneous_source_cross_covariance(sources,groups,row_frequency,
        column_frequency,bias,time)
    source_index=Dict(source.id=>index for (index,source) in enumerate(sources))
    row_psd=[_noise_source_psd(source,row_frequency,bias,time) for source in sources]
    column_psd=[_noise_source_psd(source,column_frequency,bias,time)
        for source in sources]
    covariance=Matrix{ComplexF64}(Diagonal(sqrt.(row_psd.*column_psd)))
    for group in groups
        indices=[source_index[id] for id in group.source_ids]
        correlation=ComplexF64.(group.correlation(
            sqrt(row_frequency*column_frequency),bias,time))
        _validate_correlation(correlation,group.id)
        covariance[indices,indices].=Diagonal(sqrt.(row_psd[indices]))*
            correlation*Diagonal(sqrt.(column_psd[indices]))
    end
    covariance
end

function _periodic_source_data(inventories,values,times,frequency)
    isempty(inventories)&&return NoiseSource[],Matrix{ComplexF64}[]
    reference_sources=first(inventories)[1]
    ids=getfield.(reference_sources,:id)
    covariances=Matrix{ComplexF64}[]
    for time_index in eachindex(inventories)
        sources,groups=inventories[time_index]
        getfield.(sources,:id)==ids||throw(AnalysisValidationError(
            "periodic device noise inventory changed over the orbit"))
        push!(covariances,_instantaneous_source_covariance(sources,groups,frequency,
            values[:,time_index],times[time_index]))
    end
    reference_sources,covariances
end

function _periodic_source_cross_data(inventories,values,times,row_frequency,
        column_frequency)
    reference_sources=first(inventories)[1]
    ids=getfield.(reference_sources,:id)
    covariances=Matrix{ComplexF64}[]
    for time_index in eachindex(inventories)
        sources,groups=inventories[time_index]
        getfield.(sources,:id)==ids||throw(AnalysisValidationError(
            "periodic device noise inventory changed over the orbit"))
        push!(covariances,_instantaneous_source_cross_covariance(sources,groups,
            row_frequency,column_frequency,values[:,time_index],times[time_index]))
    end
    reference_sources,covariances
end

function _periodic_adjoint_matrix(system,selector,sideband_count,offset)
    state_count=length(selector)
    selectors=zeros(ComplexF64,size(system,1),sideband_count)
    for block in 1:sideband_count
        rows=(block-1)*state_count+1:block*state_count
        selectors[rows,block].=selector
    end
    _solve_linear(system',selectors,
        "periodic-noise lifted adjoint system is singular at $(offset) Hz")
end

function _periodic_noise_at_offset(adjoint_matrix,selector,output_block,sources,covariances,
        sidebands,offset,period,direct)
    state_count=length(selector)
    adjoint=@view adjoint_matrix[:,output_block]
    source_count=length(sources)
    transfers=zeros(ComplexF64,source_count,length(sidebands))
    for (sideband_index,_) in enumerate(sidebands)
        block=(sideband_index-1)*state_count+1:sideband_index*state_count
        local_adjoint=@view adjoint[block]
        for source_index in eachindex(sources)
            transfers[source_index,sideband_index]=
                dot(local_adjoint,sources[source_index].injection)+
                (sideband_index==output_block ? direct[source_index] : 0.)
        end
    end
    total=0.
    allocations=zeros(Float64,source_count)
    sideband_power=zeros(Float64,length(sidebands))
    for (row_index,row_harmonic) in enumerate(sidebands)
        for (column_index,column_harmonic) in enumerate(sidebands)
            q=row_harmonic-column_harmonic
            covariance_q=_fourier_coefficient(
                covariances[(row_harmonic,column_harmonic)],q)
            row_transfer=@view transfers[:,row_index]
            column_transfer=@view transfers[:,column_index]
            term=row_transfer.*(covariance_q*conj.(column_transfer))
            total+=real(sum(term))
            allocations.+=real.(term)
            row_index==column_index&&(sideband_power[row_index]+=real(sum(term)))
        end
    end
    tolerance=eps(Float64)*max(sum(abs,allocations),1.)
    total>=-tolerance||throw(AnalysisValidationError(
        "periodic noise covariance produced a negative output PSD"))
    max(total,0.),allocations,max.(sideband_power,0.)
end

function periodic_noise(pss::PSSResult,offset_specification;output,input=nothing,
        output_harmonic=0,sidebands=-5:5,temperature=pss.stats[:temperature],
        points=100,scale=:log)
    get(pss.stats,:converged,false)||throw(ConvergenceError(
        "periodic noise requires a converged periodic steady state",copy(pss.stats)))
    offsets=_frequency_grid(offset_specification;points,scale)
    any(iszero,offsets)&&throw(AnalysisValidationError(
        "periodic-noise offset frequencies must be positive"))
    harmonics=sort!(unique(Int.(collect(sidebands))))
    isempty(harmonics)&&throw(AnalysisValidationError("sidebands must not be empty"))
    all(diff(harmonics).==1)||throw(AnalysisValidationError(
        "sidebands must be a contiguous integer range"))
    output_harmonic in harmonics||throw(AnalysisValidationError(
        "output harmonic must be included in sidebands"))
    times,values,conductance,dynamics,inventories=_periodic_jacobians(pss,temperature)
    output_observable=_as_observable(output)
    selector=ComplexF64.(_linear_output_selector(pss.orbit.compiled,output_observable))
    output_block=findfirst(==(output_harmonic),harmonics)
    totals=zeros(Float64,length(offsets))
    sideband_values=zeros(Float64,length(harmonics),length(offsets))
    reference_sources=first(inventories)[1]
    direct=Float64[_noise_output_direct(pss.orbit.compiled,output_observable,source)
        for source in reference_sources]
    source_values=[zeros(Float64,length(offsets)) for _ in reference_sources]
    nested_errors=zeros(Float64,length(offsets))
    gains=input===nothing ? nothing : zeros(Float64,length(offsets))
    input_excitation=input===nothing ? nothing :
        ComplexF64.(_unit_source_excitation(pss.orbit.compiled,Symbol(input)))
    coefficients=_periodic_coefficients(conductance,dynamics,harmonics)
    for (offset_index,offset) in enumerate(offsets)
        system=_lifted_periodic_system(coefficients,harmonics,offset,pss.period)
        adjoints=_periodic_adjoint_matrix(system,selector,length(harmonics),offset)
        covariance_by_pair=Dict{Tuple{Int,Int},Vector{Matrix{ComplexF64}}}()
        sources=reference_sources
        fundamental=inv(pss.period)
        for row_harmonic in harmonics,column_harmonic in harmonics
            raw_row_frequency=abs(offset+row_harmonic*fundamental)
            raw_column_frequency=abs(offset+column_harmonic*fundamental)
            if (iszero(raw_row_frequency)||iszero(raw_column_frequency))&&
                    any(source->source.mechanism===:flicker,sources)
                throw(AnalysisValidationError(
                    "periodic-noise sideband maps power-law noise to DC; choose offset frequencies that avoid an exact harmonic cancellation"))
            end
            row_frequency=max(raw_row_frequency,eps(Float64))
            column_frequency=max(raw_column_frequency,eps(Float64))
            sources,covariance_by_pair[(row_harmonic,column_harmonic)]=
                _periodic_source_cross_data(inventories,values,times,
                    row_frequency,column_frequency)
        end
        total,allocations,_=_periodic_noise_at_offset(adjoints,selector,
            output_block,sources,covariance_by_pair,harmonics,offset,pss.period,
            direct)
        totals[offset_index]=total
        for sideband_index in eachindex(harmonics)
            if sideband_index==output_block
                sideband_values[sideband_index,offset_index]=total
            else
                sideband_total,_,_=_periodic_noise_at_offset(adjoints,selector,
                    sideband_index,sources,covariance_by_pair,harmonics,offset,
                    pss.period,direct)
                sideband_values[sideband_index,offset_index]=sideband_total
            end
        end
        for source_index in eachindex(sources)
            source_values[source_index][offset_index]=allocations[source_index]
        end
        if length(harmonics)>=3&&output_harmonic in harmonics[2:end-1]
            nested_harmonics=harmonics[2:end-1]
            nested_system=_lifted_periodic_system(coefficients,
                nested_harmonics,offset,pss.period)
            nested_adjoints=_periodic_adjoint_matrix(nested_system,selector,
                length(nested_harmonics),offset)
            nested_block=findfirst(==(output_harmonic),nested_harmonics)
            nested_total,_,_=_periodic_noise_at_offset(nested_adjoints,selector,
                nested_block,sources,covariance_by_pair,nested_harmonics,
                offset,pss.period,direct)
            nested_errors[offset_index]=abs(total-nested_total)/max(total,eps(Float64))
        end
        if input!==nothing
            excitation=zeros(ComplexF64,size(system,1))
            zero_block=findfirst(==(0),harmonics)
            zero_block===nothing&&throw(AnalysisValidationError(
                "input-referred periodic noise requires sideband zero"))
            block=(zero_block-1)*length(selector)+1:zero_block*length(selector)
            excitation[block].=input_excitation
            response=_solve_linear(system,excitation,
                "periodic-noise lifted gain system is singular at $(offset) Hz")
            output_rows=(output_block-1)*length(selector)+1:output_block*length(selector)
            gains[offset_index]=abs(dot(selector,@view response[output_rows]))
        end
    end
    input_psd=nothing
    warnings=String[]
    if input!==nothing
        threshold=sqrt(eps(Float64))*max(maximum(gains),1.)
        input_psd=[gains[index]<=threshold ? Inf :
            totals[index]/gains[index]^2 for index in eachindex(offsets)]
        any(value->!isfinite(value),input_psd)&&push!(warnings,
            "input-referred periodic noise is infinite at one or more conversion nulls")
    end
    boundary_ratio=maximum((sideband_values[1,:].+sideband_values[end,:])./
        max.(totals,eps(Float64)))
    nested_error=maximum(nested_errors)
    boundary_ratio>1e-3&&push!(warnings,
        "periodic-noise energy at the sideband boundary exceeds the truncation tolerance")
    nested_error>1e-3&&push!(warnings,
        "periodic-noise result changes materially when the outer sidebands are removed")
    contribution_values=NoiseSourceContribution[]
    for (source_index,source) in enumerate(reference_sources)
        referred=input_psd===nothing ? nothing :
            [isfinite(input_psd[index]) ? source_values[source_index][index]/
                gains[index]^2 : Inf for index in eachindex(offsets)]
        push!(contribution_values,NoiseSourceContribution(source.id,source.owner,
            source.mechanism,source_values[source_index],referred))
    end
    stats=_finalize_stats!(Dict{Symbol,Any}(
        :converged=>true,:temperature=>Float64(temperature),
        :source_count=>length(reference_sources),:sideband_count=>length(harmonics),
        :correlation_group_count=>length(first(inventories)[2]),
        :conversion_metadata=>(state_count=length(selector),
            harmonic_order=copy(harmonics),
            lifted_dimension=length(selector)*length(harmonics)),
        :boundary_power_ratio=>boundary_ratio,
        :nested_truncation_relative_error=>nested_error,:warnings=>warnings))
    PeriodicNoiseResult(offsets,output_observable,
        input===nothing ? nothing : Symbol(input),output_harmonic,harmonics,totals,
        input_psd,sideband_values,contribution_values,
        _snapshot_compiled(pss.orbit.compiled),stats)
end

provenance(result::PeriodicNoiseResult)=Dict(
    :amber_version=>v"0.1.0",
    :topology_fingerprint=>result.compiled.fingerprint,
    :analysis=>"PeriodicNoise",
    :statistics=>copy(result.stats),:unit_system=>:SI,
    :warnings=>copy(result.stats[:warnings]))

report(result::PeriodicNoiseResult)=Dict(
    :analysis=>"PeriodicNoise",:statistics=>copy(result.stats),
    :output_harmonic=>result.output_harmonic,:sidebands=>copy(result.sidebands))

validity_report(result::PeriodicNoiseResult)=Dict(
    :devices=>Dict{Symbol,Any}(),
    :warnings=>_noise_validity_warnings(result.compiled,result.stats[:warnings]))
