module {
  hw.module @masked_ram(in %clk : !seq.clock, in %wen : i2, in %addr : i2, in %din : i16, out dout : i16) {
    %0 = llhd.constant_time <0ns, 0d, 1e>
    %c-1_i2 = hw.constant -1 : i2
    %mem = llhd.sig : <!hw.array<4xi16>>
    %1 = comb.extract %wen from 0 : (i2) -> i1
    %2 = comb.sub %c-1_i2, %addr : i2
    %3 = comb.extract %din from 0 : (i16) -> i8
    %4 = hw.array_get %15[%2] : !hw.array<4xi16>, i2
    %5 = comb.extract %4 from 8 : (i16) -> i8
    %6 = comb.concat %5, %3 : i8, i8
    %7 = hw.array_inject %15[%2], %6 : !hw.array<4xi16>, i2
    %8 = comb.mux bin %1, %7, %mem_0 : !hw.array<4xi16>
    %mem_0 = seq.firreg %8 clock %clk {name = "mem"} : !hw.array<4xi16>
    llhd.drv %mem, %mem_0 after %0 : !hw.array<4xi16>
    %9 = comb.extract %wen from 1 : (i2) -> i1
    %10 = comb.extract %din from 8 : (i16) -> i8
    %11 = comb.extract %4 from 0 : (i16) -> i8
    %12 = comb.concat %10, %11 : i8, i8
    %13 = hw.array_inject %15[%2], %12 : !hw.array<4xi16>, i2
    %14 = comb.mux bin %9, %13, %mem_1 : !hw.array<4xi16>
    %mem_1 = seq.firreg %14 clock %clk {name = "mem"} : !hw.array<4xi16>
    llhd.drv %mem, %mem_1 after %0 : !hw.array<4xi16>
    %15 = llhd.prb %mem : !hw.array<4xi16>
    hw.output %4 : i16
  }
}
