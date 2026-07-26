#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 10pt)
#set text(size: 10pt)

#zap.circuit({
  import zap: *

  // Wheatstone bridge, drawn as two matched divider legs.
  wire((1, 6), (5, 6))
  vcc("exc", (3, 6), label: $V_"exc"$)
  resistor("r1", (1, 6), (1, 3), label: $R_1$)
  resistor("r2", (1, 3), (1, 0), label: $R_2$)
  resistor("r3", (5, 6), (5, 3), label: $R_3$)
  resistor("r4", (5, 3), (5, 0), label: $R_4$)
  wire((1, 0), (5, 0))
  ground("gnd", (3, 0))
  node("vp", (1, 3))
  node("vm", (5, 3))

  // The tutorial implements this block as a three-op-amp INA. Keeping it as
  // one functional block makes the bridge connection legible at this scale.
  // Offset the origin so the inverting pin aligns with the right midpoint.
  opamp("amp", (8.5, 2.55), label: "INA")
  wire((5, 3), "amp.minus")
  // Route the other midpoint outside the bridge. Both inputs are real wires;
  // no connection is implied only by a repeated net label.
  wire((1, 3), (0, 3), (0, -1), (6.8, -1), (6.8, 2.1), "amp.plus")
  estub("amp.out", label: $V_"out"$)
})
