# Replace only E203's two known SRAM module bodies; keep all other frontend IR.
# This is a targeted workaround for the pinned frontend, not memory inference.
/^  hw.module private @sirv_sim_ram(_[0-9]+)?\(/ {
  if ($0 ~ /in %din : i64,/ && $0 ~ /in %addr : i13,/) { dw=64; aw=13; depth=8192; mw=8 }
  else if ($0 ~ /in %din : i32,/ && $0 ~ /in %addr : i14,/) { dw=32; aw=14; depth=16384; mw=4 }
  else { print "unexpected SRAM specialization" > "/dev/stderr"; exit 1 }
  if ($0 !~ /in %clk : !seq.clock,/) { print "unexpected SRAM clock type" > "/dev/stderr"; exit 1 }
  count++
  type=sprintf("<%d x i%d, i%d>",depth,dw,aw)
  helper=sprintf("e203_ram_write_%d",dw)
  print
  printf "    %%mem = arc.memory %s {name = \"mem_r\"}\n",type
  print "    %true = hw.constant true"
  print "    %notwe = comb.xor %we, %true : i1"
  print "    %ren = comb.and %cs, %notwe : i1"
  print "    %wen = comb.and %cs, %we : i1"
  printf "    %%addr_next = comb.mux %%ren, %%addr, %%addr_r : i%d\n",aw
  printf "    %%addr_r = seq.compreg %%addr_next, %%clk : i%d\n",aw
  for (i=0;i<mw;i++) {
    printf "    %%bit%d = comb.extract %%wem from %d : (i%d) -> i1\n",i,i,mw
    printf "    %%byte%d = comb.replicate %%bit%d : (i1) -> i8\n",i,i
  }
  printf "    %%mask = comb.concat "
  for (i=mw-1;i>=0;i--) printf "%%byte%d%s",i,(i ? ", " : " : ")
  for (i=0;i<mw;i++) printf "i8%s",(i<mw-1 ? ", " : "\n")
  printf "    arc.memory_write_port %%mem, @%s(%%addr, %%din, %%wen, %%mask) clock %%clk enable mask latency 1 : %s, i%d, i%d, i1, i%d\n",helper,type,aw,dw,dw
  printf "    %%data = arc.memory_read_port %%mem[%%addr_r] : %s\n",type
  printf "    hw.output %%data : i%d\n  }\n",dw
  printf "  arc.define @%s(%%a: i%d, %%d: i%d, %%e: i1, %%m: i%d) -> (i%d, i%d, i1, i%d) {\n",helper,aw,dw,dw,aw,dw,dw
  printf "    arc.output %%a, %%d, %%e, %%m : i%d, i%d, i1, i%d\n  }\n",aw,dw,dw
  skip=1; next
}
skip && /^  }/ { skip=0; next }
!skip { print }
END { if (count != 2) { print "expected exactly two E203 SRAM modules" > "/dev/stderr"; exit 1 } }
