# AlphaOneSoC
- A general purpose RV32I-based System-on-Chip, by alfadelta10010 & devesh-b
- Includes UART TX-RX, SPI controller with memory, and Digital GPIOs, capable of PWM(?)
## Aim
- Build a general-purpose RV32I processor, to which we can upload our instructions and see them execute
- Run !mmu Linux? `@_@`

## Status Table

| Components               | RTL                     | Pre-synthesis Simulation      | Post-synthesis Simulation       | Post-hardening Integration | Timing Analysis | GDS File |
| :----------------------- |:----------------------- | :---------------------------- | :------------------------------ | :------------------------- | :-------------- | :------- |
| **Processor**            | [Yes](src/fyracore.v)   | [No](pre_sim/fyracore.vcd)    | [No](post_sim/fyracore.vcd)     |                            |                 |          |
| Program Counter          | [Yes](src/regs.v)       | [No](pre_sim/regs.vcd)        | [No](post_sim/regs.vcd)         |                            |                 | **-**    |
| Adder                    | [Yes](src/adder.v)      | [Yes](pre_sim/adder.vcd)      | [Yes](post_sim/adder.vcd)       |                            |                 | **-**    |
| Decoder                  | [Yes](src/decoder.v)    | [Yes](pre_sim/decoder.vcd)    | [Yes](post_sim/decoder.vcd)     |                            |                 | **-**    |
| Register File            | [Yes](src/regFile.v)    | [Yes](pre_sim/regFile.vcd)    | [Yes](post_sim/regFile.vcd)     |                            |                 | **-**    |
| Sign Extension           | [Yes](src/signExt.)     | [No](pre_sim/signExt.vcd)     | [No](post_sim/signExt.vcd)      |                            |                 | **-**    |
| Control Unit             | [Yes](src/controller.v) | [Yes](pre_sim/controller.vcd) | [Yes](post_sim/controller.vcd)  |                            |                 | **-**    |
| 2:1 MUX                  | [Yes](src/mux21.v)      | [Yes](pre_sim/mux21.vcd)      | [Yes](post_sim/mux21.vcd)       |                            |                 | **-**    |
| ALU                      | [Yes](alu.v)            | [Yes](pre_sim/alu.vcd)        | [Yes](post_sim/alu.vcd)         |                            |                 | **-**    |
| Branch Controller        | [Yes](src/branchCtrl.v) | [Yes](pre_sim/branchCtrl.vcd) | [Yes*](post_sim/branchCtrl.vcd) |                            |                 | **-**    |
| AND gate                 | [Yes](src/and2.v)       | [Yes](pre_sim/and2.vcd)       | [Yes](post_sim/and2.vcd)        |                            |                 | **-**    |
| OR gate                  | [Yes](src/or2.v)        | [Yes](pre_sim/or2.vcd)        | [Yes](post_sim/or2.vcd)         |                            |                 | **-**    |
| 3:1 MUX                  | [Yes](src/mux31.v)      | [Yes](pre_sim/mux31.vcd)      | [Yes](post_sim/mux31.vcd)       |                            |                 | **-**    |
| Memory Controller        | [No](src/memctrl.v)     | [No](pre_sim/memctrl.vcd)     | [No](post_sim/memctrl.vcd)      |                            |                 | **-**    |
| CSR and Status Registers | [No](src/csr.v)         |                               |                                 |                            |                 | **-**    |
| M-type Instruction?      | [No]()                  |                               |                                 |                            |                 | **-**    |
| A-type Instruction?      | [No]()                  |                               |                                 |                            |                 | **-**    |
| **Peripharels**          | **-**                   | **-**                         | **-**                           | **-**                      | **-**           | **-**    |
| *UART controller*        |                         |                               |                                 |                            |                 |          |
| *SPI Memory*             |                         |                               |                                 |                            |                 |          |
| *Simulated Memory*       |                         |                               |                                 |                            |                 |          |
| *GPIO block*             |                         |                               |                                 |                            |                 |          |
| *CLINT*                  |                         |                               |                                 |                            |                 |          |


