;-------------------------------------------------------------
; NON-BLOCKING ADC AVERAGING MODULE
;-------------------------------------------------------------
; Instructions for integration:
; 1. Add the variables in DSEG to your project's DSEG area.
; 2. Add the Timer0 ISR code to your existing Timer0 ISR (or create one).
; 3. Call Init_ADC_Avg in your setup code.
; 4. Call Service_ADC_Avg inside your main loop.
; 5. Use Start_ADC_Read(channel) to begin a reading.
; 6. Check if ADC_State == 0 to know when reading is done.
;-------------------------------------------------------------

;-------------------------------------------------
; 1. VARIABLES (Add to DSEG)
;-------------------------------------------------
; dseg at 0x30 ...
;
; ADC_State:    ds 1    ; 0=Idle, 1=Reset, 2=Convert
; ADC_Timer:    ds 1    ; Timer for delays (decremented by ISR)
; ADC_Channel:  ds 1    ; Current channel being read (0=LM335, 1=OP07)
; ADC_Count:    ds 1    ; Sample counter (0-16)
; ADC_Sum_L:    ds 1    ; 16-bit Sum Low
; ADC_Sum_H:    ds 1    ; 16-bit Sum High
;
; ; -- Final Results (Read these in your main FSM) --
; ADC_LM335_L:  ds 1    ; Averaged Result for Cold Junction
; ADC_LM335_H:  ds 1
; ADC_OP07_L:   ds 1    ; Averaged Result for Thermocouple
; ADC_OP07_H:   ds 1

;-------------------------------------------------
; 2. TIMER0 ISR LOGIC (Add to your ISR)
;-------------------------------------------------
; Timer0_ISR:
;     ... (save context: push acc, push psw) ...
;
;     ; -- ADC Timer Update --
;     ; Decrement ADC_Timer if it is non-zero.
;     ; This creates the time-base for the ADC FSM without blocking.
;     mov a, ADC_Timer
;     jz ADC_Timer_Done
;     dec ADC_Timer
; ADC_Timer_Done:
;
;     ... (restore context: pop psw, pop acc) ...
;     reti

;=============================================================
; 3. FUNCTIONS (Include in CSEG)
;=============================================================

;-------------------------------------------------
; Init_ADC_Avg
; Purpose: Initialize all ADC variables to safe defaults.
; Call this once at startup.
;-------------------------------------------------

; Initialize variables
Init_ADC_Avg:
    mov ADC_State, #0
    mov ADC_Timer, #0
    mov ADC_Count, #0
    mov ADC_Sum_L, #0
    mov ADC_Sum_H, #0
    ret

; Start a non-blocking read for channel in A
; Example: mov a, #0 -> lcall Start_ADC_Read
Start_ADC_Read:
    mov ADC_Channel, a
    mov ADC_State, #1     ; Go to Reset state
    mov ADC_Count, #16    ; 16 samples
    mov ADC_Sum_L, #0
    mov ADC_Sum_H, #0
    
    ; Reset ADC
    orl a, #0x80
    mov ADC_C, a
    mov ADC_Timer, #1     ; Wait 1 tick (10ms)
    ret

; Service Routine - Call this in your 'forever' loop
Service_ADC_Avg:
    mov a, ADC_State
    jz ADC_Check_Return   ; If 0, do nothing
    cjne a, #1, ADC_Check_Convert
    sjmp ADC_Wait_Reset
ADC_Check_Convert:
    cjne a, #2, ADC_Check_Return
    sjmp ADC_Wait_Convert
ADC_Check_Return:
    ret

; -- State 1: Waiting for Reset Pulse --
ADC_Wait_Reset:
    mov a, ADC_Timer
    jnz ADC_Check_Return  ; Timer not done
    
    ; Reset done, start conversion
    mov a, ADC_Channel
    mov ADC_C, a          ; Clear reset bit
    mov ADC_Timer, #1     ; Wait 1 tick (10ms)
    mov ADC_State, #2     ; Go to Convert state
    ret

; -- State 2: Waiting for Conversion Result --
ADC_Wait_Convert:
    mov a, ADC_Timer
    jnz ADC_Check_Return  ; Timer not done
    
    ; Conversion done, accumulator add
    mov a, ADC_L
    add a, ADC_Sum_L
    mov ADC_Sum_L, a
    mov a, ADC_H
    addc a, ADC_Sum_H
    mov ADC_Sum_H, a
    
    ; Check if we have collected all 16 samples
    djnz ADC_Count, ADC_Next_Sample
    
    ; -- All 16 Samples Collected --
    ; Calculate Average: Sum / 16 (Right Shift 4 times)
    mov R6, #4
    mov R4, ADC_Sum_L
    mov R5, ADC_Sum_H
Shift_Right_Loop:
    clr c
    mov a, R5
    rrc a
    mov R5, a
    mov a, R4
    rrc a
    mov R4, a
    djnz R6, Shift_Right_Loop
    
    ; Store Final Averaged Result
    mov a, ADC_Channel
    cjne a, #0, Store_CH1 ; Check if Ch0 (LM335)
    mov ADC_LM335_L, R4
    mov ADC_LM335_H, R5
    sjmp ADC_Finish
Store_CH1:
    mov ADC_OP07_L, R4
    mov ADC_OP07_H, R5
    
ADC_Finish:
    mov ADC_State, #0     ; Done -> Go to Idle State
    ret

; -- Helper: Prepare Next Sample logic --
ADC_Next_Sample:
    ; Start the next sample's reset sequence
    mov a, ADC_Channel
    orl a, #0x80
    mov ADC_C, a
    mov ADC_Timer, #1     ; Set Timer for 1 tick
    mov ADC_State, #1     ; Back to State 1 (Reset)
    ret
