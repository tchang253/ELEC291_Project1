# Integration Guide: Non-Blocking ADC for Reflow Oven

**Purpose:** This guide explains how to integrate the valid temperature reading logic into your Reflow FSM without "blocking" or freezing the controller.

## 1. The Concept: Background vs Foreground

- **Foreground (Your FSM):** This is your main loop. It runs thousands of times per second, checking buttons, updating the display, and deciding if it's time to switch from "Soak" to "Reflow".
- **Background (ADC Service):** Reading the temperature takes time (~16ms per sample). If we wait for it, your FSM freezes. Instead, we use a "Service" function that does a tiny bit of work each loop (microseconds) and returns immediately.

## 2. Integration Steps

### Step A: Add Variables
Copy the variable declarations from `non_blocking_adc.asm` into your project's `DSEG` area (usually after your other variables).

### Step B: Update Timer0 ISR
Your `Timer0_ISR` handles the 100Hz PWM. You need to add **3 lines** to let it also drive the ADC timing:

```asm
Timer0_ISR:
    ; ... (Your existing PWM code) ...

    ; -- ADD THIS BLOCK --
    ; Decrement ADC Timer if it's running
    mov a, ADC_Timer
    jz ADC_Timer_Done
    dec ADC_Timer
ADC_Timer_Done:
    ; --------------------

    ; ... (Rest of ISR) ...
    reti
```

### Step C: Include the File
At the end of your main `.asm` file (before `END`), include the module:
```asm
$include(non_blocking_adc.asm)
```
*(Or just copy-paste the functions `Init_ADC_Avg` and `Service_ADC_Avg` into your file if you prefer).*

### Step D: The Main Loop (Your FSM)

Initialize the system once at startup:
```asm
    lcall Init_ADC_Avg
    ; Start the first reading (Channel 0 = LM335)
    mov a, #0
    lcall Start_ADC_Read
```

Then, update your `forever` loop structure:

```asm
forever:
    ; 1. SERVICE THE ADC (Background Task)
    ; This function checks if it's time to read/reset the ADC.
    ; It returns IMMEDIATELY if not ready.
    lcall Service_ADC_Avg

    ; 2. CHECK IF READING COMPLETED (Optional)
    ; If ADC_State == 0, a fresh reading is ready in TEMP_TOTAL.
    mov a, ADC_State
    jnz Run_FSM
    
    ; -- Reading Done! --
    ; Restart the ADC for the next reading (Channel 0 or 1)
    mov a, #0 
    lcall Start_ADC_Read

Run_FSM:
    ; 3. RUN YOUR FSM (Foreground Task)
    ; Use TEMP_TOTAL variable directly. It is always up-to-date.
    
    mov a, FSM_State
    cjne a, #1, Check_State_2
    sjmp State_Ramp_To_Soak
Check_State_2:
    ; ... other states ...

State_Ramp_To_Soak:
    ; Example: Go to Soak if Temp > 150.0 C
    ; TEMP_TOTAL is 16-bit (High/Low bytes)
    
    ; Compare High Byte first
    mov a, TEMP_TOTAL+1
    cjne a, #high(1500), Check_Low
    sjmp Check_Low_Equal
Check_Low:
    jc Stay_In_Ramp       ; If Temp < 1500, Stay
    sjmp Go_To_Soak       ; If Temp > 1500, Go
Check_Low_Equal:
    mov a, TEMP_TOTAL
    cjne a, #low(1500), Compare_Low
    sjmp Go_To_Soak
Compare_Low:
    jc Stay_In_Ramp
    
Go_To_Soak:
    mov FSM_State, #2     ; Switch State
    
Stay_In_Ramp:
    sjmp Loop_End         ; Done for this loop

Loop_End:
    sjmp forever
```
