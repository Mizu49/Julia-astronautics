module FlexibleSpacecraft

using Reexport

@reexport using LinearAlgebra
@reexport using Plots

include("DataContainers/Frames.jl")
@reexport using .Frames

# Include module `TimeLine`
include("DataContainers/TimeLine.jl")
@reexport using .TimeLine

# Include module `Orbit`
include("OrbitalDynamics/Orbit.jl")
@reexport using .Orbit

# Inculde module `Disturbance`
include("Disturbances/Disturbance.jl")
@reexport using .Disturbance

# Include module `RigidBody.jl`
include("AttitudeDynamics/RigidBody.jl")
@reexport using .RigidBody

# Include module `PlotRecipe`
include("PlotRecipes/PlotRecipe.jl")
@reexport using .PlotRecipe

include("SimulationAPI/runsimulation.jl")
export runsimulation

end # module
