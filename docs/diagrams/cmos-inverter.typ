#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 8pt)

#zap.circuit({
  import zap: *
  pmos("p", (3, 3), label: $M_P$)
  nmos("n", (3, 0), label: $M_N$)
  wire("p.s", (3, 4.5))
  vcc("vdd", (3, 4.5), label: $V_"DD"$)
  wire("p.d", (to: "p.d", rel: (1, 0)), (4, 1.5))
  wire("n.d", (to: "n.d", rel: (1, 0)), (4, 1.5))
  wire((4, 1.5), (5, 1.5))
  wire("p.g", (1, 2.5), (1, -0.5), "n.g")
  wstub((1, 1.5), label: $V_"in"$)
  capacitor("load", (5, 1.5), (5, -1), label: $C_L$)
  wire("n.s", (3, -1), (5, -1))
  ground("gnd", (4, -1))
  node("out", (5, 1.5), label: $V_"out"$)
})
