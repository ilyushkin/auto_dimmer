; Copyright Alexey S. Ilyushkin 2022

; Start coreinit.inc
ram_flush:
    ldi ZL, low(SRAM_START)     ; Start of RAM address into the index register
    ldi ZH, high(SRAM_START)
    clr r16                     ; Clear r16
flush:
    st Z+, r16                  ; Store 0 into the memory cell
    cpi ZH, high(RAMEND)        ; Reached the end of RAM?
    brne flush                  ; If not, continue the cycle

    cpi ZL, Low(RAMEND)         ; Did the low byte reach the end?
    brne flush

    clr ZL                      ; Clear the index register
    clr ZH
    clr r0
    clr r1
    clr r2
    clr r3
    clr r4
    clr r5
    clr r6
    clr r7
    clr r8
    clr r9
    clr r10
    clr r11
    clr r12
    clr r13
    clr r14
    clr r15
    clr r16
    clr r17
    clr r18
    clr r19
    clr r20
    clr r21
    clr r22
    clr r23
    clr r24
    clr r25
    clr r26
    clr r27
    clr r28
    clr r29
; End coreinit.inc