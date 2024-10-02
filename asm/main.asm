; Copyright Alexey S. Ilyushkin 2022

.include "tn13Adef.inc"

; Freq 9.6 MHz with prescaler 8 gives 1.2 Mhz

.dseg                               ; RAM segment

.cseg                               ; Code segment (flash) 
.equ POWEROFF_DELAY_SECONDS = 1200  ; Soft auto-dimming delay in seconds

.equ TRIAC_DELAY_BTM = 10           ; Minimum delay before sending a pulse to the TRIAC (maximum brightness)
.equ TRIAC_DELAY_TOP = 199          ; Maximum delay before sending a pulse to the TRIAC (minimum brightness)
.equ TRIAC_DELAY_DIMOUT_TOP = 209   ; Maximum delay for auto power off (for greater smoothness)

.equ BTN_DELAY = 200                ; Number of PCI0 interrupts triggered to detect long button press

.equ LAMP_STATUS_BIT = 0            ; The bit number encoding the lamp status in the status_register: off (0), on (1)
.equ SHORT_PRESS_BIT = 1            ; The bit number encoding detection of short button press
.equ LONG_PRESS_BIT = 2             ; Bit number encoding long button press detection
.equ POWEROFF_BIT = 3               ; Bit number encoding the auto-dimming activity
.equ RECOMPUTE_DELAY = 4            ; The bit number indicating that the delay value needs to be recalculated

; ========== Register aliases
.def poff_counter0 = r14
.def poff_counter1 = r15

.def tmpa = r16
.def tmpb = r17
.def tmpc = r18

.def pulse_delay_counter = r19      ; Delay counter for applying a signal to the gate of a TRIAC
.def triac_delay = r20              ; Current value of required pulse delay normalized from TRIAC_DELAY_BTM to TRIAC_DELAY_TOP
.def tensms_counter = r21           ; The zero crossing counter, as soon as it reaches 100 (since zero is crossed every 10 ms, i.e. with a frequency of 100 Hz), then a second has passed
.def button_counter = r22           ; Button press time counter
.def status_register = r23          ; Status register, bit 0 is responsible for the on/off state of the lamp
.def seconds_per_division0 = r24    ; Number of seconds per dimmer step for auto-dimming
.def seconds_per_division1 = r25    ; Number of seconds per dimmer step for auto-dimming

; ========== Port B pins
.equ Z_CROSS = 0
.equ BUTTON = 1
.equ TRIAC = 2
.equ LED = 3
.equ POT = 4



; ========== Interrupt Vector Table
.org 0
    rjmp RESET
.org INT0addr
    rjmp INT0_handler 
.org PCI0addr
    rjmp PCI0_handler
.org OVF0addr
    reti
.org ERDYaddr
    reti
.org ACIaddr
    reti
.org OC0Aaddr
    rjmp OC0A_handler
.org OC0Baddr
    reti
.org WDTaddr
    reti
.org ADCCaddr
    rjmp ADCC_handler


; ========== Button interrupt handler
INT0_handler:
    push tmpa

    ; We detect not just a button press, but two types of pressing: long and short
    ; After detecting a falling edge, disable all interrupts on INT0 for a minimum of 1 and a maximum of 2 periods of the 100 Hz grid zero crossing handler (10-20 ms)
    ; If INT0 is configured to trigger on a falling edge, then it detects when the button is pressed (i.e., not released)
    ; After pressing is detected the algorithm start counting and if after two seconds no rising edge was detected, then start the auto-dimming countdown
    ; If the rising edge was detected in less than 2 seconds, then invert the lamp state
    
    in tmpa, MCUCR
    sbrs tmpa, ISC00                        ; Skip the next instruction if INT0 is set to trigger on rising edge
    rjmp int0_detect_falling
    ; Processing the rising edge of the signal


    ; If the button_counter press time counter has counted more than two seconds, then start the smooth dimout countdown
    ; If the button_counter press time counter has counted less than two seconds, then invert the lamp state

    cpi button_counter, BTN_DELAY
    brlo short_press_detected
    ; Handling the long press

    sbr status_register, 1<<LONG_PRESS_BIT
    rjmp configure_falling_edge

short_press_detected:
    sbr status_register, 1<<SHORT_PRESS_BIT

configure_falling_edge:
    ldi tmpa, 1<<ISC01                      ; Set INT0 to trigger on falling edge
    out MCUCR, tmpa

    rjmp int0_continue

int0_detect_falling:     
    ; Handling falling edge   
    
    ldi tmpa, 1<<ISC01 | 1<<ISC00           ; Set INT0 to trigger on rising edge
    out MCUCR, tmpa           

int0_continue:
    in tmpa, GIMSK
    cbr tmpa, 1<<INT0                       ; Disable interrupt on INT0 to avoid triggering due to button bounce
    out GIMSK, tmpa                         ; (the interrupt will be turned back on after 20-30ms in the zero crossing interrupt handler)

    clr button_counter                      ; Clearing the button press time counter 

    pop tmpa
reti


; ========== Zero Crossing Interrupt Handler (100Hz)
PCI0_handler:
    push tmpa
    push tmpb

    cpi button_counter, 255                 ; If we have counted to 255, then do not increase the value further
    breq handle_poweroff_delay

    inc button_counter
    cpi button_counter, 3                   ; If we have counted to 3, then turn interrupts back on by pressing the button
    brne handle_poweroff_delay              ; Otherwise -- continue performing other checks further
    
    in tmpa, GIMSK
    sbr tmpa, 1<<INT0                       ; Enable interrupt on INT0
    out GIMSK, tmpa                               
    ldi tmpa, 1<<INTF0                      ; Clear the INT0 interrupt flag to skip any triggers that occurred in the last 20-30ms while INT0 was off
    out GIFR, tmpa
      
handle_poweroff_delay:
    sbrs status_register, POWEROFF_BIT      ; If POWEROFF_BIT == 1, then perform a countdown
    rjmp reset_timer0                       ; If POWEROFF_BIT == 0, then go to the label

    inc tensms_counter                      ; Increase the tens of microseconds counter
    cpi tensms_counter, 99                  ; If we have counted to 99, then increase the value of the pair poff_counter1:poff_counter0 by one
    brne reset_timer0                       ; otherwise -- continue  

    clr tensms_counter                      ; Reset tensms_counter
    ;inc seconds_counter                    ; Increment the counter of seconds elapsed since the previous brightness decrease (processed and reset in the main loop)

    ldi tmpa, 1                             ; Subtract one from the register pair poff_counter1:poff_counter0
    sub poff_counter0, tmpa
    clr tmpa
    sbc poff_counter1, tmpa

reset_timer0:
    sbrs status_register, LAMP_STATUS_BIT   ; If the LAMP_STATUS_BIT bit is set, then reset and enable Timer 0
    rjmp pci0_continue                      ; Otherwise, just exit the interrupt.

    clr tmpa
    out TCNT0, tmpa                         ; Reset the Timer 0 counter (this is essentially necessary to synchronize the timer with the grid)
    ;ldi tmpb, 1<<PSR10
    ;out GTCCR, tmpb                        ; Resetting the prescaler of Timer 0: since the prescaler is 1, then in the current implementation a reset is not needed

    ldi tmpa, 1<<OCIE0A
    out TIMSK0, tmpa                        ; Enable interrupt on Timer 0

    clr pulse_delay_counter                 ; Resetting the delay counter

pci0_continue:
    pop tmpb
    pop tmpa
reti


; ========== Timer 0 counter match interrupt handler with OCR0A register value
OC0A_handler:
    push tmpa

    ; If the TRIAC pin of PORTB is in the logic one state, then set it back to zero and disable the timer interrupts
    sbic PORTB, TRIAC                       ; skip the next instruction if TRIAC bit in PORTB register == 0
    rjmp stop_timer

    cp pulse_delay_counter, triac_delay     ; Comparing the counting register with triac_delay
    brlo continue_counting2                 ; If the delay counter has not yet counted up to triac_delay, then exit the interrupt and continue counting

    ; As soon as the counter register has counted to the required value, we send a control pulse to the TRIAC.
    sbi PORTB, TRIAC                        ; We set a logical one on the TRIAC output (thereby turning on the TRIAC, since the additional transistor inverts the MC output, pulling down the TRIAC gate to the ground, thereby opening it)
    rjmp continue_counting2

stop_timer:
    cbi PORTB, TRIAC                        ; Restore logical zero at the TRIAC output
    in tmpa, TIMSK0                         ; Read the contents of the TIMSK0 register
    cbr tmpa, 1<<OCIE0A                     ; Reset the OCIE0A bit responsible for the activity of the interrupt on the match of the Timer 0 value
    out TIMSK0, tmpa                        ; Disabling interrupts on Timer 0

continue_counting2:
    inc pulse_delay_counter                 ; Increase the value of the counter register by 1
    pop tmpa
reti


; ========== ADC Conversion End Interrupt Handler
ADCC_handler:
    sbr status_register, 1<<RECOMPUTE_DELAY     
reti


; ========== Initialization
RESET:
    ldi tmpa, low(RAMEND)                   ; Loading the stack pointer
    out SPL, tmpa                           ; Initialize the stack pointer to the end of SRAM

    .include "coreinit.asm"

    ; ========== Port B
    ldi tmpa, 1<<TRIAC | 1<<LED             ; Set the TRIAC and LED pins of port B to the pin
    out DDRB, tmpa
    
    ldi tmpa, 1<<BUTTON                     ; Turn on the pull-up for the BUTTON output
    out PORTB, tmpa

    ; ========== INT0 и PCINT0
    ldi tmpa, 1<<ISC01                      ; By default, it is triggered on the rising edge
    out MCUCR, tmpa
    
    ldi tmpa, 1<<PCINT0                     ; PCI0 interrupt on change of state of PCINT0 pin (#5 Z_CROSS)
    out PCMSK, tmpa

    ldi tmpa, 1<<INT0 | 1<<PCIE             ; Enable INT0 and PCIE
    out GIMSK, tmpa

    ; ==========  Timer0
    ldi tmpa, 48                            ; Load 48 into the Timer 0 comparison register, so the timer will operate at the frequency of 25 kHz and, accordingly, overflow 250 times per half-period of the sine wave
    out OCR0A, tmpa                         ; Accordingly, the delay between timer ticks will be 40 us

    ldi tmpa, 1<<CS00                       ; Set the prescaler for Timer 0 to 1, so it will count at a frequency of 1.2 MHz.
    out TCCR0B, tmpa

    ldi tmpa, 1<<WGM01                      ; Set Timer 0 to mode #2 (Clear Timer on Compare Match -- CTC)
    out TCCR0A, tmpa

    clr tmpa                                ; Resetting the timer counter
    out TCNT0, tmpa

    ; ========== ADC

    ldi tmpa, 1<<MUX1 | 1<<ADLAR            ; Select ADC2 as the ADC input (pin #3), ADLAR: ADC Left Adjust Result
    out ADMUX, tmpa

    ldi tmpa, 1<<ADEN | 1<<ADATE | 1<<ADIE  ; ADEN: ADC Enable, ADATE: ADC Auto Trigger Enable, ADIE: ADC Interrupt Enable
    out ADCSRA, tmpa

    ldi tmpa, 1<<ADTS2 | 1<<ADTS1           ; ADC Auto Trigger Source: Pin Change Interrupt Request
    out ADCSRB, tmpa

    ; ========== Initial pins states
    cbi PORTB, TRIAC                        ; Set a logical zero on the TRIAC output, thereby disabling it when the MCU starts up

    sei                                     ; Enable interrupts


; ========== Main loop
MAIN:
    sbrs status_register, LAMP_STATUS_BIT       ; Processing the state of the LAMP_STATUS_BIT bit
    rjmp lamp_off
    sbi PORTB, LED                              ; Turn on the LED if the LAMP_STATUS_BIT bit == 1
    rjmp process_long_press

lamp_off:
    cbi PORTB, LED                              ; Turn off the LED if the LAMP_STATUS_BIT == 0

process_long_press:
    sbrs status_register, LONG_PRESS_BIT
    rjmp process_short_press
    ; Handling the long press detection
    cbr status_register, 1<<LONG_PRESS_BIT      ; Reset bit LONG_PRESS_BIT

    ; if the lamp is already off, then process the long press in the same way as the short press -- invert the lamp state
    sbrs status_register, LAMP_STATUS_BIT
    rjmp short_press

    cli                                         ; Disable interrupts while calculating the value seconds_per_division1:seconds_per_division0
    ; otherwise - start the countdown

    sbr status_register, 1<<POWEROFF_BIT        ; Set the POWEROFF_BIT bit in the status register

    clr tensms_counter
    cbi ADCSRA, ADEN                            ; Disabling ADC!

    ; Calculate the dimming interval by dividing POWEROFF_DELAY_SECONDS by the current potentiometer value (only performed once, when a long press is detected)
    ; The result is stored in a seconds_per_division pair, and this value is used to determine the time interval to subtract one from the current value of triac_delay
    clr seconds_per_division0                   ; Reset the register of the number of seconds per division of the brightness reduction level during auto-dimming
    clr seconds_per_division1                   ; -//-
    
    ldi tmpa, TRIAC_DELAY_DIMOUT_TOP + 1
    sub tmpa, triac_delay                       ; Subtract from TRIAC_DELAY_DIMOUT_TOP + 1, the current value of triac_delay,
                                                ; since we are interested in 200 effective number of dimming gradations used: 10..209 inclusive
    mov tmpc, tmpa
    ldi tmpa, LOW(POWEROFF_DELAY_SECONDS)
    ldi tmpb, HIGH(POWEROFF_DELAY_SECONDS)
subtraction_loop:
    adiw seconds_per_division1:seconds_per_division0, 1  ; Increase the value of the register pair seconds_per_division1:seconds_per_division0 by 1
    sub tmpa, tmpc                              ; Subtract tmpc from tmpa
    sbci tmpb, 0                                ; Subtract the carry flag from the previous subtraction
    brcc subtraction_loop                       ; If the carry flag is cleared, continue the loop
    sbiw seconds_per_division1:seconds_per_division0, 1  ; Subtract the extra one, because we need to round the integer division down
    mov poff_counter0, seconds_per_division0    ; Load the new calculated values ​​into the counter of seconds elapsed since the previous dimming
    mov poff_counter1, seconds_per_division1
    sei                                         ; Turn interrupts back on
    rjmp calc_triac_delay

process_short_press:
    sbrs status_register, SHORT_PRESS_BIT
    rjmp calc_triac_delay
    ; Handling short press detection
    cbr status_register, 1<<SHORT_PRESS_BIT     ; Resetting bit SHORT_PRESS_BIT
short_press:
    sbi ADCSRA, ADEN                            ; Enabling ADC!
    ldi tmpa, 1<<LAMP_STATUS_BIT
    eor status_register, tmpa                   ; Invert the state of the LAMP_STATUS_BIT bit in the status_register register
    cbr status_register, 1<<POWEROFF_BIT        ; Reset POWEROFF_BIT

calc_triac_delay:
    sbrs status_register, POWEROFF_BIT          ; If POWEROFF_BIT == 1, then recalculate the value of the delay for supplying a pulse to the TRIAC
    rjmp read_pot_value                         ; If POWEROFF_BIT == 0, then go to the label
    
    ; Check if the pair poff_counter1:poff_counter0 has counted to zero
    cli
    tst poff_counter0
    brne enable_interrupts
    tst poff_counter1
    brne enable_interrupts
    ; If both registers poff_counter0 and poff_counter1 == 0, then decrease the value of triac_delay by one and load into poff_counter0<--seconds_per_division0 and into poff_counter1<--seconds_per_division1
    mov poff_counter0, seconds_per_division0
    mov poff_counter1, seconds_per_division1

    inc triac_delay                                       ; We increase the value of the delay of the pulse supply to the triac by 1
    cpi triac_delay, TRIAC_DELAY_DIMOUT_TOP + 1           ; Compare whether the potentiometer value has increased above TRIAC_DELAY_DIMOUT_TOP + 1 (because the TRIAC_DELAY_DIMOUT_TOP value is used inclusively and is valid)
    brne enable_interrupts                                ; if triac_delay == TRIAC_DELAY_DIMOUT_TOP + 2, then reset lamp active and countdown flags
    ; If yes, reset lamp active and countdown flags
    ldi triac_delay, TRIAC_DELAY_TOP                      ; Write TRIAC_DELAY_TOP to triac_delay (not TRIAC_DELAY_DIMOUT_TOP, which means too low brightness). This value will still, in principle, be overwritten by the new value from the ADC the next time the lamp is turned on
    cbr status_register, 1<<LAMP_STATUS_BIT | 1<<POWEROFF_BIT     ; Resettings bits LAMP_STATUS_BIT and POWEROFF_BIT
enable_interrupts:
    sei

read_pot_value:
    ; Calculating the delay value based on the new value from the potentiometer
    sbrs status_register, RECOMPUTE_DELAY
    rjmp MAIN
    cbr status_register, 1<<RECOMPUTE_DELAY
    in tmpa, ADCH                                                 ; Reading the DAC value in tmpa
    lsr tmpa                                                      ; Shift twice to the right by one position, thereby dividing the ADC value by 4
    lsr tmpa                                                      ; And from the range of values ​​0..255 we get 0..63
    clr tmpb                                                      ; Clear triac_delay before multiplying tmpa by 3, the result will be written to triac_delay
    ; Multiply tmpa by 3 in the loop and write the result to triac_delay 
multiplication_loop:
    tst tmpa                                                      ; Check if tmpa is zero
    breq exit_multiplication_loop                                 ; If tmpa == 0, then exit
    subi tmpb, -3                                                 ; Otherwise, add 3 to triac_delay
    dec tmpa                                                      ; Decrement tmpa by 1
    rjmp multiplication_loop
exit_multiplication_loop:
    ; Add TRIAC_DELAY_BTM to the resulting value
    subi tmpb, -TRIAC_DELAY_BTM                                   ; To shift the raw value from the potentiometer by 10 units, adding 10 to it
    mov triac_delay, tmpb

rjmp MAIN
