@testset "native mathematical verification" begin
    include("utilities.jl")
    include("dc_reference.jl")
    include("linear_dynamics_reference.jl")
    include("controlled_sources_reference.jl")
    include("device_reference.jl")
    include("noise_reference.jl")
    include("jacobians.jl")
    include("conservation.jl")
    include("convergence_order.jl")
    include("metamorphic.jl")
    include("storage_and_periodic.jl")
end
