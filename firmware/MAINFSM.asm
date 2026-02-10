
$NOLIST
$MODMAX10
$LIST

CLK           EQU 33333333 ; Microcontroller system crystal frequency in Hz
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))

;-------------------------------------------;

SSR_PIN     equ P0.3


SOAK_TEMP	equ 150;deg threshold to leave state 1
SOAK_TIME	equ 60 ;seconds in state 2
REFLOW_TEMP equ 220;deg threshold to leave state 3
REFLOW_TIME equ 45 ;secondes in state 4
COOL_TEMP	equ 60 ;deg threshold to leave state 5

PWR_FULL    equ 100 ;duty %
PWR_MAINTAIN equ 20 ; to stay at the same temp
PWR_OFF		equ 0 ;

;state number
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

org 0x002B
    ljmp Timer2_ISR

dseg at 0x30
; 1ms counter to count to 1000 for one sec for timekeeping
Count1ms: ds 2
sec_count: ds 1 ;counts how many seconds
time_in_state: ds 1 ;counts how many seconds has elapsed in each state
heater_duty_ms: ds 2  ;;input settable duty cycle
state:		ds 1 ;store the fsm number in this variable.

;use inc temp_c subroutine just to test the fsm first
;will be converted from the adc later
temp_c:         ds 1

bseg
; For each pushbutton we have a flag.  The corresponding FSM will set this
; flags to one when a valid press of the pushbutton is detected.
flag_1s:	dbit 1	;set once per second by timer2 ISR
start_evt:	dbit 1	;set when the start button is pressed
stop_evt:	dbit 1	; this overide all states! immediately set heater off and go back to idle
flag_adc: dbit 1
heater_enable: dbit 1
duty: dbit 1 ;if duty ==1 then on, if duty == 0, then off
cseg




;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD) ;current counter value
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	mov RCAP2H, #high(TIMER2_RELOAD)
	mov RCAP2L, #low(TIMER2_RELOAD)
	; initialize counter
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
    
	; Enable the timer and interrupts
    setb ET2  ; Enable timer 2 interrupt
    clr TR2  ; dont enable timer 2 yet	
	ret 

;---------------------------------;
; ISR for timer 2.  Runs evere ms         
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
    cjne a, #low(1000), finishISR2
    mov a, Count1ms+1
    cjne a, #high(1000), finishISR2
  
    ;reached 1000 so reset counter and set flags
    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb flag_1s
	setb duty ;re arm duty at 1s wrap. this is the common period so easier to do here

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
	orl P0MOD, #0FH    ; configure P0.3 as output (set bit3 = 1). 
    ; Turn off all the LEDs
    mov LEDRA, #0 ; LEDRA is bit addressable
    mov LEDRB, #0 ; LEDRB is NOT bit addresable
    setb EA   ; Enable Global interrupts
    
    ; Initialize variables
    clr heater_enable
    mov sec_count, #0
    mov time_in_state, #0
    mov state, #S_IDLE
    clr SSR_PIN
	setb duty
	clr P0.0

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

mainloopfsm:
	;jump to state depending on state variable
	mov a, state
	cjne a, #S_IDLE, chk_S_HEAT1
	sjmp IDLE
chk_S_HEAT1:
	cjne a, #S_HEAT1, chk_S_SOAK
	sjmp PREHEAT1
chk_S_SOAK:
	cjne a, #S_SOAK, chk_S_HEAT2
	sjmp SOAK
chk_S_HEAT2:
	cjne a, #S_HEAT2, chk_S_REFLOW
	ljmp HEAT2
chk_S_REFLOW:
	cjne a, #S_REFLOW, chk_S_COOL
	ljmp REFLOW
chk_S_COOL:
	cjne a, #S_COOL, mainloopfsm
	ljmp COOL  ;if not any of the states match, just jump back to the beginning of the fsm loop

;-----IDLE-----;
IDLE:
	clr SSR_PIN
	;wait for start button
	jnb KEY.1, IDLEPRESSED		; this will poll the button
    sjmp mainloopfsm
IDLEPRESSED:
    setb heater_enable
	mov time_in_state, #0
	mov state, #S_HEAT1
	setb TR2 ;turn on timer 2
	sjmp mainloopfsm

;------first heating state, full power until reach soak temp------;
PREHEAT1:
;immediate transition to idle if heater enable is turned off
	jnb heater_enable, HEAT1_to_IDLE ;if heater enable is turned off, instant shut off
	; increment seconds once per second
	jb flag_1s, increment1
	sjmp KEEPHEAT1
increment1:
	clr flag_1s
	inc time_in_state
	mov a, time_in_state
    lcall Hex_to_bcd_8bit   ; converts A -> R1:R0 (BCD)
    lcall Display_BCD_7_Seg_HEX10 ;display time in each state on hex
KEEPHEAT1:
	setb SSR_PIN ;; turn on heater at full power
	mov c, SSR_PIN ;;testing to see if pin is being toggled
	mov LEDRA.0, c
	mov a, time_in_state
	cjne a, #30, mainloopfsm  ;constant can be adjusted as needed, heat until x seconds have passed
	;once it equals, transtion to soak
	mov time_in_state, #0
	mov state, #S_SOAK
	sjmp mainloopfsm
HEAT1_to_IDLE:
	clr heater_enable
	clr SSR_PIN
    clr TR2 ;turn off timer 2
	mov state, #S_IDLE
	sjmp mainloopfsm

;------SOAK------;
SOAK:
    jnb heater_enable, SOAK_to_IDLE ;if heater enable turned off return to idle
    jb flag_1s, increment2
	sjmp STARTSOAK
increment2:
	clr flag_1s
	inc time_in_state
	mov a, time_in_state
    lcall Hex_to_bcd_8bit   ; converts A -> R1:R0 (BCD)
    lcall Display_BCD_7_Seg_HEX10 ;display time in each state on hex
	;timer isr will setb duty once flag goes to reduce latency
STARTSOAK: ;in the soak state, it runs a duty cycle. lets say for now, duty cycle is about 20% so 200ms (adjust later)
	jnb duty, STOPSOAK
	setb SSR_PIN 
	mov a, Count1ms+0	;if 200 ms hasn't passed then keep oven on. 200ms on 800ms off
    cjne a, #low(200), KEEPSOAK
    mov a, Count1ms+1
    cjne a, #high(200), KEEPSOAK
STOPSOAK:
	clr duty ;duty cycle now off
	clr SSR_PIN ;pin is now off until count1ms looped back to 0 again
	sjmp checktime 
KEEPSOAK:
	setb duty ;make sure duty still on go check time and re enter
	setb SSR_PIN
checktime:
	mov c, SSR_PIN ;;testing to see if pin is being toggled
	mov LEDRA.0, c
	mov a, time_in_state
	cjne a, #SOAK_TIME, SOAKRETURN ;once it equals, go to next state
	mov time_in_state, #0
	mov state, #S_HEAT2
SOAKRETURN:
	ljmp mainloopfsm

SOAK_to_IDLE:
	clr heater_enable
	clr SSR_PIN
	clr TR2
	mov state, #S_IDLE
	ljmp mainloopfsm

	;------second heating full power to reach 220. for now test with time, 30 seconds again---;
	HEAT2:
;immediate transition to idle if heater enable is turned off
	jnb heater_enable, HEAT2_to_IDLE ;if heater enable is turned off, instant shut off
	; increment seconds once per second
	mov c, SSR_PIN ;;testing to see if pin is being toggled
	mov LEDRA.0, c
	jb flag_1s, increment3
	sjmp KEEPHEAT2
increment3:
	clr flag_1s
	inc time_in_state
	mov a, time_in_state
    lcall Hex_to_bcd_8bit   ; converts A -> R1:R0 (BCD)
    lcall Display_BCD_7_Seg_HEX10 ;display time in each state on hex
KEEPHEAT2:
	setb SSR_PIN ;; turn on heater at full power
	mov a, time_in_state
	cjne a, #30, HEAT2RETURN  ;constant can be adjusted as needed, heat until x seconds have passed
	;once it equals, transtion to soak. (later will be comparing with temp, not time)
	mov time_in_state, #0
	mov state, #S_REFLOW
	clr SSR_PIN
HEAT2RETURN:
	ljmp mainloopfsm
HEAT2_to_IDLE:
	clr heater_enable
	clr SSR_PIN
    clr TR2 ;turn off timer 2
	mov state, #S_IDLE
	ljmp mainloopfsm

	;------reflow, stay at max temp for 45seconds at 20% duty----;
REFLOW:
    jnb heater_enable, REFLOW_to_IDLE ;if heater enable turned off return to idle
    jb flag_1s, increment4
	sjmp STARTREFLOW
increment4:
	clr flag_1s
	inc time_in_state
	mov a, time_in_state
    lcall Hex_to_bcd_8bit   ; converts A -> R1:R0 (BCD)
    lcall Display_BCD_7_Seg_HEX10 ;display time in each state on hex
	;timer isr will setb duty once flag goes to reduce latency
STARTREFLOW: ;in the soak state, it runs a duty cycle. lets say for now, duty cycle is about 20% so 200ms (adjust later)
	jnb duty, STOPREFLOW
	setb SSR_PIN 
	mov a, Count1ms+0	;if 200 ms hasn't passed then keep oven on. 200ms on 800ms off
    cjne a, #low(200), KEEPREFLOW
    mov a, Count1ms+1
    cjne a, #high(200), KEEPREFLOW
STOPREFLOW:
	clr duty ;duty cycle now off
	clr SSR_PIN ;pin is now off until count1ms looped back to 0 again
	sjmp checktime2 
KEEPREFLOW:
	setb duty ;make sure duty still on go check time and re enter
	setb SSR_PIN
checktime2:
	mov c, SSR_PIN ;;testing to see if pin is being toggled
	mov LEDRA.0, c
	mov a, time_in_state
	cjne a, #REFLOW_TIME, REFLOWRETURN ;once it equals, go to next state
	mov time_in_state, #0
	mov state, #S_COOL
REFLOWRETURN:
	ljmp mainloopfsm

REFLOW_to_IDLE:
	clr heater_enable
	clr SSR_PIN
	clr TR2
	mov state, #S_IDLE
	ljmp mainloopfsm

;-----cooling state. Needs to cool until temp < 60, then transtition back to idle.---;
;---because no temp measure rn, will just stay in this state for ~15 seconds to test---;
COOL:
;immediate transition to idle if heater enable is turned off
	jnb heater_enable, COOL_to_IDLE ;if heater enable is turned off, instant shut off
	; increment seconds once per second
	jb flag_1s, increment5
	sjmp KEEPCOOL
increment5:
	clr flag_1s
	inc time_in_state
	mov a, time_in_state
    lcall Hex_to_bcd_8bit   ; converts A -> R1:R0 (BCD)
    lcall Display_BCD_7_Seg_HEX10 ;display time in each state on hex
KEEPCOOL:
	clr SSR_PIN ;; turn off heater 
	mov a, time_in_state
	mov c, SSR_PIN ;;testing to see if pin is being toggled
	mov LEDRA.0, c
	cjne a, #15, COOLRETURN  ;just for testing, actual case should be < 60 degrees
	mov time_in_state, #0
	mov state, #S_IDLE
COOLRETURN:
	ljmp mainloopfsm
COOL_to_IDLE:
	clr heater_enable
	clr SSR_PIN
    clr TR2 ;turn off timer 2
	mov state, #S_IDLE
	ljmp mainloopfsm
	
END