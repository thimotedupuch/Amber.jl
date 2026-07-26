#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  wstub((0, 3), label: $V_"in"$)
  resistor("r1", (0, 3), (3, 3), label: $R_1$)
  resistor("r2", (3, 3), (6, 3), label: $R_2$)
  capacitor("c2", (6, 3), (6, 0), label: $C_2$)
  // Place the op-amp so its `plus` anchor is exactly on the sense-node row.
  opamp("buffer", (9, 3.45), label: "buffer")
  wire((6, 3), "buffer.plus")
  wire(
    "buffer.out",
    (11, 3.45),
    (11, 4.55),
    (7.8, 4.55),
    (7.8, 3.9),
    "buffer.minus",
  )
  wire((3, 3), (3, 5))
  capacitor("c1", (3, 5), (8, 5), label: $C_1$)
  wire("c1.out", (11, 5), (11, 3.45))
  wire((3, 0), (6, 0))
  ground("gnd", (4.5, 0))
  estub((11, 3.45), label: $V_"out"$)
})
