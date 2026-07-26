#import "@preview/zap:0.6.0"
#set page(width: auto, height: auto, margin: 10pt)
#set text(size: 10pt)

#zap.circuit({
  import zap: *

  // Each bank is one crossbar row. Repeated V labels denote the same column
  // nets and avoid ambiguous wire crossings in the 2-D physical array.
  for (row, input-y, op-y, index) in (
    (5.0, 7.5, 4.55, 1),
    (0.5, 3.0, 0.05, 2),
  ) {
    for (x, column) in ((1.0, 1), (3.0, 2), (5.0, 3)) {
      nstub((x, input-y), label: $V_#column$)
      resistor(
        "g" + str(index) + str(column),
        (x, input-y),
        (x, row),
        label: $G_#index#column$,
      )
      node("cell" + str(index) + str(column), (x, row))
    }
    wire((1, row), (7.5, row))

    opamp("tia" + str(index), (9, op-y), label: "TIA")
    wire((7.5, row), "tia" + str(index) + ".minus")
    ground("gnd" + str(index), "tia" + str(index) + ".plus")

    // Transimpedance feedback path.
    wire("tia" + str(index) + ".minus", (7.2, row), (7.2, row + 1.25))
    resistor(
      "rf" + str(index),
      (7.2, row + 1.25),
      (10.5, row + 1.25),
      label: $R_"f,"#index$,
    )
    wire((10.5, row + 1.25), (10.5, op-y), "tia" + str(index) + ".out")
    estub("tia" + str(index) + ".out", label: $V_"out,"#index$)
  }
})
