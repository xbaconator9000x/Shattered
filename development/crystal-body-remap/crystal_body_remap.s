.syntax unified
.thumb

/* xx1.08 TypeCalc final-damage epilogue hook.
 * Active ability ID 16 is Crystal Body. Suppression clears the active
 * ability byte, so suppression naturally falls through to vanilla damage.
 */
.section .hook, "ax"
.global CrystalBodyHook
.type CrystalBodyHook, %function
CrystalBodyHook:
    bl CrystalBodyTypeCalcEpilogue

.section .crystal_body, "ax"
.global CrystalBodyTypeCalcEpilogue
.type CrystalBodyTypeCalcEpilogue, %function
CrystalBodyTypeCalcEpilogue:
    push {r1-r7, lr}
    mov r6, r9
    movs r1, #0x58
    muls r1, r6
    ldr r2, =0x02023BE4
    adds r2, r2, r1
    adds r2, #0x20
    ldrb r3, [r2]
    cmp r3, #16
    bne 9f
    ldr r2, =0x02023D4A
    ldrh r3, [r2]
    movs r1, #12
    muls r1, r3
    ldr r2, =0x0844B846
    adds r2, r2, r1
    ldrb r3, [r2, #2]
    ldr r2, =0x02023D50
    ldr r1, [r2]
    cmp r1, #0
    ble 9f
    cmp r3, #11
    beq 1f
    cmp r3, #10
    beq 2f
    asrs r1, r1, #1
    cmp r1, #0
    bne 3f
    movs r1, #1
    b 3f
1:  movs r1, #0
    b 3f
2:  lsls r1, r1, #1
3:  str r1, [r2]
9:  ldr r3, [sp, #28]
    add sp, #32
    mov r0, sp
    ldrb r0, [r0]
    bx r3
