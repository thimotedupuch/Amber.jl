# Compiler and execution measurements on repeated CMOS, mixed passive networks,
# and heterogeneous behavioral kernels. Run with --project=. from the repo root.
using Amber
using LinearAlgebra
using TOML

@subcircuit PipelineCell(input, output, reference; R = 1.0e3, C = 1.0e-12) begin
    R1 = resistor(input, output; value = R)
    C1 = capacitor(output, reference; value = C)
end

function pipeline_design(cells; nonlinear = false, behavioral = false)
    builder = CircuitBuilder(:CompilerPipeline)
    gnd = ground!(builder, :gnd); nodes = node_array!(builder, :x, 0:cells)
    add!(builder, voltage_source(nodes[0], gnd; dc = 0.8, ac = 1.0); name = :Source)
    instances!(
        builder, PipelineCell, 1:cells;
        name = i -> (:cell, i), connections = i -> (input = nodes[i - 1], output = nodes[i], reference = gnd)
    )
    if nonlinear
        model = ChargeBasedMOSFET(width = 2.0e-6, length = 1.0e-6)
        for i in 1:cells
            add!(builder, nmos(nodes[i], nodes[0], gnd, gnd; model); name = (:M, i))
        end
    end
    if behavioral
        # Distinct callable types exercise batch diversity without eval or
        # specializing on individual device names.
        for (i, (law, slope)) in enumerate(
                zip(
                    (sin, tanh, exp, identity),
                    (cos, x -> 1 - tanh(x)^2, exp, x -> 1.0)
                )
            )
            i > cells && break
            add!(
                builder, behavioral_current_source(
                    ((nodes[i], gnd),), nodes[i], gnd;
                    current = (v, t) -> 1.0e-6 * law(v[1]),
                    gradient = (v, t) -> (1.0e-6 * slope(v[1]), 0.0, 0.0, 0.0)
                ); name = (:B, i)
            )
        end
    end
    return finish(builder)
end

function sample_time(f; repeats = 10)
    f()
    samples = [@timed f() for _ in 1:repeats]
    best = argmin(item -> item.time, samples)
    return Dict("seconds" => best.time, "allocated_bytes" => best.bytes)
end

function pipeline_measure(cells; nonlinear = false, behavioral = false)
    design = pipeline_design(cells; nonlinear, behavioral)
    compilation = @timed compile(design)
    cc = compilation.value; ws = SimulationWorkspace(cc)
    x = fill(0.4, cc.n); previous = x .- 0.001; alpha = 1.0e6
    history = Amber._storage(cc, previous)
    first_evaluation = @timed Amber._step_residual_jacobian!(ws, cc, x, history, 0.0, alpha)
    handle = parameter_handle(cc, "cell[1:$(cells)].R1.value")
    result = Dict{String, Any}(
        "unknowns" => cc.n, "batches" => length(cc.parameters.batches),
        "first_elaboration_seconds" => compilation.time,
        "first_elaboration_jit_seconds" => compilation.compile_time,
        "first_evaluation_seconds" => first_evaluation.time,
        "first_evaluation_jit_seconds" => first_evaluation.compile_time,
        "warm_elaboration" => sample_time(() -> compile(design)),
        "step_residual_jacobian" => sample_time(() -> Amber._step_residual_jacobian!(ws, cc, x, history, 0.0, alpha)),
        "step_residual" => sample_time(() -> Amber._step_residual!(ws, cc, x, history, 0.0, alpha)),
        "text_parameter_update" => sample_time(() -> with_parameters(cc, "cell[1:$(cells)].R1.value" => 2.0e3)),
        "resolved_parameter_update" => sample_time(() -> with_parameters(cc, handle => 2.0e3)),
        "structural_analysis" => sample_time(() -> structural_analysis(cc)),
        "workspace_retained_bytes" => Base.summarysize(ws)
    )
    if !behavioral
        fs = 10.0 .^ range(1, 6; length = 40)
        result["ac_sweep"] = sample_time(() -> small_signal(cc, fs); repeats = 3)
    end
    return result
end

cells = parse(Int, get(ENV, "AMBER_BENCH_CELLS", "100"))
results = Dict(
    "cells" => cells, "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
    "passive" => pipeline_measure(cells),
    "cmos" => pipeline_measure(cells; nonlinear = true),
    "behavioral" => pipeline_measure(cells; behavioral = true)
)
TOML.print(stdout, results; sorted = true)
