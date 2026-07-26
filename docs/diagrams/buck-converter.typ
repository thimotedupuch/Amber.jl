#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  vsource("input", (0, 0), (0, 3), label: $V_"in"$)
  switch("switch", "input.out", (3, 3), label: $S$, closed: false)
  inductor("l", (3, 3), (6, 3), label: $L$)
  wire("l.out", (8, 3))
  diode("catch", (3, 0), (3, 3), label: $D$)
  capacitor("c", (6, 3), (6, 0), label: $C$)
  resistor("load", (8, 3), (8, 0), label: $R_"load"$)
  wire((0, 0), (8, 0))
  node("sw", (3, 3), label: $V_"sw"$)
  node("out", (8, 3), label: $V_"out"$)
  ground("gnd", (4.5, 0))
})
