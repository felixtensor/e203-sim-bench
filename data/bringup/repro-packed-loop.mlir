module {
  hw.module private @pack(in %a : i1, in %b : i1, out pair : i2) {
    %0 = comb.concat %a, %b : i1, i1
    hw.output %0 : i2
  }
  hw.module private @high_bit(in %pair : i2, out y : i1) {
    %0 = comb.extract %pair from 1 : (i2) -> i1
    hw.output %0 : i1
  }
  hw.module @packed_loop(in %a : i1, out y : i1) {
    %p.pair = hw.instance "p" @pack(a: %a: i1, b: %h.y: i1) -> (pair: i2) {sv.namehint = "pair"}
    %h.y = hw.instance "h" @high_bit(pair: %p.pair: i2) -> (y: i1)
    hw.output %h.y : i1
  }
}
