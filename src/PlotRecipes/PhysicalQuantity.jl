module PhysicalQuantity

using Plots

# Include module `TimeLine`
import ...TimeLine
using StaticArrays

export angularvelocities, quaternions

"""
    function angularvelocities(time::StepRangeLen, angularvelocity::Vector{StaticArrays.SVector{3, Float64}}; timerange::Tuple{<:Real, <:Real} = (0, 0))::AbstractPlot

Plots angular velocity of each axis in one figure
"""
function angularvelocities(time::StepRangeLen, angularvelocity::Vector{StaticArrays.SVector{3, Float64}}; timerange::Tuple{<:Real, <:Real} = (0, 0))::AbstractPlot

    plt = plot();
    plt = plot!(plt, time, angularvelocity, 1, timerange = timerange);
    plt = plot!(plt, time, angularvelocity, 2, timerange = timerange);
    plt = plot!(plt, time, angularvelocity, 3, timerange = timerange);

    return plt
end

"""
function quaternions(time::StepRangeLen, quaternion::Vector{StaticArrays.SVector{4, Float64}}; timerange::Tuple{<:Real, <:Real} = (0, 0))

    Plot quaternions in single plot
"""
function quaternions(time::StepRangeLen, quaternion::Vector{StaticArrays.SVector{4, Float64}}; timerange::Tuple{<:Real, <:Real} = (0, 0))

    plt = plot();
    plt = plot!(plt, time, quaternion, 1, timerange = timerange);
    plt = plot!(plt, time, quaternion, 2, timerange = timerange);
    plt = plot!(plt, time, quaternion, 3, timerange = timerange);
    plt = plot!(plt, time, quaternion, 4, timerange = timerange);

    return plt
end

@recipe function f(time::StepRangeLen, quaternion::Vector{StaticArrays.SVector{4, Float64}}, index::Integer; timerange = (0, 0))
    if !(1 <= index <= 4)
        throw(BoundsError(quaternion[1], index))
    end

    xguide --> "Time (s)"
    yguide --> "Quaternion (-)"

    if index == 1
        label --> "q1"
    elseif index == 2
        label --> "q2"
    elseif index == 3
        label --> "q3"
    elseif index == 4
        label --> "q4"
    else
        throw(ArgumentError("argument `index` is set improperly"))
    end

    # get the index for data
    dataindex = TimeLine.getdataindex(timerange, convert(Float64, time.step))

    return time[dataindex], quaternion[dataindex, index]
end

@recipe function f(time::StepRangeLen, angularvelocity::Vector{StaticArrays.SVector{3, Float64}}, axisindex::Integer; timerange = (0, 0))

    plotlyjs()

    xguide --> "Time (s)"
    yguide --> "Angular velocity (rad/s)"

    if axisindex == 1
        label --> "x-axix"
    elseif axisindex == 2
        label --> "y-axis"
    elseif axisindex == 3
        label --> "z-axis"
    else
        throw(ArgumentError("argument `axisindex` is set improperly"))
    end

    # get the index for data
    dataindex = TimeLine.getdataindex(timerange, convert(Float64, time.step))

    return time[dataindex], angularvelocity[dataindex, axisindex]
end

end
