#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 10pt)
#set text(size: 10pt)

#zap.circuit({
  import zap: *

  // Supply and ground rails.
  wire((3.8, 6.5), (8.0, 6.5))
  vcc("vcc", (5.9, 6.5), label: $V_"CC"$)
  wire((0, 0), (10.5, 0))
  ground("gnd", (5.9, 0))

  // Source and AC input coupling.
  vsource("input", (0, 0), (0, 3.2), current: "sin", label: $V_"in"$)
  resistor("rs", (0, 3.2), (2.0, 3.2), label: $R_s$)
  capacitor("cin", (2.0, 3.2), (3.8, 3.2), label: $C_"in"$)

  // DC bias divider; its midpoint is the transistor base node.
  resistor("rb1", (3.8, 6.5), (3.8, 3.2), label: $R_1$)
  resistor("rb2", (3.8, 3.2), (3.8, 0), label: $R_2$)
  node("base-node", (3.8, 3.2))

  // Common-emitter gain stage.
  bjt("q", (5.5, 3.2), label: $Q_1$)
  wire((3.8, 3.2), "q.b")
  wire("q.c", (6.3, 4.2))
  resistor("rc", (6.3, 4.2), (6.3, 6.5), label: $R_C$)
  node("collector-node", (6.3, 4.2))
  wire("q.e", (6.3, 2.2))
  resistor("re", (6.3, 2.2), (6.3, 0), label: $R_E$)

  // C_E is genuinely in parallel with R_E.
  wire((6.3, 2.2), (7.8, 2.2))
  capacitor("ce", (7.8, 2.2), (7.8, 0), label: $C_E$)
  node("emitter-node", (6.3, 2.2))

  // AC-coupled output and load.
  wire((6.3, 4.2), (8.0, 4.2))
  capacitor("cout", (8.0, 4.2), (10.5, 4.2), label: $C_"out"$)
  resistor("load", (10.5, 4.2), (10.5, 0), label: $R_L$)
  node("out", (10.5, 4.2), label: $V_"out"$)
})
