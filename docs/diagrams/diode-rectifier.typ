#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  vsource("source", (0, 0), (0, 3), current: "sin", label: $V_"AC"$)
  diode("d", "source.out", (rel: (3, 0)), label: $D_1$)
  wire("d.out", (6, 3))
  capacitor("c", (4, 3), (4, 0), label: $C_1$)
  resistor("load", (6, 3), (6, 0), label: $R_"load"$)
  wire((0, 0), (6, 0))
  node("out", (6, 3), label: $V_"out"$)
  ground("gnd", (3, 0))
})
