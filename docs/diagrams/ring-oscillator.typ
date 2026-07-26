#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 10pt)
#set text(size: 10pt)

#zap.circuit({
  import zap: *

  // A single signal row keeps every inverter pin aligned. The fifth-stage
  // output returns below the row, where it cannot pass through another symbol.
  lnot("i1", (1.0, 2), label: "stage 1")
  lnot("i2", (3.5, 2), label: "stage 2")
  lnot("i3", (6.0, 2), label: "stage 3")
  lnot("i4", (8.5, 2), label: "stage 4")
  lnot("i5", (11.0, 2), label: "stage 5")

  wire("i1.out", "i2.in1")
  wire("i2.out", "i3.in1")
  wire("i3.out", "i4.in1")
  wire("i4.out", "i5.in1")
  wire("i5.out", (12.5, 2), (12.5, 0), (0, 0), (0, 2), "i1.in1")
  node("out", "i5.out", label: $V_"out"$)
})
