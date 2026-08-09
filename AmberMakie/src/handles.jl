struct PlotHandle{L,A,P,V}
    layout::L
    axes::A
    plots::P
    view::V
end

mutable struct WorkbenchHandle{F,A,P,S,U,M,W,V,C}
    figure::F
    axes::A
    plots::P
    selection::S
    cursors::U
    measurements::M
    warnings::W
    provenance::V
    cleanup::C
    closed::Bool
end

function Base.close(handle::WorkbenchHandle)
    handle.closed && return nothing
    handle.cleanup()
    handle.closed = true
    nothing
end

_position(position) = position isa Makie.Figure ? position[1, 1] : position
