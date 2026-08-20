# 4BoD

4BoD (4 Bits of DOOM) is a hyper-minimalist fantasy console 
inspired by Milton Bradley Microvision. It was created as an 
entry for FC Dev jam by puarsliburf games in 2017. Now there 
are lots of reimplementations, programming languages, and games. 

## Capabilities

- Program memory: 3072b (256 12-bit instructions).
- RAM: 16 nibbles (64b).
- Screen: 16x16 (1:1) 1-bit.
- Instruction set: 16 instructions.
- Sounds: no. 

## Instruction Set
```sh
   OP  |A   |B   |Description
   0000           - NOP
   0001 AAAA      - Sets the accumulator to the value stored at memory position AAAA
   0010 AAAA      - Sets memory position AAAA to the value stored in the accumulator
   0011 AAAA      - Sets the accumulator to AAAA
   0100           - Sets the accumulator to the buttons that have been pressed
   	             - Ones place = left button
   	             - Twos place = right button
   	             - Fours place = up button
   	             - Eights place = down button
   0101           - Increments the accumulator (Do this 15 times to make a subtraction by overflow)
   0110           - Clears the screen
   0111           - Shifts the accumulator left
   1000           - Shifts the accumulator right
   1001 AAAA BBBB - Sets the accumulator to pixel position memory AAAA, memory BBBB
   1010 AAAA BBBB - Flips pixel position memory AAAA, memory BBBB
   1011 AAAA      - Sets a flag called AAAA (Flag 15 is forever 0, bug)
   1100 AAAA      - Jumps to flag memory position AAAA
   1101 AAAA      - Only perform next action if memory position AAAA is equal to the accumulator
   1110 AAAA      - Only perform next action if memory position AAAA is greater than the accumulator
   1111 AAAA      - Only perform next action if memory position AAAA is less than the accumulator
```
