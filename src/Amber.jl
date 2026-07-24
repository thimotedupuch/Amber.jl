module Amber

using LinearAlgebra
using SparseArrays
using SHA

export Circuit, Node, Ground, Component, CompiledCircuit, SimulationResult
export circuit, node!, ground!, add!, observe!, observe, compile, check, describe
export node, ground, resistor, capacitor, inductor, conductance
export voltage_source, current_source, source, diode, npn, opamp, analog_switch
export transconductance, voltage_controlled_current_source, voltage_controlled_voltage_source, voltage_amplifier
export current_controlled_current_source, current_controlled_voltage_source, current_amplifier, transresistance
export voltage, current, power, charge, state, initial_voltage
export differential_capacitance
export operating_point, transient, small_signal, simulate, run, sweep
export noise, NoiseResult, output_noise_density, input_referred_noise_density
export OperatingPoint, Transient, SmallSignal, frequencies, trace, transfer
export MatchedGroup, matched_group, Differential
export magnitude, phase, region, ForwardActive, Saturation, Cutoff
export provenance, report, validity_report, available_observables
export result_table
export compare, peak_to_peak, periodic_metrics, sampling_metrics, propagation_delay, overshoot
export Step, Sine, Pulse, ThinFilm, SMD0603, C0G, DebyeBranches
export JunctionDiode, GummelPoonBJT, BehavioralOpAmp, VoltageControlledSwitch
export SmoothSwitch, EventSwitch, IdealResistor, IdealCapacitor
export @circuit
export Ω, kΩ, MΩ, GΩ, TΩ, mΩ, V, mV, μV, nV, A, mA, μA, nA, pA, fA
export F, mF, μF, nF, pF, fF, H, mH, μH, nH, pH
export C, mC, μC, nC, pC, fC
export s, ms, μs, ns, ps, Hz, kHz, MHz, GHz, K, m, μS, dB, percent
export °

include("Core/Units.jl")
include("Core/Ports.jl")
include("Devices/Models.jl")
include("Core/CircuitIR.jl")
include("Devices/Ideal.jl")
include("Devices/Passive.jl")
include("Devices/Semiconductor.jl")
include("Devices/Behavioral.jl")
include("Diagnostics/Diagnostics.jl")
include("Core/EquationGraph.jl")
include("Core/Compilation.jl")
include("Analysis/Analyses.jl")
include("Results/Results.jl")
include("Results/Tabular.jl")
include("Solvers/Nonlinear.jl")
include("Solvers/OperatingPoint.jl")
include("Solvers/Transient.jl")
include("Solvers/SmallSignal.jl")
include("Solvers/Noise.jl")
include("Analysis/Sweeps.jl")
include("Analysis/Metrics.jl")

end
