#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  vsource("source", (0, 0), (0, 3), label: $V_"in"$)
  resistor("r", "source.out", (rel: (3, 0)), label: $R$)
  capacitor("c", "r.out", (rel: (0, -3)), label: $C$)
  wire("c.out", "source.in")
  node("out", "r.out", label: $V_"out"$)
  ground("gnd", (1.5, 0))
})
