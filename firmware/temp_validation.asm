; reflow_controller.asm - Combined Temperature + PWM Controller
; Combines temp_reader_final.asm and ssr_pwm_final.asm
; Timer0 = PWM, Timer2 = Serial baud rate
;
$NOLIST
$MODMAX10
$LIST

;-------------------------------------------------
; Constants
;-------------------------------------------------
CLK           EQU 33333333
BAUD          EQU 115200
T2LOAD        EQU 65536-(CLK/(32*BAUD))

TIMER0_RATE   EQU 100      ; 100Hz = 10ms tick >> 1Hz PWM (1 sec period)
TIMER0_RELOAD EQU ((65536-(CLK/(12*TIMER0_RATE))))

SSR_PIN       EQU P0.3

; ADC channel assignments 
CH_LM335      EQU 0    ; LM335 cold junction sensor  
CH_OP07       EQU 1    ; OP07 thermocouple amplifier

; Calibration values - UPDATE BASED ON OUR MEASUREMENTS
VCC_MV        EQU 48650    ; VCC in 0.1mV units (4.865V = 48650)
CONST_TH      EQU 81       ; For Gain=302: 1000000/(41*302)=81



;-------------------------------------------------
; Interrupt Vectors
;-------------------------------------------------
org 0x0000
    ljmp main

org 0x000B              ; Timer0 interrupt vector
    ljmp Timer0_ISR

;-------------------------------------------------
; Data Segment
;-------------------------------------------------
dseg at 0x30
; Math variables
x:            ds 4
y:            ds 4
bcd:          ds 5

; PWM variables
PWM_counter:  ds 1
PWM_DUTY:     ds 1

; ADC readings
ADC_LM335_L:  ds 1
ADC_LM335_H:  ds 1
ADC_OP07_L:   ds 1
ADC_OP07_H:   ds 1

; Temperature values
TEMP_COLD:    ds 2    ; Cold junction in 0.1 C
TEMP_HOT:     ds 2    ; Hot junction in 0.1 C  
TEMP_TOTAL:   ds 2    ; Total temp in C

bseg
mf:           dbit 1


cseg

;--------------------------------------------------
; LIBRARIES AND INCLUDES
;--------------------------------------------------
$include(math32.asm)

;--------------------------------------------------
; SERIAL PORT FUNCTIONS
;--------------------------------------------------
InitSerialPort:
    clr TR2
    mov T2CON, #30H
    mov RCAP2H, #high(T2LOAD)
    mov RCAP2L, #low(T2LOAD)
    setb TR2
    mov SCON, #52H
    ret

putchar:
    jnb TI, putchar
    clr TI
    mov SBUF, a
    ret

SendString:
    clr a
    movc a, @a+dptr
    jz SSDone
    lcall putchar
    inc dptr
    sjmp SendString
SSDone:
    ret




;--------------------------------------------------
; TIMER0 PWM ISR & init
;--------------------------------------------------


Timer0_Init:
    mov a, TMOD
    anl a, #0xF0
    orl a, #0x01
    mov TMOD, a
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    setb ET0
    setb TR0
    ret

Timer0_ISR:
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    
    push acc
    push psw
    
    inc PWM_counter
    mov a, PWM_counter
    cjne a, #100, Check_Duty
    mov PWM_counter, #0
    
Check_Duty:
    mov a, PWM_counter
    clr c
    subb a, PWM_DUTY
    jnc SSR_Off_ISR
    setb SSR_PIN
    sjmp ISR_Done
    
SSR_Off_ISR:
    clr SSR_PIN
    
ISR_Done:
    ; Update LED0 
    mov c, SSR_PIN
    mov LEDRA.0, c
    
    pop psw
    pop acc
    reti

;--------------------------------------------------
; PWM CONTROL FUNCTIONS
;--------------------------------------------------

Set_Power:
    push acc
    clr c
    subb a, #101
    pop acc
    jc Power_OK
    mov a, #100
Power_OK:
    mov PWM_DUTY, a
    ret

Power_Off:
    mov a, #0
    lcall Set_Power
    clr SSR_PIN
    ret

;--------------------------------------------------
; DELAY AND ADC FUNCTIONS
;--------------------------------------------------
; 7-seg lookup
myLUT:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99
    DB 0x92, 0x82, 0xF8, 0x80, 0x90
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E

Wait50ms:
    mov R0, #30
Wait50ms_L3:
    mov R1, #74
Wait50ms_L2:
    mov R2, #250
Wait50ms_L1:
    djnz R2, Wait50ms_L1
    djnz R1, Wait50ms_L2
    djnz R0, Wait50ms_L3
    ret

Read_ADC:
    push acc
    orl a, #0x80
    mov ADC_C, a
    lcall Wait50ms
    pop acc
    mov ADC_C, a
    lcall Wait50ms
    mov R0, ADC_L
    mov R1, ADC_H
    ret

;--------------------------------------------------
; TEMPERATURE CALCULATIONS
;--------------------------------------------------
Calc_Cold_Junction:
    mov x+0, ADC_LM335_L
    mov x+1, ADC_LM335_H
    mov x+2, #0
    mov x+3, #0
    Load_y(VCC_MV)
    lcall mul32
    Load_y(4095)
    lcall div32
    Load_y(27300)
    lcall sub32
    mov TEMP_COLD, x+0
    mov TEMP_COLD+1, x+1
    ret

Calc_Hot_Junction:
    mov x+0, ADC_OP07_L
    mov x+1, ADC_OP07_H
    mov x+2, #0
    mov x+3, #0
    Load_y(CONST_TH)
    lcall mul32
    Load_y(1000)
    lcall div32
    Load_y(10)
    lcall mul32
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
    Load_y(10)
    lcall div32
    mov TEMP_TOTAL, x+0
    mov TEMP_TOTAL+1, x+1
    ret

;-------------------------------------------------
; DISPLAY FUNCTIONS (Temp Hex 5-3, Power Hex 1-0)
;-------------------------------------------------
Display_Temp_7seg:
    mov x+0, TEMP_TOTAL
    mov x+1, TEMP_TOTAL+1
    mov x+2, #0
    mov x+3, #0
    lcall hex2bcd
    
    mov dptr, #myLUT
    
    mov a, bcd+1
    swap a
    anl a, #0FH
    movc a, @a+dptr
    mov HEX5, a      ; Hundreds on HEX5
    
    mov a, bcd+1
    anl a, #0FH
    movc a, @a+dptr
    anl a, #0x7F     ; Turn on decimal point on HEX4
    mov HEX4, a      
    
    mov a, bcd+0
    swap a
    anl a, #0FH
    movc a, @a+dptr
    mov HEX3, a      ; Ones on HEX3
    ret

Display_Power_7seg:
    push acc
    mov dptr, #myLUT
    mov a, PWM_DUTY
    mov b, #10
    div ab
    movc a, @a+dptr
    mov HEX1, a
    mov a, b
    movc a, @a+dptr
    mov HEX0, a
    pop acc
    ret

Send_Temp_Serial:
    mov x+0, TEMP_TOTAL
    mov x+1, TEMP_TOTAL+1
    mov x+2, #0
    mov x+3, #0
    lcall hex2bcd
    
    mov a, bcd+1
    swap a
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    
    mov a, bcd+1
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    
    mov a, bcd+0
    swap a
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    
    mov a, bcd+0
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    
    mov a, #'\r'
    lcall putchar
    mov a, #'\n'
    lcall putchar
    ret

;-------------------------------------------------
; EMERGENCY STOP
;-------------------------------------------------
Check_Emergency:
    jb KEY.0, No_Emergency
    ljmp Emergency_Stop
No_Emergency:
    ret

Emergency_Stop:
    clr TR0
    clr EA
    mov PWM_DUTY, #0
    clr SSR_PIN
    
    mov LEDRA, #0xFF
Emergency_Freeze:
    sjmp Emergency_Freeze

;-------------------------------------------------
; MAIN PROGRAM
;-------------------------------------------------
Msg_Start: db '\r\nReflow Controller\r\n', 0

main:
    mov SP, #0x7F
    clr a
    mov LEDRA, a
    mov LEDRB, a
    
    ; Configure SSR pin as output
    orl P0MOD, #00001000b
    clr SSR_PIN
    
    ; Init PWM
    mov PWM_counter, #0
    mov PWM_DUTY, #0
    
    ; Init serial
    lcall InitSerialPort
    mov dptr, #Msg_Start
    lcall SendString
    
    ; Clear 7-seg
    mov HEX0, #0xFF
    mov HEX1, #0xFF
    mov HEX2, #0xFF
    mov HEX3, #0xFF
    mov HEX4, #0xFF
    mov HEX5, #0xFF
    
    ; Reset ADC
    mov ADC_C, #0x80
    lcall Wait50ms
    
    ; Init Timer0 for PWM
    lcall Timer0_Init
    setb EA ;enable global interrupts
    
forever:
    cpl LEDRA.7          ; Toggle LED7 to show running
    
    ; Read switches for power (SW0-SW6)
    mov a, SWA
    anl a, #0x7F
    push acc
    clr c
    subb a, #101
    pop acc
    jc Apply_Power
    mov a, #100
    
Apply_Power:
    lcall Set_Power
    
    ; Read LM335 (cold junction)
    mov a, #CH_LM335
    lcall Read_ADC
    mov ADC_LM335_L, R0
    mov ADC_LM335_H, R1
    
    ; Read OP07 (thermocouple)
    mov a, #CH_OP07
    lcall Read_ADC
    mov ADC_OP07_L, R0
    mov ADC_OP07_H, R1
    
    ; Calculate temperatures
    lcall Calc_Cold_Junction
    lcall Calc_Hot_Junction
    lcall Calc_Total_Temp
    
    ; Display Temperature and Power
    lcall Display_Temp_7seg
    lcall Display_Power_7seg
    
    ; Send temp via serial
    lcall Send_Temp_Serial
    
    ; Show SSR state on LED0
    mov c, SSR_PIN
    mov LEDRA.0, c
    
    ; Check emergency stop
    lcall Check_Emergency
    
    ; 1 second delay for Python script
    ;mov R7, #20
;delay_loop:
    ;lcall Wait50ms
    ;djnz R7, delay_loop
    
    ljmp forever
    
END
