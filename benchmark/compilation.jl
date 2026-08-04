using Amber
using TOML

@subcircuit CompilationCell(input, output, reference; R=1kΩ, C=1nF) begin
    R1 = resistor(input, output; value=R)
    C1 = capacitor(output, reference; value=C)
end

function compilation_design(cells::Integer)
    builder = CircuitBuilder(:CompilationLadder)
    reference = ground!(builder, :gnd)
    nodes = node_array!(builder, :x, 0:cells)
    instances!(builder, CompilationCell, 1:cells;
        name=index -> (:cell, index),
        connections=index -> (input=nodes[index - 1], output=nodes[index], reference=reference),
        parameters=_ -> (R=1kΩ, C=1nF))
    finish(builder)
end

cells = parse(Int, get(ENV, "AMBER_BENCH_CELLS", "500000"))
Amber._compile_hierarchy(compilation_design(10))
design = compilation_design(cells)
Base.GC.gc()
measurement = @timed Amber._compile_hierarchy(design)
topology, parameters = measurement.value

result = Dict(
    "benchmark" => "HierarchicalCompilationLadder",
    "cells" => cells,
    "primitive_devices" => topology.hierarchy.primitive_count,
    "unknowns" => topology.hierarchy.unknown_count,
    "jacobian_nonzeros" => length(topology.pattern.rowval),
    "batch_count" => length(parameters.batches),
    "compilation_seconds" => measurement.time,
    "allocated_bytes" => measurement.bytes,
    "retained_bytes" => Base.summarysize(measurement.value),
    "julia_version" => string(VERSION),
    "threads" => Threads.nthreads(),
)

TOML.print(stdout, result; sorted=true)
