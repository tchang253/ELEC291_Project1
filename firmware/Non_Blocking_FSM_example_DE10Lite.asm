; Non_Blocking_FSM_example.asm:  Four FSMs are run in the forever loop.
; Three FSMs are used to detect (with debounce) when either KEY1, KEY2, or
; KEY3 are pressed.  The fourth FSM keeps a counter (Count3) that is incremented
; every second.  When KEY1 is detected the program increments/decrements Count1,
; depending on the position of SW0. When KEY2 is detected the program
; increments/decrements Count2, also base on the position of SW0.  When KEY3
; is detected, the program resets Count3 to zero.  gfdfddffdf
;
$NOLIST
$MODDE1SOC
$LIST

CLK           EQU 33333333 ; Microcontroller system crystal frequency in Hz
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))

;-------------------------------------------;


SOAK_TEMP	equ 150;deg threshold to leave state 1
SOAK_TIME	equ 60 ;seconds in state 2
REFLOW_TEMP equ 220;deg threshold to leave state 3
REFLOW_TIME equ 45 ;secondes in state 4
COOL_TEMP	equ 60 ;deg threshold to leave state 5

PWR_FULL    equ 100 ;duty %
PWR_MAINTAIN equ 20 ; to stay at the same temp
PWR_OFF		equ 0 ;


;state number
;do this 
;mov state, #S_HEAT2
S_IDLE  EQU 0
S_HEAT1 EQU 1
S_SOAK  EQU 2
S_HEAT2 EQU 3
S_REFLOW EQU 4
S_COOL  EQU 5




; Reset vector
org 0x0000
    ljmp main

dseg at 0x30
; 1ms counter to count to 1000 for one sec for timekeeping
Count1ms: ds 2
sec_count: ds 1 ;counts how many seconds
time_in_state_n: ds 2 ;counts how many seconds has elapsed in each state

;pwm counters
pwm_phase_ms: ds 2 ;duty cycle counter
heater_duty_ms: ds 2  ;;input settable duty cycle

; Each FSM has its own state counter
FSM1_state: ds 1

state:		ds 1 ;store the fsm number in this variable.
sec_in_state: ds 1 ;counts the second in each states(increment evevry time when flag_1s triggers)
pwm_duty:	ds 1 ; duty command for PWM engine
ms_lo:		ds 1 ;used to ocund miilisecond 
ms_high:	ds 1 

;brandon added these
temp_preheat:      ds 1    
time_soak:         ds 1    
temp_reflow:       ds 1    
time_reflow_hold:  ds 1    
temp_cool_done:    ds 1   

bseg
; For each pushbutton we have a flag.  The corresponding FSM will set this
; flags to one when a valid press of the pushbutton is detected.
flag_1s:	dbit 1	;set once per second by timer2 ISR
start_evt:	dbit 1	;set when the start button is pressed
stop_evt:	dbit 1	; this overide all states! immediately set heater off and go back to idle
flag_adc: dbit 1
heater_enable: dbit 1
cseg
;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	mov RCAP2H, #high(TIMER2_RELOAD)
	mov RCAP2L, #low(TIMER2_RELOAD)
	; initialize counter
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
    clr a
    mov pwm_phase_ms+0, a
    mov pwm_phase_ms+1, a
	; Enable the timer and interrupts
    setb ET2  ; Enable timer 2 interrupt
    setb TR2  ; Enable timer 2
	ret

;---------------------------------;
; ISR for timer 2.  Runs evere ms ;
;---------------------------------;
Timer2_ISR:
	clr TF2  ; Timer 2 doesn't clear TF2 automatically. Do it in ISR
	; Increment the timers for each FSM. That is all we do here!
	push acc
	push psw
	
    inc Count1ms+0
    mov a, Count1ms+0
    jnz check_onesec
    inc Count1ms+1
    
check_onesec:
    mov a, Count1ms+0
    cjne a, #low(1000), pwm
    mov a, Count1ms+1
    cjne a, #high(1000), pwm
    
    ;reached 1000 so reset counter and set flags
    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb flag_1s

pwm:
    inc pwm_phase_ms+0
    mov a, pwm_phase_ms+0
    jnz checkpwm
    inc pwm_phase_ms+1
    
checkpwm:
    ;-- initial check. If heater_enable has been turned off, check if 1000 ms has passed
    jnb heater_enable, checkpwmloop 
    ;---------------------------------------
    mov a, pwm_phase_ms+0
    cjne a, #low(500), pwmon
    mov a, pwm_phase_ms+1
    cjne a, #high(500), pwmon
    
    ;if exactly 500ms has passed, turn off the heater, this should only happen once every 500ms
    clr heater_enable
    sjmp finishISR2

pwmon:
    setb heater_enable ;keep enable on
    sjmp finishISR2
checkpwmloop:;checks if 1000ms passed, if so, clear counter, turn enable back on
    mov a, pwm_phase_ms+0
    cjne a, #low(1000), finishISR2
    mov a, pwm_phase_ms+1
    cjne a, #high(1000), finishISR2

    clr a
    mov pwm_phase_ms+0, a
    mov pwm_phase_ms+1, a
    setb heater_enable

finishISR2:	
    pop psw
    pop acc
	reti

; Look-up table for the 7-seg displays. (Segments are turn on with zero) 
T_7seg:
    DB 40H, 79H, 24H, 30H, 19H, 12H, 02H, 78H, 00H, 10H

; Displays a BCD number pased in R0 in HEX1-HEX0
Display_BCD_7_Seg_HEX10:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX1, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX0, a
	
	ret

; Displays a BCD number pased in R0 in HEX3-HEX2
Display_BCD_7_Seg_HEX32:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX3, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX2, a
	
	ret

; Displays a BCD number pased in R0 in HEX5-HEX4
Display_BCD_7_Seg_HEX54:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX5, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX4, a
	
	ret

; The 8-bit hex number passed in the accumulator is converted to
; BCD and stored in [R1, R0]
Hex_to_bcd_8bit:
	mov b, #100
	div ab
	mov R1, a   ; After dividing, a has the 100s
	mov a, b    ; Remainder is in register b
	mov b, #10
	div ab ; The tens are stored in a, the units are stored in b 
	swap a
	anl a, #0xf0
	orl a, b
	mov R0, a
	ret

;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.     ;
;---------------------------------;


main:
	; Initialization of hardware
    mov SP, #0x7F
    lcall Timer2_Init
    ; Turn off all the LEDs
    mov LEDRA, #0 ; LEDRA is bit addressable
    mov LEDRB, #0 ; LEDRB is NOT bit addresable
    setb EA   ; Enable Global interrupts
    
    ; Initialize variables
    mov FSM1_state, #0 
    mov FSM2_state, #0
    mov FSM3_state, #0
    mov FSM4_state, #0
    mov Count1, #0
    mov Count2, #0
    mov Count3, #0
	
	;;variables for FSM brandon added, initialization

    mov temp_preheat,     #150
    mov time_soak,        #60
    mov temp_reflow,      #220
    mov time_reflow_hold, #45
    mov temp_cool_done,   #60
    
    ; Display the initial value of each counter
    mov a, Count1
    lcall Hex_to_bcd_8bit
	lcall Display_BCD_7_Seg_HEX10
    mov a, Count2
    lcall Hex_to_bcd_8bit
	lcall Display_BCD_7_Seg_HEX32
    mov a, Count3
    lcall Hex_to_bcd_8bit
	lcall Display_BCD_7_Seg_HEX54
	
	; After initialization the program stays in this 'forever' loop
loop:
    ; stop overrides everything (optional if you already handle inside fsm)
    jbc stop_evt, do_stop_now

    ; wait until timer sets the 1-second flag
    jnb flag_1s, loop
    clr flag_1s

    ; 1 second just happened
    inc sec_in_state

    ; temp update (for now you can fake it to test transitions)
    ; later replace this with adc->temp conversion
    ; inc temp_c

    ; run one fsm step
    lcall reflow_fsm_step

    ; debug: show state on leds (so you see transitions)
    mov a, state
    mov ledra, a

    sjmp loop

do_stop_now:
    mov pwm_duty, #0
    clr ssr_pin
    mov state, #s_idle
    mov sec_in_state, #0
    sjmp loop


;-------------------------------------------------------------------------------
; non-blocking state machine starts here

; Brandon: I copied the fsm code from the slides for state 0, 1, and 2.
; For now its not in variables im gonna change it tho


; state 0: IDLE, Power=0%, wait for start
;-------------------------------------------
; reflow fsm (non-blocking) using shared names
; state        : 0..5
; sec_in_state : seconds since entering current state
; temp_c       : current temp in °c
; pwm_duty     : 0..100 duty command
;-------------------------------------------

reflow_fsm_step:

    ; stop overrides everything
    jbc stop_evt, reflow_stopnow

    mov a, state

;-------------------------
; state 0: idle
;-------------------------
state0:
    cjne a, #s_idle, state1
    mov pwm_duty, #pwr_off

    ; wait for start event
    jbc start_evt, go_state1
    ret

go_state1:
    mov state, #s_heat1
    mov sec_in_state, #0
    mov pwm_duty, #pwr_full
    ret

;-------------------------
; state 1: preheat/ramp to temp_preheat
; power = 100% until temp_c >= temp_preheat
;-------------------------
state1:
    cjne a, #s_heat1, state2
    mov pwm_duty, #pwr_full

    ; if temp_c < temp_preheat -> stay
    mov a, temp_c
    clr c
    subb a, temp_preheat
    jc  state1_stay

    ; else reached threshold -> go soak
    mov state, #s_soak
    mov sec_in_state, #0
    ret
state1_stay:
    ret

;-------------------------
; state 2: soak
; power = 20% for time_soak seconds
;-------------------------
state2:
    cjne a, #s_soak, state3
    mov pwm_duty, #pwr_maintain

    ; if sec_in_state < time_soak -> stay
    mov a, sec_in_state
    clr c
    subb a, time_soak
    jc  state2_stay

    ; else -> reflow ramp
    mov state, #s_heat2
    mov sec_in_state, #0
    ret
state2_stay:
    ret

;-------------------------
; state 3: reflow ramp
; power = 100% until temp_c >= temp_reflow
;-------------------------
state3:
    cjne a, #s_heat2, state4
    mov pwm_duty, #pwr_full

    mov a, temp_c
    clr c
    subb a, temp_reflow
    jc  state3_stay

    mov state, #s_reflow
    mov sec_in_state, #0
    ret
state3_stay:
    ret

;-------------------------
; state 4: reflow hold
; power = 0% until sec_in_state >= time_reflow_hold
;-------------------------
state4:
    cjne a, #s_reflow, state5
    mov pwm_duty, #pwr_off

    mov a, sec_in_state
    clr c
    subb a, time_reflow_hold
    jc  state4_stay

    mov state, #s_cool
    mov sec_in_state, #0
    ret
state4_stay:
    ret

;-------------------------
; state 5: cool
; power = 0% until temp_c < temp_cool_done
;-------------------------
state5:
    cjne a, #s_cool, fsm_done
    mov pwm_duty, #pwr_off

    ; if temp_c >= temp_cool_done -> stay
    mov a, temp_c
    clr c
    subb a, temp_cool_done
    jnc state5_stay

    ; else done -> back to idle
    mov state, #s_idle
    mov sec_in_state, #0
    ret
state5_stay:
    ret

fsm_done:
    ret


reflow_stopnow:
    ; immediate stop behavior
    mov pwm_duty, #pwr_off
    mov state, #s_idle
    mov sec_in_state, #0
    ret

END