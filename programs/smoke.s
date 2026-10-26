# SCRATCH and EXPECT_SUM are supplied by scripts/build-programs.sh.
.option norvc
.option norelax
.text
.globl _start
_start:
  .2byte 0x0001                 # c.nop; following instructions cross fetch boundaries
  lui s0, (SCRATCH >> 12)
  lui s1, 0x20002              # external mailbox: 0x20002000
  li t0, 0
  li t1, 10
sum_loop:
  add t0, t0, t1
  addi t1, t1, -1
  bne t1, zero, sum_loop
  li t2, EXPECT_SUM
  bne t0, t2, fail
  sw t0, 0(s0)
  lw t1, 0(s0)
  bne t0, t1, fail
  li t1, 3
  mul t2, t0, t1
  li t3, 165
  bne t2, t3, fail
  div t3, t2, t1
  bne t3, t0, fail
  sw t2, 8(s0)
  li t1, -128
  sb t1, 4(s0)
  lb t2, 4(s0)
  bne t1, t2, fail
  lbu t2, 4(s0)
  li t3, 128
  bne t2, t3, fail
  li t1, -1234
  sh t1, 6(s0)
  lh t2, 6(s0)
  bne t1, t2, fail
  lhu t2, 6(s0)
  li t3, 0xfb2e
  bne t2, t3, fail
  li t0, 1
  sw t0, 0(s1)
1: j 1b
fail:
  li t0, 2
  sw t0, 0(s1)
2: j 2b
