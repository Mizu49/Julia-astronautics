"""
    SimulationCore

submodule contains the high-level interface functions and core implementation of the simulation features
"""
module SimulationCore

using LinearAlgebra, StaticArrays
using ..Frames, ..Orbit, ..Disturbance, ..DynamicsBase, ..Attitude, ..Structures, ..ParameterSettingBase

export runsimulation

############# runsimulation function ##################################
"""
    runsimulation(attitudemodel, initvalue::Attitude.InitData, orbitinfo::Orbit.OrbitInfo, distconfig::DisturbanceConfig, simconfig::SimulationConfig)::Tuple

Function that runs simulation of the spacecraft attitude-structure coupling problem

# Arguments

* `attitudemodel`: Attitude dynamics model of the system
* `strmodel`: Structural model of the flexible appendages
* `initvalue::InitData`: Inital value of the simulation physical states
* `orbitinfo::Orbit.OrbitInfo`: information and model definition of the orbital dynamics
* `distconfig::DisturbanceConfig`: Disturbanve torque input configuration
* `simconfig::SimulationConfig`: Simulation configuration ParameterSettingBase

# Return value

Return is tuple of `(time, attidata, orbitdata, strdata``)`

* `time`: 1-D array of the time
* `attidata`: Struct of time trajectory of the physical amount states of the spacecraft system
* `orbitdata`: Struct of the orbit state trajectory
* `strdata`: Struct of the trajectory of the state of the flexible appendage

# Usage

```julia
(time, attitudedata, orbitdata, strdata) = runsimulation(attitudemodel, strmodel, initvalue, orbitinfo, distconfig, simconfig)
```

"""
@inline function runsimulation(
    attitudemodel,
    strmodel,
    initvalue::Attitude.InitData,
    orbitinfo::Orbit.OrbitInfo,
    distconfig::DisturbanceConfig,
    simconfig::SimulationConfig
    )::Tuple

    # misc of the simulation implementation
    Ts = simconfig.samplingtime

    # array of the time
    time = 0:Ts:simconfig.simulationtime

    # Numbers of simulation data
    datanum = floor(Int, simconfig.simulationtime/Ts) + 1;

    # Initialize data containers for the attitude dynamics
    attidata = initattitudedata(datanum, initvalue)

    # initialize data container for the structural motion of the flexible appendages
    strdata = initappendagedata(strmodel, [0, 0, 0, 0], datanum)

    # transformation matrix from ECI frame to orbital plane frame
    C_ECI2OrbitPlane = Orbit.ECI2OrbitalPlaneFrame(orbitinfo.orbitalelement)

    # initialize orbit state data array
    orbitdata = Orbit.initorbitdata(datanum, orbitinfo.planeframe)

    # main loop of the simulation
    for iter = 1:datanum

        ############### orbit state ##################################################
        orbitdata.angularvelocity[iter] = Orbit.get_angular_velocity(orbitinfo.orbitmodel)
        orbitdata.angularposition[iter] = orbitdata.angularvelocity[iter] * time[iter]

        # calculation of the LVLH frame and its transformation matrix
        C_OrbitPlane2RAT = Orbit.OrbitalPlaneFrame2RadialAlongTrack(orbitinfo.orbitalelement, orbitdata.angularvelocity[iter], time[iter])
        C_ECI2LVLH = T_RAT2LVLH * C_OrbitPlane2RAT * C_ECI2OrbitPlane
        orbitdata.LVLH[iter] = C_ECI2LVLH * RefFrame

        ############### attitude #####################################################
        # Update current attitude
        C_ECI2Body = ECI2BodyFrame(attidata.quaternion[iter])
        attidata.bodyframe[iter] = C_ECI2Body * RefFrame
        # update the euler angle representations
        C_LVLH2Body = T_LVLHref2rollpitchyaw * C_ECI2Body * transpose(C_ECI2LVLH)
        attidata.RPYframe[iter] = C_LVLH2Body * RefFrame
        attidata.eulerangle[iter] = dcm2euler(C_LVLH2Body)

        ############### flexible appendages state ####################################
        strdata.physicalstate[iter] = modalstate2physicalstate(strmodel, strdata.state[iter])

        ############### disturbance torque input to the attitude dynamics ############
        attidistinput = disturbanceinput(distconfig, attitudemodel.inertia, orbitdata.angularvelocity[iter], C_ECI2Body, C_ECI2LVLH, orbitdata.LVLH[iter].z)

        ############### control and disturbance input to the flexible appendages
        strdistinput = 100 * sin(10* time[iter])
        strctrlinput = 0

        strdata.controlinput[iter] = strctrlinput
        strdata.disturbance[iter] = strdistinput

        ############### coupling dynamics of the flexible spacecraft ###############

        # calculation of the structural response input for the attitude dynamics
        currentstrstate = strdata.state[iter]
        if iter == 1
            straccel = currentstrstate[3:end] / Ts
        else
            previousstrstate = strdata.state[iter-1]
            straccel = (currentstrstate[3:end] - previousstrstate[3:end]) / Ts
        end
        strvelocity = currentstrstate[3:end]

        # angular velocity of the attitude dynamics for the structural coupling input
        attiinput = attidata.angularvelocity[iter]

        ################## Time evolution of the system ##############################
        if iter != datanum

            # Update angular velocity
            attidata.angularvelocity[iter+1] = update_angularvelocity(attitudemodel, time[iter], attidata.angularvelocity[iter], Ts, attidata.bodyframe[iter], attidistinput, straccel, strvelocity)

            # Update quaternion
            attidata.quaternion[iter+1] = update_quaternion(attidata.angularvelocity[iter], attidata.quaternion[iter], Ts)

            # Update the state of the flexible appendages
            strdata.state[iter+1] = updatestate(strmodel, Ts, time[iter], strdata.state[iter], attiinput, strctrlinput, strdistinput)

        end

    end

    return (time, attidata, orbitdata, strdata)
end

end
