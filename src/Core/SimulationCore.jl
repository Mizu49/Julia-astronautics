"""
    SimulationCore

submodule contains the high-level interface functions and core implementation of the simulation features
"""
module SimulationCore

using LinearAlgebra, StaticArrays, ProgressMeter
using ..Frames, ..OrbitBase, ..AttitudeDisturbance, ..DynamicsBase, ..KinematicsBase, ..StructuresBase, ..StructureDisturbance, ..ParameterSettingBase, ..AttitudeControlBase

export SimData, runsimulation

"""
    SimData

data container for one simulation result.

# Fields

* `time::StepRangeLen`: time information
* `datanum::Unsigned`: numbers of simulation data
* `attitude::AttitudeData`: data container for attitude dynamics
* `appendages::AppendageData`: data container for the appendages
* `orbit::OrbitData`: data contaier for orbit data

"""
struct SimData
    time::StepRangeLen
    datanum::Unsigned
    attitude::AttitudeData
    appendages::Union{AppendageData, Nothing}
    orbit::OrbitData
end


############# runsimulation function ##################################
"""
    runsimulation

Function that runs simulation of the spacecraft attitude-structure coupling problem

# Arguments

* `attitudemodel`: KinematicsBase dynamics model of the system
* `strmodel`: Structural model of the flexible appendages
* `initvalue::InitData`: Inital value of the simulation physical states
* `orbitinfo::OrbitBase.OrbitInfo`: information and model definition of the orbital dynamics
* `distconfig::DisturbanceConfig`: Disturbanve torque input configuration
* `simconfig::SimulationConfig`: Simulation configuration ParameterSettingBase

# Return value

return value is the instance of `SimData`

# Usage

```julia
simdata = runsimulation(attitudemodel, strmodel, initvalue, orbitinfo, distconfig, simconfig)
```

"""
@inline function runsimulation(
    attitudemodel,
    strmodel,
    initvalue::KinematicsBase.InitData,
    orbitinfo::OrbitBase.OrbitInfo,
    distconfig::DisturbanceConfig,
    distinternals::DisturbanceInternals,
    strdistconfig::AbstractStrDistConfig,
    simconfig::SimulationConfig,
    attitude_controller
    )::SimData

    ##### Constants
    # Sampling tl.time
    Ts = simconfig.samplingtime

    # transformation matrix from ECI frame to orbital plane frame
    C_ECI2OrbitPlane = OrbitBase.ECI2OrbitalPlaneFrame(orbitinfo.orbitalelement)

    # Data containers
    tl = _init_datacontainers(simconfig, initvalue, strmodel, orbitinfo)

    ### main loop of the simulation
    prog = Progress(tl.datanum, 1, "Simulation running...", 50)   # progress meter
    for iter = 1:tl.datanum

        ### orbit state
        tl.orbit.angularvelocity[iter] = get_angular_velocity(orbitinfo.orbitmodel)
        tl.orbit.angularposition[iter] = tl.orbit.angularvelocity[iter] * tl.time[iter]

        # calculation of the LVLH frame and its transformation matrix
        C_OrbitPlane2RAT = OrbitalPlaneFrame2RadialAlongTrack(orbitinfo.orbitalelement, tl.orbit.angularvelocity[iter], tl.time[iter])
        C_ECI2RAT = C_OrbitPlane2RAT * C_ECI2OrbitPlane
        C_ECI2LVLH = C_ECI2RAT

        ### attitude state
        # Update current attitude
        C_ECI2Body = ECI2BodyFrame(tl.attitude.quaternion[iter])
        tl.attitude.bodyframe[iter] = C_ECI2Body * UnitFrame

        # update the roll-pitch-yaw representations
        C_RAT2Body = C_ECI2Body * transpose(C_ECI2RAT)
        C_LVLH2Body = C_ECI2Body * transpose(C_ECI2LVLH)
        # euler angle from RAT to Body frame is the roll-pitch-yaw angle of the spacecraft
        current_RPY = dcm2euler(C_LVLH2Body)
        tl.attitude.eulerangle[iter] = current_RPY
        # RPYframe representation can be obtained from the LVLH unit frame
        tl.attitude.RPYframe[iter] = C_LVLH2Body * LVLHUnitFrame

        ### flexible appendages state
        if isnothing(strmodel)
            # do nothing
        else
            tl.appendages.physicalstate[iter] = modalstate2physicalstate(strmodel, tl.appendages.state[iter])
        end

        ### input to the attitude dynamics
        # disturbance input
        attidistinput = transpose(C_ECI2Body) * calc_attitudedisturbance(distconfig, distinternals, attitudemodel.inertia, tl.time[iter], tl.orbit.angularvelocity[iter], C_ECI2Body, C_ECI2RAT, tl.orbit.LVLH[iter].z, Ts)
        # control input
        attictrlinput = transpose(C_ECI2Body) * control_input!(attitude_controller, current_RPY, [0, 0, 0])

        ### input to the structural dynamics
        if isnothing(strmodel)
            strdistinput = nothing
            strctrlinput = nothing
        else
            # disturbance input
            strdistinput = calcstrdisturbance(strdistconfig, tl.time[iter])
            # control input
            strctrlinput = 0
            # data log
            tl.appendages.controlinput[iter] = strctrlinput
            tl.appendages.disturbance[iter] = strdistinput
        end

        ### attitude-structure coupling dynamics
        # calculation of the structural response input for the attitude dynamics
        if isnothing(strmodel)
            straccel = 0
            strvelocity = 0
            attiinput = 0
        else
            currentstrstate = tl.appendages.state[iter]
            if iter == 1
                if typeof(currentstrstate) <: AbstractVector
                    straccel = currentstrstate[(strmodel.DOF+1):end] / Ts
                    strvelocity = currentstrstate[(strmodel.DOF+1):end]
                else
                    straccel = currentstrstate / Ts
                    strvelocity = currentstrstate
                end
            else
                if typeof(currentstrstate) <: AbstractVector
                    previousstrstate = tl.appendages.state[iter-1]
                    straccel = (currentstrstate[(strmodel.DOF+1):end] - previousstrstate[(strmodel.DOF+1):end]) / Ts
                    strvelocity = currentstrstate[(strmodel.DOF+1):end]
                else
                    previousstrstate = tl.appendages.state[iter-1]
                    straccel = (currentstrstate - previousstrstate) / Ts
                    strvelocity = currentstrstate
                end
            end
            # angular velocity of the attitude dynamics for the structural coupling input
            attiinput = tl.attitude.angularvelocity[iter]
        end

        ### Time evolution of the system
        if iter != tl.datanum

            # Update angular velocity
            tl.attitude.angularvelocity[iter+1] = update_angularvelocity(attitudemodel, tl.time[iter], tl.attitude.angularvelocity[iter], Ts, tl.attitude.bodyframe[iter], attidistinput, attictrlinput, straccel, strvelocity)

            # Update quaternion
            tl.attitude.quaternion[iter+1] = update_quaternion(tl.attitude.angularvelocity[iter], tl.attitude.quaternion[iter], Ts)

            # Update the state of the flexible appendages
            if isnothing(strmodel)
                # do nothing
            else
                tl.appendages.state[iter+1] = update_strstate(strmodel, Ts, tl.time[iter], tl.appendages.state[iter], attiinput, strctrlinput, strdistinput)
            end
        end
        # update the progress meter
        next!(prog)
    end

    return tl
end

function _init_datacontainers(simconfig, initvalue, strmodel, orbitinfo)

    time = 0:simconfig.samplingtime:simconfig.simulationtime

    # Numbers of simulation data
    datanum = floor(Int, simconfig.simulationtime/simconfig.samplingtime) + 1;

    # Initialize data containers for the attitude dynamics
    attitude = initattitudedata(datanum, initvalue)

    # initialize data container for the structural motion of the flexible appendages
    appendages = initappendagedata(strmodel, [0, 0, 0, 0], datanum)

    # initialize orbit state data array
    orbit = initorbitdata(datanum, orbitinfo.planeframe)

    # initialize simulation data container
    tl = SimData(time, datanum, attitude, appendages, orbit)

    return tl
end

end
