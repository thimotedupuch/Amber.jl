using Amber
using TOML

@subcircuit MillionCellRC(input, output, reference; R = 1kΩ, C = 1nF) begin
    R1 = resistor(input, output; value = R)
    C1 = capacitor(output, reference; value = C)
end

function million_cell_ladder(cells::Integer)
    builder = CircuitBuilder(:MillionCellLadder)
    reference = ground!(builder, :gnd)
    nodes = node_array!(builder, :x, 0:cells)
    instances!(
        builder,
        MillionCellRC,
        1:cells;
        name = index -> (:cell, index),
        connections = index -> (input = nodes[index - 1], output = nodes[index], reference = reference),
        parameters = _ -> (R = 1kΩ, C = 1nF),
    )
    return finish(builder)
end

cells = parse(Int, get(ENV, "AMBER_BENCH_CELLS", "500000"))
warm_design = million_cell_ladder(10)
resolve(warm_design, "cell[5].R1")
describe(warm_design; depth = 1, limit = 10)
Base.GC.gc()
measurement = @timed million_cell_ladder(cells)
design = measurement.value
lookup_time = @elapsed resolve(design, "cell[$(max(1, cells ÷ 2))].R1")
description_time = @elapsed describe(design; depth = 1, limit = 10)

result = Dict(
    "benchmark" => "MillionCellLadder",
    "cells" => cells,
    "primitive_devices" => summary(design).primitive_devices,
    "construction_seconds" => measurement.time,
    "allocated_bytes" => measurement.bytes,
    "retained_bytes" => Base.summarysize(design),
    "path_lookup_seconds" => lookup_time,
    "description_seconds" => description_time,
    "julia_version" => string(VERSION),
    "threads" => Threads.nthreads(),
)

TOML.print(stdout, result; sorted = true)
