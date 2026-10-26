# Fixed workloads: ITERATIONS=2000 (small) or 20000 (large).
# Checksums use seed 0x12345678 and 32-bit unsigned arithmetic.
.option norvc
.option norelax
.text
.globl _start
_start:
  lui s0, (SCRATCH >> 12)
  lui s1, 0x20002
  li t0, ITERATIONS
  li t1, 0x12345678
loop:
  add t1, t1, t0
  mul t2, t1, t0
  xor t3, t1, t2
  divu t4, t3, t0
  add t1, t1, t4
  add t1, t1, t3
  sw t1, 0(s0)
  lw t5, 0(s0)
  bne t5, t1, fail
  addi t0, t0, -1
  bne t0, zero, loop
.if ITERATIONS == 2000
  li t6, 0x1bbb0ba7
.elseif ITERATIONS == 20000
  li t6, 0x53ce762a
.else
  .error "use ITERATIONS=2000 or 20000"
.endif
  bne t1, t6, fail
  # Shared 12-byte signature, independently checked by each testbench.
  li t2, 0x37
  sw t2, 0(s0)
  li t2, 0x80
  sb t2, 4(s0)
  li t2, 0xfb2e
  sh t2, 6(s0)
  li t2, 0xa5
  sw t2, 8(s0)
  li t2, 1
  sw t2, 0(s1)
1: j 1b
fail:
  li t2, 2
  sw t2, 0(s1)
2: j 2b
