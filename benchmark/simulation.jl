using Amber
using TOML

@subcircuit SimulationCell(input, output, reference; R = 1.0e3, C = 1.0e-9) begin
    R1 = resistor(input, output; value = R)
    C1 = capacitor(output, reference; value = C)
end

function simulation_design(cells)
    builder = CircuitBuilder(:SimulationLadder)
    reference = ground!(builder, :gnd)
    nodes = node_array!(builder, :x, 0:cells)
    add!(builder, voltage_source(nodes[0], reference; dc = 1.0, waveform = Step(at = 0.0)); name = :Source)
    instances!(
        builder, SimulationCell, 1:cells;
        name = i -> (:cell, i),
        connections = i -> (input = nodes[i - 1], output = nodes[i], reference = reference)
    )
    return finish(builder)
end

function measure(cells, steps)
    construction = @timed simulation_design(cells)
    compilation = @timed compile(construction.value)
    compiled = compilation.value
    dc = @timed operating_point(compiled)
    dc.value.stats[:converged]||error("benchmark operating point failed")
    transient_run = @timed transient(
        compiled, 0.0 => 1.0e-4; initial = :discharged,
        saveat = 1.0e-4 / steps, max_step = 1.0e-4 / steps
    )
    transient_run.value.stats[:converged]||error("benchmark transient failed")
    result = Dict{String, Any}(
        "cells" => cells, "steps" => steps, "unknowns" => compiled.n,
        "result_retained_bytes" => Base.summarysize(transient_run.value),
        "process_peak_rss_bytes" => Sys.maxrss(), "julia_version" => string(VERSION),
        "threads" => Threads.nthreads()
    )
    for (name, timing) in (
            ("construction", construction), ("compilation", compilation),
            ("operating_point", dc), ("transient", transient_run),
        )
        result[name * "_seconds"] = timing.time
        result[name * "_allocated_bytes"] = timing.bytes
    end
    return result
end

cells = parse(Int, get(ENV, "AMBER_BENCH_CELLS", "100"))
steps = parse(Int, get(ENV, "AMBER_BENCH_STEPS", "100"))
measure(2, 2) # Compile the execution paths before timing.
Base.GC.gc()
TOML.print(stdout, measure(cells, steps); sorted = true)
