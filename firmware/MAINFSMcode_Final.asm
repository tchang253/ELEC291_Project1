$NOLIST 
$MODMAX10
$LIST

CLK           EQU 33333333 ; Hz
TIMER2_RATE   EQU 1000     ; 1ms tick
TIMER2_RELOAD EQU (65536-(CLK/(12*TIMER2_RATE)))




; ------------------- NEW: Timer0 tone generator -------------------
;
T0_TOGGLE_HZ     EQU 4096
TIMER0_RELOAD    EQU (65536-(CLK/(12*T0_TOGGLE_HZ)))
; ------------------------------------------------------------------


BAUD               EQU 57600
TIMER1_UART_RELOAD EQU (256 - ((CLK*2) / (32*12*BAUD)))

; constants
SSR_PIN     equ P0.3
BTN_SOAK_TI    equ p2.0
BTN_REFLOW_TI  equ p1.6
BTN_STEMP   equ p1.4
BTN_RTEMP   equ p1.2
BTN_MODE	equ p2.2
SPK_PIN      equ P0.0    


STEMP  equ 150
STIME  equ 60
RTEMP  equ 220
RTIME  equ 45
CTEMP  equ 60

S_TH_TEMP equ 1500
R_TH_TEMP equ 2200
C_TH_TEMP equ 600
ABORTTEMP equ 500

; Power constants for printing only (no real PWM changes here)
PWR_FULL     equ 100
PWR_MAINTAIN equ 50
PWR_OFF      equ 0

; FSM states (match MAINFSM naming)
S_IDLE   EQU 0
S_HEAT1  EQU 1
S_SOAK   EQU 2
S_HEAT2  EQU 3
S_REFLOW EQU 4
S_COOL   EQU 5

;ADC channel assignements
CH_LM335 EQU 0 ;lm355 cold junction connected to channel 0
CH_OP07  EQU 1 ;thermocouple amplifier connected channel 1

;calibration vales(current without lm4040 Vref. measured)
VCC_MV   EQU 49900 ;mv
CONST_TH EQU 81	;for gain = 302
TC_DEN   EQU 12382   ; 41*302


BEEP_ON_MS   equ 120     ; was 80
BEEP_OFF_MS  equ 120     ; was 70
; ------------------------------------------------------------------

; ============================================================
; Vectors
; ============================================================
org 0x0000
    ljmp main

org 0x0003 
	ljmp INT0_ISR


org 0x000B
    ljmp Timer0_ISR
; ----------------------------------------------------------------

org 0x002B
    ljmp Timer2_ISR

; ============================================================
; RAM
; ============================================================
dseg at 0x30

Count1ms:        ds 2
sec_count:       ds 1
State_seconds:   ds 1
heater_duty_ms:  ds 2
FSM_state:       ds 1

SOAK_TEMP:       ds 1
SOAK_TIME:       ds 1
REFLOW_TEMP:     ds 1
REFLOW_TIME:     ds 1
x:               ds 4
y:               ds 4
bcd:             ds 5
TEMP_TOTAL:		 ds 2
th_preheat_soak: ds 2
th_ramp_reflow:  ds 2
th_cool_idle:    ds 2
abort_cond:		 ds 2

ADC_LM335_L:     ds 1
ADC_LM335_H:     ds 1
ADC_OP07_H:      ds 1
ADC_OP07_L:      ds 1
ADC_OP07_OFF_H:  ds 1
ADC_OP07_OFF_L:  ds 1

TEMP_COLD: ds 2
TEMP_HOT:  ds 2

beep_num_left:   ds 1
beep_state:      ds 1
beep_ms:         ds 1   ; countdown ms for current ON/OFF segment
; ---------------------------------------------------------

bseg
beep_active:     dbit 1
flag_1s:         dbit 1
start_evt:       dbit 1
stop_evt:        dbit 1
flag_adc:        dbit 1
heater_enable:   dbit 1
duty:            dbit 1
flag_serial_out: dbit 1
mf:              dbit 1

cseg
;LCD_RW equ PX.X ; Not used in this code, connect the pin to GND
ELCD_RS equ P3.7
ELCD_E  equ P3.3
ELCD_D4 equ P3.1
ELCD_D5 equ P2.7
ELCD_D6 equ P2.5
ELCD_D7 equ P2.3

$NOLIST
$include(math32.asm)
$LIST

$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$LIST

$NOLIST
$include(lcd_display.inc)
$LIST

; ============================================================
; NEW: Timer0 init + ISR for tone generation on SPK_PIN
; ============================================================
Timer0_Init:
    ; Timer0 mode1 (16-bit)
    mov a, TMOD
    anl a, #0F0H
    orl a, #01H
    mov TMOD, a

    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)

    clr TR0          ; tone OFF by default
    setb ET0         ; enable Timer0 interrupt
    ret

Timer0_ISR:
    ; reload
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    cpl SPK_PIN
    reti

; ============================================================
; ============================================================
Timer2_Init:
    mov T2CON, #0
    mov TH2, #high(TIMER2_RELOAD)
    mov TL2, #low(TIMER2_RELOAD)
    mov RCAP2H, #high(TIMER2_RELOAD)
    mov RCAP2L, #low(TIMER2_RELOAD)

    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a

    setb ET2
    setb TR2
    ret
    
INT0_ISR:
	push acc
    push psw

    ; abort logic
    clr heater_enable
    clr SSR_PIN

	mov a, #10
    lcall Beep_Request
    
    
    pop psw
    pop acc
    reti

Timer2_ISR:
    clr TF2
    push acc
    push psw

    ; --- 1ms counter ---
    inc Count1ms+0
    mov a, Count1ms+0
    jnz t2_check_1s
    inc Count1ms+1

t2_check_1s:
    mov a, Count1ms+0
    cjne a, #low(1000), t2_beep_engine
    mov a, Count1ms+1
    cjne a, #high(1000), t2_beep_engine

    ; reached 1 second
    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a

    setb flag_1s
    setb flag_serial_out
    setb duty
    setb flag_adc

t2_beep_engine:
    jnb beep_active, t2_done_beep

    mov a, beep_ms
    jz  beep_seg_done
    dec beep_ms
    sjmp t2_done_beep

beep_seg_done:
    mov a, beep_state
    cjne a, #1, seg_was_gap

    ; ON finished go to GAP (tone off)
    clr TR0
    clr SPK_PIN
    mov beep_state, #2
    mov beep_ms, #BEEP_OFF_MS
    sjmp t2_done_beep

seg_was_gap:
    mov a, beep_num_left
    jz  stop_beep
    dec a
    mov beep_num_left, a
    jz  stop_beep

    ; start next ON
    mov beep_state, #1
    mov beep_ms, #BEEP_ON_MS
    setb TR0
    sjmp t2_done_beep


stop_beep:
    clr beep_active
    clr TR0
    clr SPK_PIN

t2_done_beep:
; -------------------------------------------------------------------------------

t2_done:
    pop psw
    pop acc
    reti

Beep_Request:
    mov beep_num_left, a
    mov beep_state, #1
    mov beep_ms, #BEEP_ON_MS
    setb beep_active
    clr SPK_PIN
    setb TR0
    ret

; ============================================================
; ADC calculation helper functions
; ============================================================
Calc_Cold_Junction:
    mov x+0, ADC_LM335_L
    mov x+1, ADC_LM335_H
    mov x+2, #0
    mov x+3, #0

    Load_y(VCC_MV)
    lcall mul32
    Load_y(4095)
    lcall div32

    Load_y(10)
    lcall div32

    Load_y(2731)
    lcall sub32

    mov TEMP_COLD, x+0
    mov TEMP_COLD+1, x+1
    ret

Calc_Hot_Junction:
    mov x+0, ADC_OP07_L
    mov x+1, ADC_OP07_H
    mov x+2, #0
    mov x+3, #0

    mov y+0, ADC_OP07_OFF_L
    mov y+1, ADC_OP07_OFF_H
    mov y+2, #0
    mov y+3, #0

    lcall sub32

    mov a, x+3
    jnb acc.7, Hot_Pos
    mov x+0, #0
    mov x+1, #0
    mov x+2, #0
    mov x+3, #0
Hot_Pos:

    Load_y(VCC_MV)
    lcall mul32
    Load_y(4095)
    lcall div32

    Load_y(1000)
    lcall mul32
    Load_y(TC_DEN)
    lcall div32

    mov TEMP_HOT, x+0
    mov TEMP_HOT+1, x+1
    ret

Calc_Total_Temp:
    mov x+0, TEMP_COLD
    mov x+1, TEMP_COLD+1
    mov x+2, #0
    mov x+3, #0

    mov y+0, TEMP_HOT
    mov y+1, TEMP_HOT+1
    mov y+2, #0
    mov y+3, #0

    lcall add32

    mov TEMP_TOTAL, x+0
    mov TEMP_TOTAL+1, x+1
    ret

Read_ADC:
    push acc
    orl a, #0x80
    mov ADC_C, a
    Wait_Milli_Seconds(#1)
    pop acc
    mov ADC_C, a
    Wait_Milli_Seconds(#1)
    mov R0, ADC_L
    mov R1, ADC_H
    ret

; ============================================================
; 7-seg helpers
; ============================================================
T_7seg:
    DB 40H, 79H, 24H, 30H, 19H, 12H, 02H, 78H, 00H, 10H

Display_BCD_7_Seg_HEX10:
    mov dptr, #T_7seg
    mov a, R0
    swap a
    anl a, #0FH
    movc a, @a+dptr
    orl a, #10000000B
    mov HEX1, a

    mov a, R0
    anl a, #0FH
    movc a, @a+dptr
    orl a, #10000000B
    mov HEX0, a
    ret

Hex_to_bcd_8bit:
    mov b, #100
    div ab
    mov R1, a
    mov a, b
    mov b, #10
    div ab
    swap a
    anl a, #0F0H
    orl a, b
    mov R0, a
    ret

; ============================================================
; UART init + TX
; ============================================================
InitSerialPort:
    clr TR1
    mov TMOD, #020H
    mov TH1, #TIMER1_UART_RELOAD
    mov TL1, #0

    mov a, PCON
    orl a, #080H
    mov PCON, a

    mov SCON, #052H
    setb TR1
    setb TI
    ret

putchar:
    jnb TI, putchar
    clr TI
    mov SBUF, a
    ret

SendString:
    clr a
    movc a, @a+dptr
    jz SendString_done
    lcall putchar
    inc dptr
    sjmp SendString
SendString_done:
    ret

SendNewline:
    mov a, #0x0D
    lcall putchar
    mov a, #0x0A
    lcall putchar
    ret

Print8_Int:
    push acc
    push b
    push psw
    
	mov R7, #0
	
	mov b, #100
    div ab
    jz p8_hund_done
    add a, #'0'
    lcall putchar
    mov R7, #1
    
p8_hund_done:
	mov a, b
	mov b, #10
	div ab
	
	jnz p8_print_tens
	
	mov a, R7
	jz p8_ones
	mov a, #'0'
	lcall putchar
	sjmp p8_ones
	
p8_print_tens:
	add a, #'0'
	lcall putchar
p8_ones:
	mov a,b
	add a, #'0'
	lcall putchar
	
	pop psw
    pop b
    pop acc
    ret

; ============================================================
; Dummy Serial Output (unchanged)
; ============================================================
SerialOutput_Dummy:
    mov dptr, #str_temp
    lcall SendString
    mov x+0, TEMP_TOTAL
  	mov x+1, TEMP_TOTAL+1
  	mov x+2, #0
  	mov x+3, #0
  	lcall hex2bcd
  
  	mov a, bcd+1
  	swap a
  	anl a, #0FH
  	jz skip_hundred
  	add a, #'0'
  	lcall putchar
skip_hundred:
 	mov a, bcd+1
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  
  	mov a, bcd+0
  	swap a
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  	
  	mov a, #'.'
    lcall putchar
  
  	mov a, bcd+0
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar

    mov dptr, #str_set
    lcall SendString

    mov a, FSM_state
    cjne a, #S_HEAT1, ser_chk_soak
    mov x+0, th_preheat_soak+0
  	mov x+1, th_preheat_soak+1
  	mov x+2, #0
  	mov x+3, #0
  	lcall hex2bcd
  
  	mov a, bcd+1
  	swap a
  	anl a, #0FH
  	jz skip_hundred1
  	add a, #'0'
  	lcall putchar
skip_hundred1:
 	mov a, bcd+1
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  
  	mov a, bcd+0
  	swap a
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  	
  	mov a, #'.'
    lcall putchar
  
  	mov a, bcd+0
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
    ljmp ser_next
    
ser_chk_soak:    
    mov a, FSM_state
    cjne a, #S_SOAK, ser_chk_ramp
    mov x+0, th_preheat_soak+0
  	mov x+1, th_preheat_soak+1
  	mov x+2, #0
  	mov x+3, #0
  	lcall hex2bcd
  
  	mov a, bcd+1
  	swap a
  	anl a, #0FH
  	jz skip_hundred2
  	add a, #'0'
  	lcall putchar
skip_hundred2:
 	mov a, bcd+1
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  
  	mov a, bcd+0
  	swap a
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  	
  	mov a, #'.'
    lcall putchar
  
  	mov a, bcd+0
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
    ljmp ser_next

ser_chk_ramp:
    mov a, FSM_state
    cjne a, #S_HEAT2, ser_chk_reflow
    mov x+0, th_ramp_reflow+0
  	mov x+1, th_ramp_reflow+1
  	mov x+2, #0
  	mov x+3, #0
  	lcall hex2bcd
  
  	mov a, bcd+1
  	swap a
  	anl a, #0FH
  	jz skip_hundred3
  	add a, #'0'
  	lcall putchar
skip_hundred3:
 	mov a, bcd+1
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  
  	mov a, bcd+0
  	swap a
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  	
  	mov a, #'.'
    lcall putchar
  
  	mov a, bcd+0
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
    sjmp ser_next
    
ser_chk_reflow:
    mov a, FSM_state
    cjne a, #S_REFLOW, ser_set_zero
    mov x+0, th_ramp_reflow+0
  	mov x+1, th_ramp_reflow+1
  	mov x+2, #0
  	mov x+3, #0
  	lcall hex2bcd
  
  	mov a, bcd+1
  	swap a
  	anl a, #0FH
  	jz skip_hundred4
  	add a, #'0'
  	lcall putchar
skip_hundred4:
 	mov a, bcd+1
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  
  	mov a, bcd+0
  	swap a
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
  	
  	mov a, #'.'
    lcall putchar
  
  	mov a, bcd+0
  	anl a, #0FH
  	add a, #'0'
  	lcall putchar
    sjmp ser_next

ser_set_zero:
    mov a, #0
    lcall Print8_Int

ser_set_done:
    mov a, #'.'
    lcall putchar
    mov a, #'0'
    lcall putchar

ser_next:
    mov dptr, #str_state
    lcall SendString

    mov a, FSM_state
    cjne a, #S_IDLE, ser_s1
    mov dptr, #State_IDLE_Str
    sjmp ser_s_print
ser_s1:
    cjne a, #S_HEAT1, ser_s2
    mov dptr, #State_RAMP_SK_Str
    sjmp ser_s_print
ser_s2:
    cjne a, #S_SOAK, ser_s3
    mov dptr, #State_SOAK_Str
    sjmp ser_s_print
ser_s3:
    cjne a, #S_HEAT2, ser_s4
    mov dptr, #State_RAMP_RF_Str
    sjmp ser_s_print
ser_s4:
    cjne a, #S_REFLOW, ser_s5
    mov dptr, #State_REFLOW_Str
    sjmp ser_s_print
ser_s5:
    mov dptr, #State_COOL_Str
ser_s_print:
    lcall SendString

    mov dptr, #str_pwm
    lcall SendString

    mov a, FSM_state
    cjne a, #S_IDLE, pwm_s1
    mov a, #PWR_OFF
    sjmp pwm_print
pwm_s1:
    cjne a, #S_HEAT1, pwm_s2
    mov a, #PWR_FULL
    sjmp pwm_print
pwm_s2:
    cjne a, #S_SOAK, pwm_s3
    mov a, #PWR_MAINTAIN
    sjmp pwm_print
pwm_s3:
    cjne a, #S_HEAT2, pwm_s4
    mov a, #PWR_FULL
    sjmp pwm_print
pwm_s4:
    cjne a, #S_REFLOW, pwm_s5
    mov a, #PWR_MAINTAIN
    sjmp pwm_print
pwm_s5:
    mov a, #PWR_OFF
pwm_print:
    lcall Print8_Int
    lcall SendNewline
    ret

; ============================================================
; Serial strings + state strings
; ============================================================
str_temp:   DB 'temp=',0
str_set:    DB ',set=',0
str_state:  DB ',state=',0
str_pwm:    DB ',pwm=',0

State_IDLE_Str:     DB 'IDLE',0
State_RAMP_SK_Str:  DB 'PREHEAT',0
State_SOAK_Str:     DB 'SOAK',0
State_RAMP_RF_Str:  DB 'RAMP',0
State_REFLOW_Str:   DB 'REFLOW',0
State_COOL_Str:     DB 'COOLING',0
SOAKTI: db 'SOAK TIME:',0
REFLOWTI: db 'RF TIME:',0
SOAKT: db 'SOAK TEMP:',0
REFLOWT: db 'RF TEMP:',0

; --- debounce
Waitmode:
    jnb BTN_MODE, Waitmode
    ret
Waitstemp:
    jnb BTN_STEMP, Waitstemp
    ret
Waitrtemp:
    jnb BTN_RTEMP, Waitrtemp
    ret
Waitsoak:
    jnb BTN_SOAK_TI, Waitsoak
    ret
Waitreflow:
    jnb BTN_REFLOW_TI, Waitreflow
    ret

soaktimeadjust:
 	mov a, SOAK_TIME
 	add a, #5
	mov SOAK_TIME, a
	cjne a, #125, done
	mov SOAK_TIME, #60
done:
	ret

reflowtimeadjust:
 	mov a, REFLOW_TIME
 	add a, #5
	mov REFLOW_TIME, a
	cjne a, #80, done1
	mov REFLOW_TIME, #45
done1:
	ret

soaktempadjust:
 	mov  a, th_preheat_soak+0
	add  a, #LOW(100)
	mov  th_preheat_soak+0, a

	mov  a, th_preheat_soak+1
	addc a, #HIGH(100)
	mov  th_preheat_soak+1, a
	
	mov a, th_preheat_soak+1
	clr c
	subb a, #HIGH(2100)
	jc  done_ok
	jnz reset_soak

	mov a, th_preheat_soak+0
	clr c
	subb a, #LOW(2100)
	jc  done_ok
reset_soak:
	mov th_preheat_soak+0, #LOW(1500)
	mov th_preheat_soak+1, #HIGH(1500)
done_ok:
	ret
	
reflowtempadjust:
 	mov  a, th_ramp_reflow+0
	add  a, #LOW(100)
	mov  th_ramp_reflow+0, a

	mov  a, th_ramp_reflow+1
	addc a, #HIGH(100)
	mov  th_ramp_reflow+1, a
	
	mov a, th_ramp_reflow+1
	clr c
	subb a, #HIGH(3100)
	jc  done_ok2
	jnz reset_reflow

	mov a, th_ramp_reflow+0
	clr c
	subb a, #LOW(3100)
	jc  done_ok2
reset_reflow:
	mov th_ramp_reflow+0, #LOW(2200)
	mov th_ramp_reflow+1, #HIGH(2200)
done_ok2:
	ret

; ============================================================
; MAIN + FSM
; ============================================================
main:
    mov SP, #0x7F
	orl P0MOD, #0FH
    mov P1MOD, #10101011B
    mov P2MOD, #11111010B
    mov P3MOD, #0xff
    mov LEDRA, #0
    mov LEDRB, #0

    ; Init timer + serial + tone timer
    lcall Timer2_Init
    lcall Timer0_Init
    lcall InitSerialPort

    clr SPK_PIN
    clr TR0
    clr beep_active
    setb EX0
    setb IT0

    ; initialize lcd
    lcall ELCD_4BIT

    mov SOAK_TEMP,  #STEMP
    mov SOAK_TIME,  #60
    mov REFLOW_TEMP,#RTEMP
    mov REFLOW_TIME,#45
    
    mov th_preheat_soak+0, #low(S_TH_TEMP)
    mov th_preheat_soak+1, #high(S_TH_TEMP)
    mov th_ramp_reflow+0,  #low(R_TH_TEMP)
    mov th_ramp_reflow+1,  #high(R_TH_TEMP)
    mov th_cool_idle+0,    #low(C_TH_TEMP)
    mov th_cool_idle+1,    #high(C_TH_TEMP)

    mov abort_cond+0, #low(ABORTTEMP)
    mov abort_cond+1, #high(ABORTTEMP)
    
    mov ADC_C, #0x80
	Wait_Milli_Seconds(#50)
	mov a, #CH_OP07
	lcall Read_ADC
	mov ADC_OP07_OFF_L, R0
	mov ADC_OP07_OFF_H, R1
    
    clr heater_enable
    mov sec_count, #0
    mov State_seconds, #0
    mov FSM_state, #S_IDLE
    clr SSR_PIN
    setb duty
    setb flag_adc

    setb EA

mainloopfsm:
	jnb flag_adc, checkser1
    clr flag_adc

    mov a, #CH_LM335
	lcall Read_ADC
	mov ADC_LM335_L, R0
	mov ADC_LM335_H, R1

	mov a, #CH_OP07
	lcall Read_ADC
	mov ADC_OP07_L, R0
	mov ADC_OP07_H, R1

	lcall Calc_Cold_Junction
	lcall Calc_Hot_Junction
	lcall Calc_Total_Temp

checkser1:
    jnb flag_serial_out, fsm_dispatch
    clr flag_serial_out
    lcall SerialOutput_Dummy

fsm_dispatch:
    mov a, FSM_state
    cjne a, #S_IDLE,  chk_S_HEAT1
    ljmp IDLE
chk_S_HEAT1:
    cjne a, #S_HEAT1, chk_S_SOAK
    ljmp PREHEAT1
chk_S_SOAK:
    cjne a, #S_SOAK,  chk_S_HEAT2
    ljmp SOAK
chk_S_HEAT2:
    cjne a, #S_HEAT2, chk_S_REFLOW
    ljmp HEAT2
chk_S_REFLOW:
    cjne a, #S_REFLOW, chk_S_COOL
    ljmp REFLOW
chk_S_COOL:
    cjne a, #S_COOL, mainloopfsm
    ljmp COOL

; ---------------- IDLE ----------------
IDLE:
    clr SSR_PIN
    jnb KEY.1, goidlepress
    mov a, #00H
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_idle
    Set_Cursor(2,6)
    lcall LCD_SHOW_SK
    Set_Cursor(2,13)
	lcall LCD_SHOW_RF
	
	jnb BTN_MODE, modepress
	sjmp mainloopfsm
goidlepress:
	ljmp IDLEPRESSED

modepress:
	Wait_Milli_Seconds(#40)
	jnb BTN_MODE, modestilldown
	ljmp mainloopfsm
modestilldown:
	lcall Waitmode
	WriteCommand(#0x01)
	Wait_Milli_Seconds(#2)

mode1:
	Set_Cursor(1,1)
	Send_Constant_String(#SOAKTI)
	mov a, SOAK_TIME
	lcall LCD_Print3_A
	Set_Cursor(2,1)
	Send_Constant_String(#REFLOWTI)
	mov a, REFLOW_TIME
	lcall Hex_to_bcd_8bit
	lcall ?Display_BCD
	
	jnb BTN_SOAK_TI, soaktipress
	jnb BTN_REFLOW_TI, reflowtipress
	jnb BTN_MODE, modepress2
	sjmp mode1

soaktipress:
	Wait_Milli_Seconds(#40)
	jnb BTN_SOAK_TI, soakstilldown
	sjmp mode1
soakstilldown:
	lcall Waitsoak
	lcall soaktimeadjust
	sjmp mode1	

reflowtipress:
	Wait_Milli_Seconds(#40)
	jnb BTN_REFLOW_TI, reflowstilldown
	sjmp mode1
reflowstilldown:
	lcall Waitreflow
	lcall reflowtimeadjust
	sjmp mode1

modepress2:
	Wait_Milli_Seconds(#40)
	jnb BTN_MODE, modestilldown2
	ljmp mode1
modestilldown2:
	lcall Waitmode
	WriteCommand(#0x01)
	Wait_Milli_Seconds(#2)
	
mode2:
	Set_Cursor(1,1)
	Send_Constant_String(#SOAKT)
	Set_Cursor(1,11)
	lcall LCD_SHOW_SK

	Set_Cursor(2,1)
	Send_Constant_String(#REFLOWT)
	Set_Cursor(2,9)
	lcall LCD_SHOW_RF
	
	jnb BTN_STEMP, soaktpress
	jnb BTN_RTEMP, reflowtpress
	jnb BTN_MODE, modepresscheck
	sjmp mode2

modepresscheck:
	ljmp modepress3

soaktpress:
	Wait_Milli_Seconds(#40)
	jnb BTN_STEMP, soakstilldown1
	sjmp mode2
soakstilldown1:
	lcall Waitstemp
	lcall soaktempadjust
	sjmp mode2	

reflowtpress:
	Wait_Milli_Seconds(#40)
	jnb BTN_RTEMP, reflowstilldown1
	ljmp mode2
reflowstilldown1:
	lcall Waitrtemp
	lcall reflowtempadjust
	ljmp mode2

modepress3:
	Wait_Milli_Seconds(#40)
	jnb BTN_MODE, modestilldown3
	ljmp mode2
modestilldown3:
	lcall Waitmode
	WriteCommand(#0x01)
	Wait_Milli_Seconds(#2)		
    ljmp mainloopfsm

IDLEPRESSED:
    setb heater_enable
    mov State_seconds, #0
    mov FSM_state, #S_HEAT1
    mov a, #1
    lcall Beep_Request
    setb TR2
    WriteCommand(#0x01)
	Wait_Milli_Seconds(#2)
    ljmp mainloopfsm

; ---------------- PREHEAT1 ----------------
PREHEAT1:
    jnb heater_enable, HEAT1_to_IDLE
    jb flag_1s, heat1_inc
    sjmp heat1_keep

heat1_inc:
    clr flag_1s
    inc State_seconds
    mov a, State_seconds
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_all
    mov a, State_seconds
    cjne a, #60, heat1_keep

    mov a, TEMP_TOTAL+1
    clr c
    subb a, abort_cond+1
    jc lesser1
    jnz not_less1
    mov  a, TEMP_TOTAL+0
	clr  c
	subb a, abort_cond+0
	jc   lesser1
	sjmp not_less1
 
lesser1:
    mov State_seconds, #0
    mov FSM_state, #S_IDLE
    clr heater_enable
    
    ;clear lcd and wait
    WriteCommand(#0x01)
    Wait_Milli_Seconds(#2)
    
    mov a, #10
	lcall Beep_Request
    sjmp abortorstay

not_less1:
abortorstay:
    ljmp mainloopfsm

heat1_keep:
    setb SSR_PIN
    mov c, SSR_PIN
    mov LEDRA.0, c

    mov a, TEMP_TOTAL+1
    clr c
    subb a, th_preheat_soak+1
    jc not_greater1
    jnz greater1
    mov  a, TEMP_TOTAL+0
	clr  c
	subb a, th_preheat_soak+0
	jc   not_greater1
	jz   not_greater1
	sjmp greater1
    
greater1:
    mov State_seconds, #0
    mov FSM_state, #S_SOAK
    
    ;clear lcd and wait
    WriteCommand(#0x01)
    Wait_Milli_Seconds(#2)
    
    mov a, #1
    lcall Beep_Request
    sjmp HEAT1RETURN

not_greater1:
HEAT1RETURN:
    ljmp mainloopfsm

HEAT1_to_IDLE:
    clr heater_enable
    clr SSR_PIN
    mov FSM_state, #S_IDLE
    ljmp mainloopfsm

; ---------------- SOAK ----------------
SOAK:
    jnb heater_enable, SOAK_to_IDLE
    jb flag_1s, soak_inc
    sjmp soak_run

soak_inc:
    clr flag_1s
    inc State_seconds
    mov a, State_seconds
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_all

soak_run:
    jnb duty, soak_off
    setb SSR_PIN
    mov a, Count1ms+0
    cjne a, #low(400), soak_on
    mov a, Count1ms+1
    cjne a, #high(400), soak_on
soak_off:
    clr duty
    clr SSR_PIN
    sjmp soak_check
soak_on:
    setb duty
    setb SSR_PIN

soak_check:
    mov c, SSR_PIN
    mov LEDRA.0, c
    mov a, State_seconds
    cjne a, SOAK_TIME, SOAKRETURN    

    mov State_seconds, #0
    mov FSM_state, #S_HEAT2
    
    ;clear lcd and wait
    WriteCommand(#0x01)
    Wait_Milli_Seconds(#2)
    
    mov a, #1
    lcall Beep_Request

SOAKRETURN:
    ljmp mainloopfsm

SOAK_to_IDLE:
    clr heater_enable
    clr SSR_PIN
    mov FSM_state, #S_IDLE
    ljmp mainloopfsm

; ---------------- HEAT2 ----------------
HEAT2:
    jnb heater_enable, HEAT2_to_IDLE
    mov c, SSR_PIN
    mov LEDRA.0, c
    jb flag_1s, heat2_inc
    sjmp heat2_keep

heat2_inc:
    clr flag_1s
    inc State_seconds
    mov a, State_seconds
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_all

heat2_keep:
    setb SSR_PIN
    mov c, SSR_PIN
    mov LEDRA.0, c

    mov a, TEMP_TOTAL+1
    clr c
    subb a, th_ramp_reflow+1
    jc not_greater2
    jnz greater2
    mov  a, TEMP_TOTAL+0
	clr  c
	subb a, th_ramp_reflow+0
	jc   not_greater2
	jz   not_greater2
	sjmp greater2
    
greater2:
    mov State_seconds, #0
    mov FSM_state, #S_REFLOW
    
    ;clear lcd and wait
    WriteCommand(#0x01)
    Wait_Milli_Seconds(#2)
    
    mov a, #1
    lcall Beep_Request
    sjmp HEAT2RETURN

not_greater2:
HEAT2RETURN:
    ljmp mainloopfsm

HEAT2_to_IDLE:
    clr heater_enable
    clr SSR_PIN
    mov FSM_state, #S_IDLE
    ljmp mainloopfsm

; ---------------- REFLOW ----------------
REFLOW:
    jnb heater_enable, REFLOW_to_IDLE
    jb flag_1s, reflow_inc
    sjmp reflow_run

reflow_inc:
    clr flag_1s
    inc State_seconds
    mov a, State_seconds
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_all

reflow_run:
    jnb duty, reflow_off
    setb SSR_PIN
    mov a, Count1ms+0
    cjne a, #low(650), reflow_on
    mov a, Count1ms+1
    cjne a, #high(6500), reflow_on
reflow_off:
    clr duty
    clr SSR_PIN
    sjmp reflow_check
reflow_on:
    setb duty
    setb SSR_PIN

reflow_check:
    mov c, SSR_PIN
    mov LEDRA.0, c
    mov a, State_seconds
    cjne a, REFLOW_TIME, REFLOWRETURN     

    mov State_seconds, #0
    mov FSM_state, #S_COOL
    
    ;clear lcd and wait
    WriteCommand(#0x01)
    Wait_Milli_Seconds(#2)
    
    mov a, #1
    lcall Beep_Request

REFLOWRETURN:
    ljmp mainloopfsm

REFLOW_to_IDLE:
    clr heater_enable
    clr SSR_PIN
    mov FSM_state, #S_IDLE
    ljmp mainloopfsm

; ---------------- COOL ----------------
COOL:
    jnb heater_enable, COOL_to_IDLE
    jb flag_1s, cool_inc
    sjmp cool_keep

cool_inc:
    clr flag_1s
    inc State_seconds
    mov a, State_seconds
    lcall Hex_to_bcd_8bit
    lcall Display_BCD_7_Seg_HEX10
    lcall LCD_show_all

cool_keep:
    clr SSR_PIN
    mov c, SSR_PIN
    mov LEDRA.0, c

    mov a, TEMP_TOTAL+1
    clr c
    subb a, th_cool_idle+1
    jc lesser
    jnz not_less
    mov  a, TEMP_TOTAL+0
	clr  c
	subb a, th_cool_idle+0
	jc   lesser
	sjmp not_less
 
lesser:
    mov State_seconds, #0
    mov FSM_state, #S_IDLE
    mov a, #5
    lcall Beep_Request
    sjmp COOLRETURN

not_less:
COOLRETURN:
    ljmp mainloopfsm

COOL_to_IDLE:
    clr heater_enable
    clr SSR_PIN
    mov FSM_state, #S_IDLE
    WriteCommand(#0x01)
	Wait_Milli_Seconds(#2)
    ljmp mainloopfsm

END
