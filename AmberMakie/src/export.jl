function savefigure(path, handle::Union{PlotHandle,WorkbenchHandle}; include_metadata=true, kwargs...)
    figure = handle isa WorkbenchHandle ? handle.figure : Makie.get_figure(handle.layout)
    Makie.save(path, figure; kwargs...)
    if include_metadata && handle isa WorkbenchHandle
        sidecar = string(path, ".toml")
        open(sidecar, "w") do io
            println(io, "amber_makie_version = \"0.1.0\"")
            println(io, "warnings = ", repr(handle.warnings))
        end
    end
    path
end

function copyrecipe(handle::PlotHandle)
    "# AmberMakie $(nameof(typeof(handle.view))) view; recreate with the corresponding semantic plot function"
end

function copyrecipe(handle::WorkbenchHandle)
    "workbench(result) # restore selections and cursor values programmatically"
end
