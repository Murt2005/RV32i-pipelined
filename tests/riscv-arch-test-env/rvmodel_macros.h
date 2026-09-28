# rvmodel_macros.h for the RV32IM pipelined core, system configuration
#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

#define STANDARD_SM_SUPPORTED

// tohost in the testbench MMIO block ends the simulation; 1 passes, 3 fails
#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  li t0, 0x0002FFC0       ;\
  sw x1, 0(t0)            ;\
  self_loop_pass:         ;\
    j self_loop_pass      ;\

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  li t0, 0x0002FFC0       ;\
  sw x1, 0(t0)            ;\
  self_loop_fail:         ;\
    j self_loop_fail      ;\

// putchar register
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                           ;                        \
  lbu  _R1, 0(_STR_PTR)      ;                        \
  beqz _R1, 3f               ;                        \
  li   _R2, 0x0002FFF8       ;                        \
  sw   _R1, 0(_R2)           ;                        \
  addi _STR_PTR, _STR_PTR, 1 ;                        \
  j 1b                       ;                        \
3:

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 10000

#endif // _RVMODEL_MACROS_H
