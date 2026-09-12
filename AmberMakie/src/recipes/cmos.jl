"""A reproducible grid of ChargeBasedMOSFET bias points for CMOS characterization."""
struct MOSFETView{M,P} <: AbstractDisplayView
    model::M
    kind::Symbol
    vgs::Vector{Float64}
    vds::Vector{Float64}
    vbs::Float64
    temperature::Float64
    points::P
    warnings::Vector{String}
    provenance::Dict
end

"""
    mosfetview(model; kind=:nmos, vgs=range(0, 1.5; length=101),
               vds=[0.05, 0.6, 1.2], vbs=0, temperature=300)

Evaluate a transistor on a gate/drain bias grid, retaining the model parameters.
Biases are polarity-normalized: positive `vgs`/`vds` mean VSG/VSD for PMOS.
`points[i,j]` corresponds to `vgs[i], vds[j]`. No circuit solver is run by the
plot recipes consuming this view. Geometry is taken from the supplied model.
"""
function mosfetview(model::Amber.ChargeBasedMOSFET; kind=:nmos,
        vgs=range(0.,1.5;length=101), vds=[.05,.6,1.2], vbs=0., temperature=300.)
    kind in (:nmos,:pmos) || throw(ArgumentError("kind must be :nmos or :pmos"))
    gates=Float64.(collect(vgs)); drains=vds isa Real ? [Float64(vds)] : Float64.(collect(vds))
    length(gates)>=2 || throw(ArgumentError("vgs needs at least two samples"))
    isempty(drains) && throw(ArgumentError("vds must not be empty"))
    all(isfinite,gates) && all(isfinite,drains) && isfinite(vbs) ||
        throw(ArgumentError("bias voltages must be finite"))
    all(>(0),diff(gates)) && all(>(0),diff(drains)) ||
        throw(ArgumentError("bias grids must be strictly increasing"))
    polarity=kind===:nmos ? 1. : -1.
    points=[Amber.mosfet_operating_point(model,kind,polarity*d,polarity*g,0.,polarity*vbs;
        temperature) for g in gates,d in drains]
    warnings=["Illustrative long-channel model; no foundry calibration or short-channel effects."]
    provenance=Dict(:model=>"ChargeBasedMOSFET", :parameters=>Amber.model_parameters(model),
        :kind=>kind, :vgs=>gates, :vds=>drains, :vbs=>Float64(vbs), :temperature=>Float64(temperature))
    MOSFETView(model,kind,gates,drains,Float64(vbs),Float64(temperature),points,warnings,provenance)
end

_mos_gate_label(view)=view.kind===:nmos ? "VGS (V)" : "VSG (V)"
_mos_drain_label(view)=view.kind===:nmos ? "VDS" : "VSD"
_mos_quantity(point,quantity)=quantity===:id ? abs(point.id) :
    quantity===:gm ? abs(point.gm) : quantity===:gds ? abs(point.gds) :
    quantity===:gm_over_id ? point.gm_over_id : quantity===:intrinsic_gain ? point.intrinsic_gain :
    quantity===:cgg ? point.capacitance_matrix[2,2] :
    throw(ArgumentError("quantity must be :id, :gm, :gds, :gm_over_id, :intrinsic_gain, or :cgg"))
const _MOS_LABELS=Dict(:id=>"|ID| (A)",:gm=>"|gm| (S)",:gds=>"|gds| (S)",
    :gm_over_id=>"gm / |ID| (1/V)",:intrinsic_gain=>"|gm / gds|",:cgg=>"∂Qg / ∂Vg (F)")
_display_values(values;positive=false)=[isfinite(x) && (!positive || x>0) ? Float64(x) : NaN for x in values]

"""
    mosfetplot(position, view; quantity=:id, x=:vgs, scale=:linear, axis=(;))

Plot transfer (`x=:vgs`), output (`x=:vds`), or sizing (`x=:gm_over_id`) families.
`scale=:log` displays positive finite values only; original data remains in `view`.
Current/conductance quantities use magnitudes, with polarity explicit in labels.
"""
function mosfetplot(position,view::MOSFETView;quantity=:id,x=:vgs,scale=:linear,axis=(;),legend=true,kwargs...)
    haskey(_MOS_LABELS,quantity) || throw(ArgumentError("unsupported MOS quantity $(quantity)"))
    x in (:vgs,:vds,:gm_over_id) || throw(ArgumentError("x must be :vgs, :vds, or :gm_over_id"))
    scale in (:linear,:log) || throw(ArgumentError("scale must be :linear or :log"))
    slot=_position(position)
    attributes=merge((xlabel=x===:gm_over_id ? "gm / |ID| (1/V)" : x===:vgs ? _mos_gate_label(view) : _mos_drain_label(view)*" (V)",
        ylabel=_MOS_LABELS[quantity],yscale=scale===:log ? log10 : identity,
        xtickformat=_engineering_ticks,ytickformat=_engineering_ticks),axis)
    ax=Makie.Axis(slot;attributes...)
    xs=x===:vgs ? view.vgs : view.vds
    biases=x===:vds ? view.vgs : view.vds
    plots=map(eachindex(biases)) do j
        points=x===:vds ? view.points[j,:] : view.points[:,j]
        ys=_display_values([_mos_quantity(p,quantity) for p in points];positive=scale===:log)
        label=(x!==:vds ? _mos_drain_label(view) : (view.kind===:nmos ? "VGS" : "VSG"))*
            " = "*engineering(biases[j];unit="V",digits=3)
        Makie.lines!(ax,x===:gm_over_id ? _display_values([p.gm_over_id for p in points]) : xs,ys;label,kwargs...)
    end
    legend && Makie.axislegend(ax;position=:lt)
    PlotHandle(slot,(characteristic=ax,),(curves=plots,),view)
end
mosfetplot(position,model::Amber.ChargeBasedMOSFET;kind=:nmos,vgs=range(0.,1.5;length=101),
    vds=[.05,.6,1.2],vbs=0.,temperature=300.,kwargs...)=
    mosfetplot(position,mosfetview(model;kind,vgs,vds,vbs,temperature);kwargs...)

"""Plot gm/|ID| versus |ID|/(W × multiplicity), in A/m, for each drain bias."""
function gmidplot(position,view::MOSFETView;axis=(;),legend=true,kwargs...)
    slot=_position(position)
    ax=Makie.Axis(slot;merge((xlabel="|ID| / total width (A/m)",ylabel="gm / |ID| (1/V)",
        xscale=log10,xtickformat=_engineering_ticks),axis)...)
    plots=map(eachindex(view.vds)) do j
        density=[abs(p.id)/(view.model.width*view.model.multiplicity) for p in view.points[:,j]]
        ys=[p.gm_over_id for p in view.points[:,j]]
        label=_mos_drain_label(view)*" = "*engineering(view.vds[j];unit="V",digits=3)
        Makie.lines!(ax,_display_values(density;positive=true),_display_values(ys);label,kwargs...)
    end
    legend && Makie.axislegend(ax;position=:rt)
    PlotHandle(slot,(gmid=ax,),(curves=plots,),view)
end

"""
    capacitanceplot(position, point)

Show the signed 4×4 dQi/dVj matrix returned by `Amber.mosfet_operating_point`.
Rows are charge terminals, columns voltage terminals. Values are displayed in fF;
negative entries are preserved. This is not a matrix of positive lumped capacitors.
"""
function capacitanceplot(position,point::NamedTuple;kwargs...)
    matrix=point.capacitance_matrix
    size(matrix)==(4,4) || throw(DimensionMismatch("expected a four-terminal capacitance matrix"))
    all(isfinite,matrix) || throw(ArgumentError("capacitance matrix must be finite"))
    slot=_position(position); layout=Makie.GridLayout(slot)
    names=["Drain","Gate","Source","Bulk"]
    ax=Makie.Axis(layout[1,1];xlabel="Voltage terminal",ylabel="Charge terminal",
        xticks=(1:4,names),yticks=(1:4,names),yreversed=true,
        title="Signed ∂Qi / ∂Vj")
    values=Float64.(matrix).*1e15; extent=maximum(abs,values)
    extent=iszero(extent) ? 1. : extent
    plot=Makie.heatmap!(ax,1:4,1:4,permutedims(values);colormap=:RdBu,
        colorrange=(-extent,extent),kwargs...)
    Makie.Colorbar(layout[1,2],plot;label="fF")
    PlotHandle(layout,(capacitance=ax,),(capacitance=plot,),point)
end

"""Open linked transfer, gm/ID, gain and capacitance plots on a stored MOS bias grid."""
function workbench(view::MOSFETView)
    figure=Makie.Figure(size=(1200,900))
    title="$(uppercase(String(view.kind))) characterization · W = $(engineering(view.model.width;unit="m")) · L = $(engineering(view.model.length;unit="m")) · $(view.temperature) K"
    header=Makie.GridLayout(figure[1,1:2])
    Makie.Label(header[1,1],title;fontsize=21,halign=:left,tellwidth=false)
    transfer=mosfetplot(figure[2,1],view;scale=:log,legend=false,axis=(title="Transfer characteristic",))
    efficiency=gmidplot(figure[2,2],view;legend=false,axis=(title="Transconductance efficiency",))
    gain=mosfetplot(figure[3,1],view;quantity=:intrinsic_gain,x=:gm_over_id,scale=:log,legend=false,axis=(title="Intrinsic gain",))
    capacitance=mosfetplot(figure[3,2],view;quantity=:cgg,legend=false,axis=(title="Gate capacitance",))
    Makie.Legend(header[2,1],transfer.plots.curves,
        [_mos_drain_label(view)*" = "*engineering(v;unit="V",digits=3) for v in view.vds];
        orientation=:horizontal,framevisible=false,tellwidth=false)
    Makie.linkxaxes!(transfer.axes.characteristic,capacitance.axes.characteristic)
    controls=Makie.GridLayout(figure[4,1:2])
    Makie.Label(controls[1,1],view.kind===:nmos ? "Gate bias VGS" : "Gate bias VSG")
    gate_slider=Makie.Slider(controls[1,2];range=view.vgs,startvalue=view.vgs[cld(length(view.vgs),2)])
    drain_menu=Makie.Menu(controls[1,3];options=[(_mos_drain_label(view)*" = "*engineering(v;unit="V"),j) for (j,v) in enumerate(view.vds)],default=1)
    selected_gate=Makie.Observable(cld(length(view.vgs),2)); selected_drain=Makie.Observable(1)
    subscriptions=Any[]
    push!(subscriptions,Makie.on(gate_slider.value) do voltage
        selected_gate[]=argmin(abs.(view.vgs.-voltage))
    end)
    push!(subscriptions,Makie.on(drain_menu.selection) do index
        index===nothing || (selected_drain[]=index)
    end)
    selected_point=Makie.lift((i,j)->view.points[i,j],selected_gate,selected_drain)
    marker_positions=map((:id,:gm_over_id,:intrinsic_gain,:cgg)) do quantity
        Makie.lift(selected_gate,selected_point) do i,point
            x=quantity===:gm_over_id ? abs(point.id)/(view.model.width*view.model.multiplicity) : quantity===:intrinsic_gain ? point.gm_over_id : view.vgs[i]
            y=_mos_quantity(point,quantity)
            valid=isfinite(x)&&isfinite(y) && (quantity===:gm_over_id ? x>0 : quantity in (:id,:intrinsic_gain) ? y>0 : true)
            [valid ? Makie.Point2f(x,y) : Makie.Point2f(NaN,NaN)]
        end
    end
    axes=(transfer=transfer.axes.characteristic,gmid=efficiency.axes.gmid,
        gain=gain.axes.characteristic,capacitance=capacitance.axes.characteristic)
    markers=map((ax,points)->Makie.scatter!(ax,points;color=_AMBER_COLORS.warning,
        strokecolor=:black,strokewidth=1,markersize=12),Tuple(values(axes)),marker_positions)
    # Clicking a voltage-domain panel selects the nearest sampled gate bias.
    for ax in (axes.transfer,axes.gain,axes.capacitance)
        push!(subscriptions,Makie.on(Makie.events(ax).mousebutton;priority=10) do event
            event.button==Makie.Mouse.left && event.action==Makie.Mouse.press && Makie.is_mouseinside(ax.scene) || return Makie.Consume(false)
            target=Makie.mouseposition(ax)[1]
            voltage=if ax===axes.gain
                efficiencies=[p.gm_over_id for p in view.points[:,selected_drain[]]]
                distance=[isfinite(value) ? abs(value-target) : Inf for value in efficiencies]
                view.vgs[argmin(distance)]
            else
                target
            end
            Makie.set_close_to!(gate_slider,voltage)
            Makie.Consume(true)
        end)
    end
    readout=Makie.lift(selected_point,selected_gate,selected_drain) do point,i,j
        "Vg = $(engineering(view.vgs[i];unit="V"))    Vd = $(engineering(view.vds[j];unit="V"))    |ID| = $(engineering(abs(point.id);unit="A"))    gm/|ID| = $(engineering(point.gm_over_id;unit="1/V"))    Cgg = $(engineering(point.capacitance_matrix[2,2];unit="F"))"
    end
    Makie.Label(figure[5,1:2],readout;halign=:left,tellwidth=false)
    Makie.Label(figure[6,1:2],first(view.warnings);halign=:left,tellwidth=false)
    Makie.colsize!(figure.layout,1,Makie.Relative(.5))
    Makie.colsize!(figure.layout,2,Makie.Relative(.5))
    plots=(transfer=transfer.plots.curves,gmid=efficiency.plots.curves,
        gain=gain.plots.curves,capacitance=capacitance.plots.curves,selected=markers)
    measurements=Dict{Symbol,Any}(:selected_gate=>selected_gate,:selected_drain=>selected_drain,
        :selected_point=>selected_point,:gate_control=>gate_slider,:drain_control=>drain_menu,
        :bias_readout=>readout,:mosfet_view=>view)
    cleanup=()->(foreach(Makie.off,subscriptions);empty!(subscriptions);nothing)
    handle=WorkbenchHandle(figure,axes,plots,Makie.Observable(Symbol[]),nothing,measurements,
        copy(view.warnings),copy(view.provenance),cleanup,false)
    _contextualize!(handle;help="Choose a drain bias and move the gate slider; click a voltage-domain plot to inspect the nearest stored bias point. Units and model parameters are retained on export.")
end
workbench(model::Amber.ChargeBasedMOSFET;kwargs...)=workbench(mosfetview(model;kwargs...))

"""Snap a CMOS workbench to the nearest stored polarity-normalized gate/drain biases."""
function selectbias!(handle::WorkbenchHandle;vgs=nothing,vds=nothing)
    handle.closed && throw(ArgumentError("workbench is closed"))
    view=get(handle.measurements,:mosfet_view,nothing)
    view===nothing && throw(ArgumentError("workbench does not support CMOS bias selection"))
    for value in (vgs,vds)
        value===nothing || (value isa Real && isfinite(value)) || throw(ArgumentError("bias must be finite"))
    end
    if vgs!==nothing
        Makie.set_close_to!(handle.measurements[:gate_control],vgs)
    end
    if vds!==nothing
        handle.measurements[:drain_control].i_selected[]=argmin(abs.(view.vds.-vds))
    end
    handle
end
