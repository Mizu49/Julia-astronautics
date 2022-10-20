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
    strinternals::AppendageInternals,
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
    current_angularvelocity = tl.attitude.angularvelocity[1]
    current_quaternion = tl.attitude.quaternion[1]
    if !isnothing(strmodel)
        currentstrstate = tl.appendages.state[1]
    end

    ### main loop of the simulation
    prog = Progress(tl.datanum, 1, "Simulation running...", 50)   # progress meter
    for iter = 1:tl.datanum

        # variables
        currenttime = tl.time[iter]

        ### orbit state
        tl.orbit.angularvelocity[iter] = get_angular_velocity(orbitinfo.orbitmodel)
        tl.orbit.angularposition[iter] = tl.orbit.angularvelocity[iter] * currenttime

        # calculation of the LVLH frame and its transformation matrix
        C_OrbitPlane2RAT = OrbitalPlaneFrame2RadialAlongTrack(orbitinfo.orbitalelement, tl.orbit.angularvelocity[iter], currenttime)
        C_ECI2RAT = C_OrbitPlane2RAT * C_ECI2OrbitPlane
        C_ECI2LVLH = C_ECI2RAT

        ### attitude state
        # Update current attitude
        C_ECI2Body = ECI2BodyFrame(current_quaternion)
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
        strinternals.currentstate = currentstrstate
        strinternals.currentaccel = (strinternals.currentstate[(strmodel.DOF+1):end] - strinternals.previousstate[(strmodel.DOF+1):end]) / Ts
        tl.appendages.physicalstate[iter] = modalstate2physicalstate(strmodel, strinternals.currentstate)

        ### input to the attitude dynamics
        # disturbance input
        attidistinput = transpose(C_ECI2Body) * calc_attitudedisturbance(distconfig, distinternals, attitudemodel.inertia, currenttime, tl.orbit.angularvelocity[iter], C_ECI2Body, C_ECI2RAT, tl.orbit.LVLH[iter].z, Ts)
        # control input
        attictrlinput = transpose(C_ECI2Body) * control_input!(attitude_controller, current_RPY, [0, 0, 0])

        ### input to the structural dynamics
        if isnothing(strmodel)
            strdistinput = nothing
            strctrlinput = nothing
        else
            # disturbance input
            strdistinput = calcstrdisturbance(strdistconfig, currenttime)
            # control input
            strctrlinput = 0
            # data log
            tl.appendages.controlinput[iter] = strctrlinput
            tl.appendages.disturbance[iter] = strdistinput
        end

        ### attitude-structure coupling dynamics
        # calculation of the structural response input for the attitude dynamics
        straccel = strinternals.currentaccel
        strvelocity = strinternals.currentstate[(strmodel.DOF+1):end]
        attiinput = current_angularvelocity

        ### save current states
        tl.attitude.angularvelocity[iter] = current_angularvelocity
        tl.attitude.quaternion[iter] = current_quaternion
        if !isnothing(strmodel)
            tl.appendages.state[iter] = currentstrstate
        end

        ### Time evolution of the system
        if iter != tl.datanum

            # Update angular velocity
            current_angularvelocity = update_angularvelocity(attitudemodel, currenttime, current_angularvelocity, Ts, tl.attitude.bodyframe[iter], attidistinput, attictrlinput, straccel, strvelocity)

            # Update quaternion
            current_quaternion = update_quaternion(current_angularvelocity, current_quaternion, Ts)

            # Update the state of the flexible appendages
            if isnothing(strmodel)
                # do nothing
            else
                currentstrstate = update_strstate!(strmodel, strinternals, Ts, currenttime, currentstrstate, attiinput, strctrlinput, strdistinput)
            end
        end

        ### calculation for the next step
        strinternals.previousstate = strinternals.currentstate

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
