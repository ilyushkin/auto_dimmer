; Copyright Alexey S. Ilyushkin 2022

.include "tn13Adef.inc"

; Freq 9.6 MHz with prescaler 8 gives 1.2 Mhz

.dseg                               ; RAM segment

.cseg                               ; Code segment (flash) 
.equ POWEROFF_DELAY_SECONDS = 900   ; Soft auto-dimming delay in seconds; 300..1800 is a typical range

.equ TRIAC_DELAY_BTM = 10           ; Minimum delay before sending a pulse to the TRIAC (maximum brightness)
.equ TRIAC_DELAY_TOP = 199          ; Maximum delay before sending a pulse to the TRIAC (minimum brightness)
.equ TRIAC_DELAY_DIMOUT_TOP = 209   ; Maximum delay before auto power off
.equ TRIAC_LUT_POT_SIZE = 128       ; ADC range after ADCH>>1: indices 0..127
.equ TRIAC_LUT_SIZE = 148           ; Full LUT: 128 pot entries + 20 dimout-only entries

.if TRIAC_LUT_SIZE > 255
    .error "TRIAC_LUT_SIZE must fit in an 8-bit index"
.endif
.if POWEROFF_DELAY_SECONDS < TRIAC_LUT_SIZE
    .error "POWEROFF_DELAY_SECONDS must be at least TRIAC_LUT_SIZE so every LUT level lasts at least one second"
.endif
.if POWEROFF_DELAY_SECONDS > 65535
    .error "POWEROFF_DELAY_SECONDS must fit in 16 bits"
.endif

.equ BTN_DELAY = 100                ; Number of PCI0 interrupts triggered to detect long button press

.equ LAMP_STATUS_BIT = 0            ; The bit number encoding the lamp status in the status_register: off (0), on (1)
.equ SHORT_PRESS_BIT = 1            ; The bit number encoding detection of short button press
.equ LONG_PRESS_BIT = 2             ; Bit number encoding long button press detection
.equ POWEROFF_BIT = 3               ; Bit number encoding the auto-dimming activity
.equ RECOMPUTE_DELAY = 4            ; The bit number indicating that the delay value needs to be recalculated

; ========== Register aliases
.def dimout_steps = r10             ; Number of timed LUT levels remaining
.def dimout_remainder = r11         ; POWEROFF_DELAY_SECONDS mod dimout_steps
.def dimout_error = r12             ; Error accumulator for distributing remainder seconds
.def dimout_lut_idx = r13           ; Current LUT index: pot reading uses 0..127, dimout uses 0..147
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
.def seconds_per_division0 = r24    ; Number of seconds per dimmer step for auto-dimming, must stay on r24 (W-pair low)
.def seconds_per_division1 = r25    ; Number of seconds per dimmer step for auto-dimming, must stay on r25 (W-pair high)

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
    in tmpa, SREG                           ; Save SREG
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
    out SREG, tmpa                          ; Restore SREG
    pop tmpa
reti


; ========== Zero Crossing Interrupt Handler (100Hz)
PCI0_handler:
    push tmpa
    in tmpa, SREG                           ; Save SREG
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
    cpi tensms_counter, 100                 ; If we have counted to 100, then increase the value of the pair poff_counter1:poff_counter0 by one
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
    out SREG, tmpa                          ; Restore SREG
    pop tmpa
reti


; ========== Timer 0 counter match interrupt handler with OCR0A register value
OC0A_handler:
    push tmpa
    in tmpa, SREG                           ; Save SREG
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
    out SREG, tmpa                          ; Restore SREG
    pop tmpa
reti


; ========== ADC Conversion End Interrupt Handler
ADCC_handler:
    ; No SREG save: SBR preserves C, so it cannot break the ADD/ADC LUT-address sequence
    ; All other SREG-dependent main-code sequences execute with interrupts disabled
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

    ; ========== INT0 and PCINT0
    ldi tmpa, 1<<ISC01                      ; By default, it is triggered on the falling edge (ISC01=1, ISC00=0)
    out MCUCR, tmpa
    
    ldi tmpa, 1<<PCINT0                     ; PCI0 interrupt on change of state of PCINT0 pin (#5 Z_CROSS)
    out PCMSK, tmpa

    ldi tmpa, 1<<INT0 | 1<<PCIE             ; Enable INT0 and PCIE
    out GIMSK, tmpa

    ; ==========  Timer0
    ldi tmpa, 47                            ; Load 47 into the Timer 0 comparison register: f = 1200000/(47+1) = 25000 Hz exactly, overflow 250 times per half-period of the sine wave
    out OCR0A, tmpa                         ; Accordingly, the delay between timer ticks will be 40 us exactly

    ldi tmpa, 1<<CS00                       ; Set the prescaler for Timer 0 to 1, so it will count at a frequency of 1.2 MHz.
    out TCCR0B, tmpa

    ldi tmpa, 1<<WGM01                      ; Set Timer 0 to mode #2 (Clear Timer on Compare Match -- CTC)
    out TCCR0A, tmpa

    clr tmpa                                ; Resetting the timer counter
    out TCNT0, tmpa

    ; ========== ADC

    ldi tmpa, 1<<MUX1 | 1<<ADLAR            ; Select ADC2 as the ADC input (pin #3), ADLAR: ADC Left Adjust Result
    out ADMUX, tmpa

    ldi tmpa, 1<<ADEN | 1<<ADATE | 1<<ADIE | 1<<ADPS1 | 1<<ADPS0  ; ADEN: ADC Enable, ADATE: ADC Auto Trigger Enable, ADIE: ADC Interrupt Enable, ADPS1|ADPS0: prescaler=8 --> 1200000/8=150 kHz (within 50-200 kHz spec)
    out ADCSRA, tmpa

    ldi tmpa, 1<<ADTS2 | 1<<ADTS1           ; ADC Auto Trigger Source: Pin Change Interrupt Request
    out ADCSRB, tmpa

    ; ========== Watchdog
    ldi tmpa, 1<<WDCE | 1<<WDE              ; Step 1: enable timed change sequence (WDCE+WDE must be set together)
    out WDTCR, tmpa
    ldi tmpa, 1<<WDE | 1<<WDP2 | 1<<WDP1    ; Step 2 (within 4 cycles): set WDE + prescaler=8 --> approx. 1 s timeout (WDP2:WDP1:WDP0 = 110)
    out WDTCR, tmpa

    ; ========== Initial pins states
    cbi PORTB, TRIAC                        ; Set a logical zero on the TRIAC output, thereby disabling it when the MCU starts up

    sei                                     ; Enable interrupts


; ========== Main loop
MAIN:
    wdr                                         ; Reset watchdog timer
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

    ; Calculate the interval length for the LUT levels remaining from the current pot position.
    ; The quotient q is stored in seconds_per_division1:seconds_per_division0.
    ; The remainder is distributed across the fade so that exactly
    ; POWEROFF_DELAY_SECONDS elapse without one long first interval.
    clr seconds_per_division0
    clr seconds_per_division1

    ldi tmpa, TRIAC_LUT_SIZE
    sub tmpa, dimout_lut_idx                    ; Remaining timed levels, including the current one: 148-index
    mov dimout_steps, tmpa                      ; Pot indices are 0..127, therefore range is 21..148
    mov tmpc, tmpa                              ; Divisor for the subtraction-based division

    ldi tmpa, low(POWEROFF_DELAY_SECONDS)
    ldi tmpb, high(POWEROFF_DELAY_SECONDS)
subtraction_loop:
    adiw seconds_per_division1:seconds_per_division0, 1
    sub tmpa, tmpc
    sbci tmpb, 0
    brcc subtraction_loop
    sbiw seconds_per_division1:seconds_per_division0, 1  ; q = floor(POWEROFF_DELAY_SECONDS/dimout_steps)

    add tmpa, tmpc                              ; Recover r = POWEROFF_DELAY_SECONDS mod dimout_steps
    mov dimout_remainder, tmpa
    clr dimout_error

    rcall load_dimout_interval                  ; Load duration of the current LUT level
    sei
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
    sbrs status_register, POWEROFF_BIT
    rjmp read_pot_value

    ; Check whether the current LUT-level interval has elapsed
    cli
    tst poff_counter0
    brne enable_interrupts
    tst poff_counter1
    brne enable_interrupts

    inc dimout_lut_idx                          ; Advance to the next perceptual dimout level
    ldi tmpa, TRIAC_LUT_SIZE
    cp dimout_lut_idx, tmpa
    breq dimout_complete                        ; Index 148 is the end marker and is never read

    ldi ZL, low(triac_lut * 2)
    ldi ZH, high(triac_lut * 2)
    add ZL, dimout_lut_idx
    adc ZH, r0                                  ; r0 is permanently zero
    lpm triac_delay, Z

    rcall load_dimout_interval                  ; Load q or q+1 seconds for this LUT level
    rjmp enable_interrupts
dimout_complete:
    ldi triac_delay, TRIAC_DELAY_TOP            ; Restore normal minimum, ADC overwrites it after lamp-on
    cbr status_register, 1<<LAMP_STATUS_BIT | 1<<POWEROFF_BIT
enable_interrupts:
    sei

read_pot_value:
    ; Convert ADCH to a 7-bit LUT index and read the gamma-corrected TRIAC delay
    sbrs status_register, RECOMPUTE_DELAY
    rjmp MAIN
    cbr status_register, 1<<RECOMPUTE_DELAY
    in tmpa, ADCH                               ; 0..255
    lsr tmpa                                    ; 0..127
    mov dimout_lut_idx, tmpa                    ; Starting LUT index for a possible auto-dimout

    ldi ZL, low(triac_lut * 2)
    ldi ZH, high(triac_lut * 2)
    add ZL, tmpa
    adc ZH, r0                                  ; r0 is permanently zero
    lpm triac_delay, Z

rjmp MAIN


; Load the next interval duration.
; Exactly dimout_remainder of dimout_steps intervals receive q+1 seconds;
; the rest receive q seconds. The 8-bit accumulator may overflow, so C is checked.
load_dimout_interval:
    mov poff_counter0, seconds_per_division0
    mov poff_counter1, seconds_per_division1

    add dimout_error, dimout_remainder
    brcs dimout_interval_extra
    cp dimout_error, dimout_steps
    brlo dimout_interval_ready
dimout_interval_extra:
    sub dimout_error, dimout_steps
    inc poff_counter0                          ; r15:r14 is not a valid ADIW register pair
    brne dimout_interval_ready
    inc poff_counter1
dimout_interval_ready:
    ret


; ========== Gamma-corrected LUT
; Indices 0..127 preserve the gamma-corrected potentiometer mapping (delay 10..199).
; Indices 128..147 are dimout-only: each low-end delay 200..209 is repeated twice
; to spend more time in the low-brightness region while keeping LUT-only control.
; For the actual interrupt sequence:
; alpha=(triac_delay+1)*pi/250
; P=((pi-alpha)+sin(2*alpha)/2)/pi
triac_lut:
    .db  10,  31,  39,  45,  50,  54,  58,  61
    .db  64,  67,  69,  72,  74,  76,  79,  81
    .db  83,  84,  86,  88,  90,  91,  93,  95
    .db  96,  98,  99, 101, 102, 103, 105, 106
    .db 107, 109, 110, 111, 113, 114, 115, 116
    .db 117, 119, 120, 121, 122, 123, 124, 125
    .db 126, 128, 129, 130, 131, 132, 133, 134
    .db 135, 136, 137, 138, 139, 140, 141, 142
    .db 143, 144, 145, 146, 147, 148, 149, 149
    .db 150, 151, 152, 153, 154, 155, 156, 157
    .db 158, 159, 160, 160, 161, 162, 163, 164
    .db 165, 166, 167, 168, 168, 169, 170, 171
    .db 172, 173, 174, 175, 175, 176, 177, 178
    .db 179, 180, 181, 181, 182, 183, 184, 185
    .db 186, 187, 188, 188, 189, 190, 191, 192
    .db 193, 194, 195, 195, 196, 197, 198, 199
    .db 200, 200, 201, 201, 202, 202, 203, 203
    .db 204, 204, 205, 205, 206, 206, 207, 207
    .db 208, 208, 209, 209
