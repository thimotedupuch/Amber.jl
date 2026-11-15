# Run: julia --project=. benchmark/ngspice_cmos_audit.jl
# Accuracy audit only; this script does not benchmark runtime.
include("ngspice_cmos.jl")

function audit_ngspice_data(deck,n,h,dir,label)
    data=joinpath(dir,"$label.txt"); circuit=joinpath(dir,"$label.cir")
    vectors=join(["v(out$i)" for i in 1:n]," ")
    write(circuit,deck*".control\nset wr_singlescale\nset numdgt=17\ntran $h 210n 0 $h\nwrdata $data $vectors\nquit\n.endc\n.end\n")
    read(`$CMOS_SPICE -b $circuit`,String)
    rows=[parse.(Float64,split(line)) for line in eachline(data)]
    return getindex.(rows,1),reduce(hcat,[row[2:end] for row in rows])
end

# Interpolate both retained traces onto an explicitly chosen common grid.
function audit_trace_errors(ta,va,tb,vb,grid)
    errors=zeros(size(va,1)); ka=1; kb=1
    for t in grid
        while ka<length(ta)-1 && ta[ka+1]<t; ka+=1; end
        while kb<length(tb)-1 && tb[kb+1]<t; kb+=1; end
        fa=(t-ta[ka])/(ta[ka+1]-ta[ka]); fb=(t-tb[kb])/(tb[kb+1]-tb[kb])
        for i in eachindex(errors)
            a=va[i,ka]+fa*(va[i,ka+1]-va[i,ka])
            b=vb[i,kb]+fb*(vb[i,kb+1]-vb[i,kb])
            errors[i]=max(errors[i],abs(a-b))
        end
    end
    return errors
end

function audit_cmos_case(n,topology)
    design,deck=cmos_design(n,"transient";topology)
    cc=compile(design); h=6.25e-11
    result=transient(cc,0.0=>2.1e-7;max_step=h,saveat=h,event_mode=:exact,
        adaptive=false,solver=SolverOptions(reltol=1e-6,current_abstol=1e-12,voltage_abstol=1e-9))
    result.stats[:converged] || error("Amber audit failed convergence")
    mktempdir() do dir
        tc,vc=audit_ngspice_data(deck,n,h,dir,"coarse")
        tf,vf=audit_ngspice_data(deck,n,4e-12,dir,"fine")
        tr,vr=audit_ngspice_data(deck,n,2e-12,dir,"reference")
        av=result.values[3:n+2,:]; uniongrid=sort!(unique(vcat(result.axis,tc)))
        all(isfinite,av) && all(isfinite,vc) && all(isfinite,vf) && all(isfinite,vr) || error("Nonfinite trace")
        all(t->all(diff(t).>0),(result.axis,tc,tf,tr)) || error("Nonmonotonic sample times")
        minima=[minimum(av[i,:]) for i in 1:n]; maxima=[maximum(av[i,:]) for i in 1:n]
        all(x->x<1.0,minima) && all(x->x>4.0,maxima) || error("A gate did not traverse both rails")
        reference_difference=audit_trace_errors(tf,vf,tr,vr,tr)
        maximum(reference_difference)<1e-4 || error("Reference refinement is not converged within 0.1mV")
        return Dict(
            "topology"=>topology,"inverters"=>n,"checked_nodes"=>collect(1:n),
            "amber_adaptive"=>false,"ngspice_adaptive"=>true,
            "coarse_max_step_seconds"=>h,"reference_max_step_seconds"=>2e-12,
            "reference_check_max_step_seconds"=>4e-12,
            "amber_newton_reltol"=>1e-6,"ngspice_reltol"=>1e-6,
            "amber_accepted_steps"=>length(result.stats[:accepted_step_sizes]),
            "amber_saved_samples"=>length(result.axis),"ngspice_coarse_samples"=>length(tc),
            "ngspice_reference_samples"=>length(tr),
            "mutual_error_on_union_grid"=>audit_trace_errors(result.axis,av,tc,vc,uniongrid),
            "amber_error_on_reference_grid"=>audit_trace_errors(result.axis,av,tr,vr,tr),
            "amber_error_on_native_grid"=>audit_trace_errors(result.axis,av,tr,vr,result.axis),
            "ngspice_error_on_native_grid"=>audit_trace_errors(tc,vc,tr,vr,tc),
            "ngspice_error_on_reference_grid"=>audit_trace_errors(tc,vc,tr,vr,tr),
            "reference_4ps_vs_2ps_on_reference_grid"=>reference_difference,
            "amber_output_minimum"=>minima,
            "amber_output_maximum"=>maxima)
    end
end

if abspath(PROGRAM_FILE)==@__FILE__
    cases=[audit_cmos_case(1,"bank"),audit_cmos_case(10,"chain")]
    TOML.print(stdout,Dict("julia_version"=>string(VERSION),"threads"=>Threads.nthreads(),
        "note"=>"Native-grid metrics compare simulator samples; reference-grid metrics additionally include piecewise-linear reconstruction. Refinement difference is empirical, not a rigorous absolute error bound.",
        "cases"=>cases);sorted=true)
end
