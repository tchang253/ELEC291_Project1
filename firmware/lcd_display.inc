; lcd_display.inc - display functions for reflow oven LCD
; shows temp, state, elapsed time, and profile params on 16x2 LCD
;
; include this AFTER math32.asm or math32.inc and LCD_4bit_DE10Lite.inc in code
;
; your main file needs these variables:
;   TEMP_TOTAL (2 bytes), State_seconds (1 byte), FSM_state (1 byte)
;   SOAK_TEMP, SOAK_TIME, REFLOW_TEMP, REFLOW_TIME (1 byte each)
;   x (4 bytes), bcd (5 bytes) - for math32

;                       1234567890123456
msg_ready:       db 'Ready  Temp:', 0
msg_abort:       db '** ABORT **     ', 0
msg_abort2:      db 'Safety stopped! ', 0
msg_done:        db '** DONE! **     ', 0
msg_done2:       db 'Remove PCB      ', 0

;-----------------------------------
; show everything during reflow
; line 1: ###C STATENAME ###s
; line 2: Sk:150/60 Rf:220
; call this once per second
;-----------------------------------
LCD_show_all:
	Set_Cursor(1, 1)
	lcall LCD_show_temp
	Display_char(#' ')
	lcall LCD_show_state
	lcall LCD_show_time
	
	Set_Cursor(2, 1)
	lcall LCD_show_params
	ret

;-----------------------------------
; idle screen
; line 1: "Ready  Temp:###C"
; line 2: Sk:150/60 Rf:220
;-----------------------------------
LCD_show_idle:
	Set_Cursor(1, 1)
	Send_Constant_String(#msg_ready)
	lcall LCD_show_temp
	
	Set_Cursor(2, 1)
	lcall LCD_show_params
	ret

;-----------------------------------
; display temp as "###C" at cursor
; note: changes x and bcd
;-----------------------------------
LCD_show_temp:
	; convert to BCD so we can display digits
	mov x+0, TEMP_TOTAL
	mov x+1, TEMP_TOTAL+1
	mov x+2, #0
	mov x+3, #0
	lcall hex2bcd
	
	; hundreds digit (lower nibble of bcd+1)
	mov a, bcd+1
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData

	; tens digit (upper nibble of bcd+0)
	mov a, bcd+0
	swap a
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData

	; ones digit (lower nibble of bcd+0)
	mov a, bcd+0
	anl a, #0FH
	orl a, #'0'
	lcall ?WriteData
	
	Display_char(#'C')
	ret

;-----------------------------------
; show state name (8 chars)
;-----------------------------------
LCD_show_state:
	mov a, FSM_state
	cjne a, #0, chk_st1
	; IDLE
	Display_char(#'I')
	Display_char(#'D')
	Display_char(#'L')
	Display_char(#'E')
	Display_char(#' ')
	Display_char(#' ')
	Display_char(#' ')
	Display_char(#' ')
	ret
chk_st1:
	cjne a, #1, chk_st2
	; RAMP_SK
	Display_char(#'R')
	Display_char(#'A')
	Display_char(#'M')
	Display_char(#'P')
	Display_char(#'_')
	Display_char(#'S')
	Display_char(#'K')
	Display_char(#' ')
	ret
chk_st2:
	cjne a, #2, chk_st3
	; SOAK
	Display_char(#'S')
	Display_char(#'O')
	Display_char(#'A')
	Display_char(#'K')
	Display_char(#' ')
	Display_char(#' ')
	Display_char(#' ')
	Display_char(#' ')
	ret
chk_st3:
	cjne a, #3, chk_st4
	; RAMP_RF
	Display_char(#'R')
	Display_char(#'A')
	Display_char(#'M')
	Display_char(#'P')
	Display_char(#'_')
	Display_char(#'R')
	Display_char(#'F')
	Display_char(#' ')
	ret
chk_st4:
	cjne a, #4, chk_st5
	; REFLOW
	Display_char(#'R')
	Display_char(#'E')
	Display_char(#'F')
	Display_char(#'L')
	Display_char(#'O')
	Display_char(#'W')
	Display_char(#' ')
	Display_char(#' ')
	ret
chk_st5:
	; COOLING (state 5, or anything else)
	Display_char(#'C')
	Display_char(#'O')
	Display_char(#'O')
	Display_char(#'L')
	Display_char(#'I')
	Display_char(#'N')
	Display_char(#'G')
	Display_char(#' ')
	ret

;-----------------------------------
; display elapsed seconds as "###s"
; reads State_seconds (0-255)
;-----------------------------------
LCD_show_time:
	push b
	
	mov a, State_seconds
	mov b, #100
	div ab
	orl a, #'0'
	lcall ?WriteData           ; hundreds
	
	mov a, b
	mov b, #10
	div ab
	orl a, #'0'
	lcall ?WriteData           ; tens
	
	mov a, b
	orl a, #'0'
	lcall ?WriteData           ; ones
	
	Display_char(#'s')
	
	pop b
	ret

;-----------------------------------
; show profile params
; "Sk:150/60 Rf:220 "
;-----------------------------------
LCD_show_params:
	push b
	
	Display_char(#'S')
	Display_char(#'k')
	Display_char(#':')
	
	; soak temp (3 digits)
	mov a, SOAK_TEMP
	lcall lcd_write_3dig
	
	Display_char(#'/')
	
	; soak time 2 digits
	mov a, SOAK_TIME
	mov b, #10
	div ab
	orl a, #'0'
	lcall ?WriteData
	mov a, b
	orl a, #'0'
	lcall ?WriteData
	
	Display_char(#' ')
	Display_char(#'R')
	Display_char(#'f')
	Display_char(#':')
	
	; reflow temp (3 digits)
	mov a, REFLOW_TEMP
	lcall lcd_write_3dig
	Display_char(#' ')
	
	pop b
	ret

;-----------------------------------
; error screen
;-----------------------------------
LCD_show_error:
	Set_Cursor(1, 1)
	Send_Constant_String(#msg_abort)
	Set_Cursor(2, 1)
	Send_Constant_String(#msg_abort2)
	ret

;-----------------------------------
; done screen
;-----------------------------------
LCD_show_done:
	Set_Cursor(1, 1)
	Send_Constant_String(#msg_done)
	Set_Cursor(2, 1)
	Send_Constant_String(#msg_done2)
	ret

;-----------------------------------
; write value in A as 3 digits
; max 255
;-----------------------------------
lcd_write_3dig:
	push b
	mov b, #100
	div ab
	orl a, #'0'
	lcall ?WriteData
	mov a, b
	mov b, #10
	div ab
	orl a, #'0'
	lcall ?WriteData
	mov a, b
	orl a, #'0'
	lcall ?WriteData
	pop b
	ret
