using Test
using Amber

include("fixtures/circuits.jl")

@testset "Amber.jl" begin
    include("Core/circuit_ir.jl")
    include("Core/hierarchy.jl")
    include("Core/compiler_ir.jl")
    include("Core/units.jl")
    include("Core/serialization.jl")
    include("Devices/models.jl")
    include("Devices/mosfet.jl")
    include("Devices/controlled_sources.jl")
    include("Solvers/operating_point.jl")
    include("Solvers/transient.jl")
    include("Solvers/periodic_steady_state.jl")
    include("Solvers/small_signal.jl")
    include("Solvers/network.jl")
    include("Solvers/noise.jl")
    include("Analysis/sweeps.jl")
    include("Analysis/monte_carlo.jl")
    include("Analysis/metrics.jl")
    include("Analysis/spectrum.jl")
    include("Analysis/control.jl")
    include("Analysis/feedback.jl")
    include("Results/results.jl")
    include("Diagnostics/diagnostics.jl")
    include("reference/examples.jl")
    include("reference/gallery.jl")
    include("verification/runtests.jl")
end
