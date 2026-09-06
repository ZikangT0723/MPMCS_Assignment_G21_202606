; ====================================================================
; MCU 2: TOPIC 2 - DISPLAY CONTROLLER (LCD + local scroll keys)
; Receives screen commands from MCU 1 (Operation) via UART 9600 baud.
; Protocol:
;   0xFF        = show welcome marquee
;   0xFE        = clear both lines, cursor home
;   0xFC        = erase last character
;   0xFB <m><o> = erase operator (mode, operator index)
;   0xFD <e>    = show error code e on line 2
;   0xF8        = entry screen: hints on line 2, cursor line 1
;   0xF6        = logic entry screen: hints on line 2, cursor line 1
;   0xFA <f><hi><lo> = show value on line 2 (for bin8 logic, hi=bit width)
;                       f=4 positive decimal, f=5 negative decimal magnitude
;   0xF9 <g>    = print gate name g at cursor
;   0xE0..0xE3  = show menu screens 0..3
;   ASCII       = write character at cursor
; Pins: P2.0-P2.7=LCD D0-D7 (P2 has internal pull-ups, no resistors needed)
;       P3.6=RS, P3.7=E, LCD RW tied to GND on the board
;       P3.1=TX (to MCU1 RX), P3.0=RX (from MCU1 TX)
;       P3.2=SCROLL L, P3.3=SCROLL R (keypad is MCU1-only)
;       P3.5 is unused; leave it disconnected or pull it up with 10 kohm.
; Scroll buttons are active while entering or reviewing an equation, and only
; within the width of the equation (no empty columns at either end).
; ====================================================================
RS        EQU P3.6
E         EQU P3.7
LCD_DATA  EQU P2
SCROLL_L  EQU P3.2
SCROLL_R  EQU P3.3

; HD44780 datasheet: 18H = shift display LEFT, 1CH = shift display RIGHT.
; If your virtual LCD shows the opposite direction, swap these two values.
SHIFT_LEFT  EQU 18H
SHIFT_RIGHT EQU 1CH

ORG 0000H
    LJMP MAIN

ORG 0030H
MAIN:
    MOV SP, #6FH
    MOV P1, #0FFH
    CLR P1.0             ; MCU8051IDE virtual LCD R/W: hold low for write mode
    MOV P3, #0FFH
    MOV TMOD, #20H
    MOV TH1, #0FDH
    MOV SCON, #50H
    SETB TR1
    MOV 4EH, #0
    MOV 33H, #0        ; result-state flag (1 = result/error on screen)
    MOV 34H, #0        ; display shift counter (0 = equation at home)
    MOV 36H, #0        ; entry-state flag (1 = equation is being entered)
    LCALL LCD_INIT
    LCALL LCD_LOAD_CGRAM
    LCALL SHOW_WELCOME        ; play the welcome automatically at boot
    MOV A, #0                 ; then draw the main menu locally,
    LCALL SHOW_SCREEN         ; no UART command needed for either

MAIN_LOOP:
    ; Keypad matrix lives on MCU 1 only; check the two local scroll keys.
    SJMP MD_CHECK_SCROLL_L

MD_CHECK_SCROLL_L:
    JB SCROLL_L, MD_CHECK_SCROLL_R
    LCALL DELAY_2MS
    JB SCROLL_L, MD_CHECK_SCROLL_R
    MOV A, 33H
    JNZ MD_SCROLL_L_WINDOW    ; If a math result is out, use normal display shift
    MOV A, 36H
    JNZ MD_SCROLL_L_WINDOW    ; Also permit manual scrolling during equation entry
    
    ; Logic menu navigation: P3.2 advances from page 1 to page 2.
    MOV A, R4                 ; Check current screen index
    CJNE A, #2, MD_CHECK_SCROLL_R ; Only act on Logic Page 1 (Index 2)
    MOV A, #3                 ; Switch to Logic Page 2 (Index 3)
    LCALL SHOW_SCREEN
    MOV R4, #3                ; Update tracker state locally
    SJMP MD_UART

MD_SCROLL_L_WINDOW:
    LCALL CAN_SHIFT_LEFT
    JZ MD_CHECK_SCROLL_R
    MOV A, #SHIFT_LEFT
    LCALL LCD_CMD
    INC 34H
    SJMP MD_UART

MD_CHECK_SCROLL_R:
    JB SCROLL_R, MD_UART
    LCALL DELAY_2MS
    JB SCROLL_R, MD_UART
    MOV A, 33H
    JNZ MD_SCROLL_R_WINDOW    ; If a math result is out, use normal display shift
    MOV A, 36H
    JNZ MD_SCROLL_R_WINDOW    ; Also permit scrolling back during equation entry
    
    ; Logic menu navigation: P3.3 returns from page 2 to page 1.
    MOV A, R4                 ; Check current screen index
    CJNE A, #3, MD_UART       ; Only act on Logic Page 2 (Index 3)
    MOV A, #2                 ; Switch back to Logic Page 1 (Index 2)
    LCALL SHOW_SCREEN
    MOV R4, #2                ; Update tracker state locally
    SJMP MD_UART
    
MD_SCROLL_R_WINDOW:
    LCALL CAN_SHIFT_RIGHT
    JZ MD_UART
    MOV A, #SHIFT_RIGHT
    LCALL LCD_CMD
    DEC 34H

    
MU_IDLE:
    LJMP MAIN_LOOP

MD_UART:
    ; 3. Process commands from MCU 1
    JNB RI, MU_IDLE
    CLR RI
    MOV A, SBUF
    CJNE A, #0FFH, MU_CLR
    MOV 33H, #0
    MOV 34H, #0
    MOV 36H, #0
    MOV A, #0            ; main menu (screen index 0) drawn locally,
    LCALL SHOW_SCREEN    ; never depends on a UART command arriving
    LJMP MAIN_LOOP
MU_CLR:
    CJNE A, #0FEH, MU_BS
    LCALL CLEAR_BOTH_LINES
    MOV 4EH, #0
    MOV 33H, #0
    MOV 34H, #0
    MOV 36H, #0
    LJMP MAIN_LOOP
MU_BS:
    CJNE A, #0FCH, MU_ERASE_OP
    LCALL ERASE_LAST_CHAR
    LJMP MAIN_LOOP
MU_ERASE_OP:
    CJNE A, #0FBH, MU_ERR
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A                ; undo +1 encoding
    MOV 30H, A
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A
    MOV 47H, A
    LCALL ERASE_OPERATOR
    LJMP MAIN_LOOP
MU_RX_ABORT:
    LJMP MAIN_LOOP
MU_ERR:
    CJNE A, #0FDH, MU_ENTRY
    LCALL WAIT_RX
    JC MU_RX_ABORT
    MOV 5DH, A
    LCALL DISPLAY_ERROR
    MOV 33H, #1
    MOV 34H, #0
    MOV 36H, #0
    LJMP MAIN_LOOP
MU_ENTRY:
    CJNE A, #0F8H, MU_ENTRY_L
    MOV 5CH, #0
    LCALL ENTRY_SCREEN
    MOV 33H, #0
    MOV 34H, #0
    MOV 36H, #1
    LJMP MAIN_LOOP
MU_ENTRY_L:
    CJNE A, #0F6H, MU_VALUE
    MOV 5CH, #0
    LCALL ENTRY_SCREEN_L
    MOV 33H, #0
    MOV 34H, #0
    MOV 36H, #1
    LJMP MAIN_LOOP
MU_VALUE:
    CJNE A, #0FAH, MU_GATE
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A                ; undo +1 encoding
    MOV 35H, A
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A
    MOV 41H, A
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A
    MOV 40H, A
    LCALL SHOW_VALUE
    MOV 33H, #1
    MOV 34H, #0
    MOV 36H, #0
    LJMP MAIN_LOOP
MU_GATE:
    CJNE A, #0F9H, MU_SCR
    LCALL WAIT_RX
    JC MU_RX_ABORT
    DEC A                ; undo +1 encoding
    MOV 47H, A
    LCALL PRINT_GATE
    LCALL AUTO_SCROLL_TO_END
    LJMP MAIN_LOOP

MU_SCR:
    MOV B, A                  ; Save copy of character
    CLR C
    SUBB A, #0E0H             ; Check if byte is 0xE0 or higher (Commands live here)
    JC MU_ASCII               ; SAFETY Shield: Lower bytes (0x31, 0x23) go straight to text typing!
    
    MOV A, B                  ; Restore byte to check specific menus
    CJNE A, #0E0H, MUS_1
    MOV A, #0                 ; 0xE0 triggers Main Menu (Screen 0) with no restart animation!
    LCALL SHOW_SCREEN
    SJMP MUS_X
MUS_1:
    CJNE A, #0E1H, MUS_2
    MOV A, #1                 ; 0xE1 triggers Math Menu (Screen 1)
    LCALL SHOW_SCREEN
    SJMP MUS_X
MUS_2:
    CJNE A, #0E2H, MUS_3
    MOV A, #2                 ; 0xE2 triggers Logic Menu (Screen 2)
    LCALL SHOW_SCREEN
    SJMP MUS_X
MUS_3:
    CJNE A, #0E3H, MUS_X      
    MOV A, #3                 ; 0xE3 triggers Logic Page 2 (Screen 3)
    LCALL SHOW_SCREEN
MUS_X:
    MOV 33H, #0               
    MOV 34H, #0               
    MOV 36H, #0
    LJMP MAIN_LOOP

MU_ASCII:
    MOV A, B
MU_WRITE:
    CJNE A, #3DH, MU_WRITE_CHAR
    ; '=' marks the completed equation. Write it at the logical end, then
    ; return the display window to column 1 so the full equation can be
    ; reviewed from its beginning with the manual scroll buttons.
    LCALL LCD_DATA_WRITE
    INC 4EH
    LCALL RETURN_SHIFT_HOME
    LJMP MAIN_LOOP
MU_WRITE_CHAR:
    ; Move the visible window first when the next character would be
    ; written beyond column 16. Some simulated HD44780 models do not
    ; redraw a hidden DDRAM character reliably when shifted afterwards.
    LCALL PREPARE_NEXT_CHAR
    MOV A, B                ; restore the received ASCII byte after shift calculations
    LCALL LCD_DATA_WRITE
    INC 4EH
    LJMP MAIN_LOOP

; CAN_SHIFT_LEFT: allowed only while shift counter < (equation length - 16)
; Returns A = 1 allowed, A = 0 blocked.
CAN_SHIFT_LEFT:
    MOV A, 4EH
    CLR C
    SUBB A, #16
    JNC CSL_MAX
    MOV A, #0
CSL_MAX:
    CLR C
    SUBB A, 34H
    JC CSL_BLOCK
    JZ CSL_BLOCK
    MOV A, #1
    RET
CSL_BLOCK:
    MOV A, #0
    RET

; CAN_SHIFT_RIGHT: allowed only while shift counter > 0 (home = blocked,
; so the beginning of the equation cannot be pushed off with empty columns).
CAN_SHIFT_RIGHT:
    MOV A, 34H
    JZ CSR_BLOCK
    MOV A, #1
    RET
CSR_BLOCK:
    MOV A, #0
    RET

; Wait for the next UART byte with a ~20 ms timeout.
; Returns: CY=0 + byte in A if received, CY=1 if timed out (never hangs).
WAIT_RX:
    MOV R7, #80
WR_O:
    MOV R6, #230
WR_I:
    JNB RI, WR_NEXT
    CLR RI
    MOV A, SBUF
    CLR C                   ; successful receive: return CY=0
    RET
WR_NEXT:
    DJNZ R6, WR_I
    DJNZ R7, WR_O
    SETB C
    RET

ERASE_LAST_CHAR:
    MOV A, 4EH
    JZ ELX
    DEC 4EH
    LCALL NORMALIZE_SHIFT
    MOV R2, #0
    MOV R3, 4EH
    LCALL LCD_SET_CURSOR
    MOV A, #20H
    LCALL LCD_DATA_WRITE
    MOV R2, #0
    MOV R3, 4EH
    LCALL LCD_SET_CURSOR
ELX:
    RET

ERASE_OPERATOR:
    MOV A, 30H
    JNZ EO_GATE
    MOV 57H, #1
    SJMP EO_L
EO_GATE:
    MOV A, 47H
    MOV DPTR, #GATE_LEN
    MOVC A, @A+DPTR
    MOV 57H, A
EO_L:
    MOV A, 4EH
    JZ EO_X
    DEC 4EH
    LCALL NORMALIZE_SHIFT
    MOV R2, #0
    MOV R3, 4EH
    LCALL LCD_SET_CURSOR
    MOV A, #20H
    LCALL LCD_DATA_WRITE
    MOV R2, #0
    MOV R3, 4EH
    LCALL LCD_SET_CURSOR
    DJNZ 57H, EO_L
EO_X:
    RET

; AUTO_SCROLL_TO_END: keep the newest equation character visible once
; line 1 grows beyond the LCD's 16 visible columns. 4EH is the logical
; equation length and 34H is the number of left display shifts.
AUTO_SCROLL_TO_END:
    MOV A, 4EH
    CLR C
    SUBB A, #16
    JC ASTE_X
    JZ ASTE_X
    MOV 37H, A             ; required shift = equation length - 16
ASTE_L:
    MOV A, 34H
    CJNE A, 37H, ASTE_C
    RET
ASTE_C:
    JNC ASTE_X             ; already at or beyond the required shift
    MOV A, #SHIFT_LEFT
    LCALL LCD_CMD
    INC 34H
    SJMP ASTE_L
ASTE_X:
    RET

; PREPARE_NEXT_CHAR: called before writing an ordinary equation byte.
; If 4EH characters already exist, the new byte will be at position
; 4EH+1. Shift first until that position is inside the 16-column window.
; This also returns to the live end if the user manually scrolled back.
PREPARE_NEXT_CHAR:
    MOV A, 4EH
    CLR C
    SUBB A, #15
    JC PNC_X
    JZ PNC_X
    MOV 37H, A             ; required shift for the character about to arrive
PNC_L:
    MOV A, 34H
    CJNE A, 37H, PNC_C
    RET
PNC_C:
    JNC PNC_X
    MOV A, #SHIFT_LEFT
    LCALL LCD_CMD
    INC 34H
    SJMP PNC_L
PNC_X:
    RET

; NORMALIZE_SHIFT: after deletion, prevent the window from remaining
; farther left than the shortened equation permits.
NORMALIZE_SHIFT:
    MOV A, 4EH
    CLR C
    SUBB A, #16
    JNC NS_HAVE_MAX
    MOV A, #0
NS_HAVE_MAX:
    MOV 37H, A
NS_L:
    MOV A, 34H
    CLR C
    SUBB A, 37H
    JZ NS_X
    JC NS_X
    MOV A, #SHIFT_RIGHT
    LCALL LCD_CMD
    DEC 34H
    SJMP NS_L
NS_X:
    RET

; RETURN_SHIFT_HOME: undo every equation-window shift without changing
; the logical DDRAM cursor position. Used immediately after '='.
RETURN_SHIFT_HOME:
    MOV A, 34H
    JZ RSH_X
RSH_L:
    MOV A, #SHIFT_RIGHT
    LCALL LCD_CMD
    DEC 34H
    MOV A, 34H
    JNZ RSH_L
RSH_X:
    RET

DISPLAY_ERROR:
    LCALL CLEAR_LINE2
    MOV A, #00H
    LCALL LCD_DATA_WRITE
    MOV A, 5DH
    CJNE A, #1, DR2
    MOV DPTR, #STR_OVERFLOW
    SJMP DR_P
DR2:
    CJNE A, #2, DR3
    MOV DPTR, #STR_DIV0
    SJMP DR_P
DR3:
    MOV DPTR, #STR_INVALID
DR_P:
    LCALL LCD_PRINT_STRING
    MOV 4EH, #0
    RET

ENTRY_SCREEN:
    LCALL CLEAR_BOTH_LINES
    MOV 4EH, #0
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV DPTR, #STR_HINTS_MATH
    LCALL LCD_PRINT_STRING
    MOV R2, #0
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    RET

ENTRY_SCREEN_L:
    LCALL CLEAR_BOTH_LINES
    MOV 4EH, #0
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV DPTR, #STR_HINTS_LOGIC
    LCALL LCD_PRINT_STRING
    MOV R2, #0
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    RET

SHOW_VALUE:
    LCALL CLEAR_LINE2
    MOV R6, 41H
    MOV R7, 40H
    MOV A, 35H
    JZ SV_DEC16
    CJNE A, #1, SV_DEC8
    LCALL PRINT_BIN_16BIT
    RET
SV_DEC8:
    CJNE A, #2, SV_BIN8
    MOV A, 40H
    LCALL PRINT_DEC_8BIT
    RET
SV_BIN8:
    CJNE A, #3, SV_SIGNED_DEC
    MOV A, 41H             ; logic packet high field carries width 1..8
    MOV 35H, A
    MOV A, 40H
    LCALL PRINT_BIN_8BIT
    RET
SV_SIGNED_DEC:
    CJNE A, #5, SV_DEC16   ; format 4 = positive, format 5 = negative
    MOV A, #2DH            ; print '-' before the result magnitude
    LCALL LCD_DATA_WRITE
SV_DEC16:
    LCALL PRINT_DEC_16BIT
    RET

SHOW_SCREEN:
    MOV R4, A           ; <-- FIX: Save the active screen index into R4!
    RL A
    MOV B, A            ; B = screen*2 = line-0 string index
    LCALL CLEAR_BOTH_LINES
    MOV 4EH, #0
    MOV R2, #0
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV A, B
    LCALL SS_PRINT_LINE
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV A, B
    INC A
    LCALL SS_PRINT_LINE
    MOV 4EH, #0
    RET
SS_PRINT_LINE:
    ; A = string index 0..13, each string is exactly 16 chars + 0
    MOV R6, A
    RL A
    RL A
    RL A
    RL A
    ADD A, R6           ; A = index * 17
    MOV R6, A
    MOV DPTR, #STR_BLOCK
    ADD A, DPL
    MOV DPL, A
    JNC SS_P0
    INC DPH
SS_P0:
    LCALL LCD_PRINT_STRING
    RET

PRINT_GATE:
    MOV A, 47H
    MOV DPTR, #GATE_OFF
    MOVC A, @A+DPTR
    MOV R0, A
    MOV DPTR, #GATE_TABLE
    MOV A, R0
    ADD A, DPL
    MOV DPL, A
    JNC PG_OK
    INC DPH
PG_OK:
    CLR A
    MOVC A, @A+DPTR
    JZ PG_X
    LCALL LCD_DATA_WRITE
    INC DPTR
    SJMP PG_OK
PG_X:
    MOV A, 47H
    MOV DPTR, #GATE_LEN
    MOVC A, @A+DPTR
    ADD A, 4EH
    MOV 4EH, A
    RET

CLEAR_LINE2:
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV R7, #16
CL2_L:
    MOV A, #20H
    LCALL LCD_DATA_WRITE
    DJNZ R7, CL2_L
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    RET

PRINT_DEC_8BIT:
    MOV B, #100
    DIV AB
    MOV 44H, A
    XCH A, B
    MOV B, #10
    DIV AB
    MOV 45H, A
    MOV 46H, B
    MOV 5CH, #0            ; 5CH = "nonzero digit seen" flag
    MOV A, 44H
    LCALL PD8_1            ; hundreds (suppress leading zero)
    MOV A, 45H
    LCALL PD8_1            ; tens (suppress leading zero)
    MOV A, 46H
    LCALL PD8_1            ; units (always printed)
    MOV A, 5CH
    JNZ PD8_X
    MOV A, #30H            ; value was 0 -> print a single '0'
    LCALL LCD_DATA_WRITE
PD8_X:
    RET
PD8_1:
    JNZ PD8_P              ; digit != 0 -> print it
    MOV A, 5CH
    JZ PD8_SKIP            ; still leading -> skip
    CLR A                  ; restore the actual digit value 0
    SJMP PD8_P             ; already started -> print this zero
PD8_SKIP:
    RET
PD8_P:
    MOV 5CH, #1
    ADD A, #30H
    LCALL LCD_DATA_WRITE
    RET

PRINT_DEC_16BIT:
    MOV 50H, #0
    MOV 51H, #0
    MOV 52H, #0
    MOV 53H, #0
TT_L:
    CLR C
    MOV A, R7
    SUBB A, #010H
    MOV 5FH, A
    MOV A, R6
    SUBB A, #027H
    JC TT_X
    MOV R6, A
    MOV A, 5FH
    MOV R7, A
    INC 50H
    SJMP TT_L
TT_X:
TH_L:
    CLR C
    MOV A, R7
    SUBB A, #0E8H
    MOV 5FH, A
    MOV A, R6
    SUBB A, #003H
    JC TH_X
    MOV R6, A
    MOV A, 5FH
    MOV R7, A
    INC 51H
    SJMP TH_L
TH_X:
HU_L:
    CLR C
    MOV A, R7
    SUBB A, #064H
    MOV 5FH, A
    MOV A, R6
    SUBB A, #000H
    JC HU_X
    MOV R6, A
    MOV A, 5FH
    MOV R7, A
    INC 52H
    SJMP HU_L
HU_X:
TE_L:
    MOV A, R7
    CLR C
    SUBB A, #10
    JC TE_X
    MOV R7, A
    INC 53H
    SJMP TE_L
TE_X:
    MOV 54H, R7
    MOV 5CH, #0            ; 5CH = "nonzero digit seen" flag
    MOV A, 50H
    LCALL PD16_1           ; ten-thousands (suppress leading zero)
    MOV A, 51H
    LCALL PD16_1           ; thousands (suppress leading zero)
    MOV A, 52H
    LCALL PD16_1           ; hundreds (suppress leading zero)
    MOV A, 53H
    LCALL PD16_1           ; tens (suppress leading zero)
    MOV A, 54H
    LCALL PD16_1           ; units (always printed)
    MOV A, 5CH
    JNZ PD16_X
    MOV A, #30H            ; value was 0 -> print a single '0'
    LCALL LCD_DATA_WRITE
PD16_X:
    RET
PD16_1:
    JNZ PD16_P             ; digit != 0 -> print it
    MOV A, 5CH
    JZ PD16_SKIP           ; still leading -> skip
    CLR A                  ; restore the actual digit value 0
    SJMP PD16_P            ; already started -> print this zero
PD16_SKIP:
    RET
PD16_P:
    MOV 5CH, #1
    ADD A, #30H
    LCALL LCD_DATA_WRITE
    RET

PRINT_BIN_8BIT:
    MOV 33H, #1            ; Unlock auto-display state instantly
    MOV R1, A
    MOV A, 35H             ; Get bit width from MCU 1
    JZ PB8_DF
    MOV R0, A              ; Loop counter = width
    
    ; Shift data left by (8 - width) to align high bits
    MOV A, #8
    CLR C
    SUBB A, R0
    JZ B8_LOGIC_L
    MOV R2, A
PB8_AL:
    MOV A, R1
    RL A
    MOV R1, A
    DJNZ R2, PB8_AL
    SJMP B8_LOGIC_L
PB8_DF:
    MOV R0, #8
B8_LOGIC_L:
    MOV A, R1
    RLC A                  ; Shift highest bit into Carry
    MOV R1, A
    JC B8_LOGIC_1
    MOV A, #30H            ; Always print '0', no skipping!
    SJMP B8_LOGIC_W
B8_LOGIC_1:
    MOV A, #31H            ; Print '1'
B8_LOGIC_W:
    LCALL LCD_DATA_WRITE
    DJNZ R0, B8_LOGIC_L
    RET

PRINT_BIN_16BIT:
    MOV 5CH, #0            ; 5CH = "nonzero bit seen" flag
    MOV R0, #16
B16_L:
    MOV A, R7
    RLC A
    MOV R7, A
    MOV A, R6
    RLC A
    MOV R6, A
    JC B16_1
    MOV A, 5CH
    JZ B16_N               ; still leading zeros -> skip
    MOV A, #30H
    SJMP B16_S
B16_1:
    MOV 5CH, #1
    MOV A, #31H
B16_S:
    LCALL LCD_DATA_WRITE
B16_N:
    DJNZ R0, B16_L
    MOV A, 5CH
    JNZ B16_X
    MOV A, #30H            ; value was 0 -> print a single '0'
    LCALL LCD_DATA_WRITE
B16_X:
    RET

LCD_INIT:
    LCALL DELAY_15MS
    MOV A, #38H
    LCALL LCD_CMD
    LCALL DELAY_15MS
    MOV A, #0EH
    LCALL LCD_CMD
    LCALL DELAY_15MS
    MOV A, #01H
    LCALL LCD_CMD
    LCALL DELAY_15MS
    MOV A, #06H
    LCALL LCD_CMD
    LCALL DELAY_2MS
    RET

LCD_LOAD_CGRAM:
    MOV A, #40H
    LCALL LCD_CMD
    MOV DPTR, #ICON_DATA
    MOV R4, #8
CG_L:
    CLR A
    MOVC A, @A+DPTR
    LCALL LCD_DATA_WRITE
    INC DPTR
    DJNZ R4, CG_L
    RET

LCD_CMD:
    MOV LCD_DATA, A
    CLR RS
    SETB E
    LCALL DELAY_SHORT
    CLR E
    LCALL DELAY_SHORT
    RET

LCD_DATA_WRITE:
    MOV LCD_DATA, A
    SETB RS
    SETB E
    LCALL DELAY_SHORT
    CLR E
    LCALL DELAY_SHORT
    RET

LCD_PRINT_STRING:
    CLR A
    MOVC A, @A+DPTR
    JZ LPS_X
    LCALL LCD_DATA_WRITE
    INC DPTR
    SJMP LCD_PRINT_STRING
LPS_X:
    RET

LCD_SET_CURSOR:
    MOV A, R2
    JZ ROW0
    MOV A, #40H
    SJMP ADD_COL
ROW0:
    MOV A, #00H
ADD_COL:
    ADD A, R3
    ORL A, #80H
    LCALL LCD_CMD
    RET

CLEAR_BOTH_LINES:
    MOV A, #01H
    LCALL LCD_CMD
    LCALL DELAY_2MS
    MOV A, #80H
    LCALL LCD_CMD
    RET

SHOW_WELCOME:
    LCALL CLEAR_BOTH_LINES
    MOV R2, #0
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV DPTR, #STR_WELCOME
    LCALL LCD_PRINT_STRING
    MOV R2, #1
    MOV R3, #0
    LCALL LCD_SET_CURSOR
    MOV DPTR, #STR_GROUP
    LCALL LCD_PRINT_STRING
    LCALL WELCOME_HOLD        ; hold both full lines visible
    MOV 5FH, #16
SW_L:
    MOV A, #SHIFT_LEFT
    LCALL LCD_CMD
    LCALL WELCOME_STEP        ; ~50 ms per step so the text is readable
    DJNZ 5FH, SW_L
    MOV 5FH, #16
SW_R:
    MOV A, #SHIFT_RIGHT
    LCALL LCD_CMD
    DJNZ 5FH, SW_R
    LCALL WELCOME_HOLD
    RET
WELCOME_HOLD:
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	;--------display more longer time----------
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    RET
WELCOME_STEP:
    LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    LCALL DELAY_15MS
    LCALL DELAY_15MS
	LCALL DELAY_15MS
    RET

DELAY_15MS:
    MOV R7, #30
D15A:
    MOV R6, #250
D15B:
    DJNZ R6, D15B
    DJNZ R7, D15A
    RET

DELAY_2MS:
    MOV R6, #250
D2A:
    MOV R5, #10
    DJNZ R5, $
    DJNZ R6, D2A
    RET

DELAY_SHORT:
    MOV R5, #50
    DJNZ R5, $
    RET

STR_BLOCK:
    DB '1:Math   2:Logic', 0  ; Screen 0, Line 1
    DB 'Pls select mode ', 0  ; Screen 0, Line 2
    DB '1:+ 2:- 3:* 4:/ ', 0  ; Screen 1, Line 1
    DB '*close          ', 0  ; Screen 1, Line 2
    DB '1.AND   2.OR   >', 0  ; Screen 2, Line 1
    DB '5.NOR   6.XNOR  ', 0  ; Screen 2, Line 2
    DB '< 3.NOT   4.NAND', 0  ; Screen 3, Line 1
    DB '  7.XOR   *Close', 0  ; Screen 3, Line 2

    
STR_HINTS_MATH:
    DB 'A:Del D:= C:Clr ', 0
;---------- change it to just like math----------
STR_HINTS_LOGIC:
    DB 'A:Del D:= C:Clr ', 0

; === STUDENT LABEL: GATE WIDTHS ADJUSTED FOR NEW SPACES ===
; === STUDENT LABEL: GATE WIDTHS ADJUSTED FOR EQUATION SPACING ===
GATE_LEN:
    DB 5, 4, 5, 6, 5, 6, 5
GATE_OFF:
    DB 0, 6, 11, 17, 24, 30, 37, 43
GATE_TABLE:
    DB ' AND ', 0
    DB ' OR ', 0
    DB ' NOT ', 0
    DB ' NAND ', 0
    DB ' NOR ', 0
    DB ' XNOR ', 0
    DB ' XOR ', 0

ICON_DATA:
    DB 00H, 0AH, 0AH, 01H, 00H, 0EH, 11H, 00H
STR_OVERFLOW:
    DB 'OVERFLOW', 0
STR_DIV0:
    DB 'DIV 0', 0
STR_INVALID:
    DB 'INVALID INPUT', 0
STR_WELCOME:
    DB 'Hello, Dr.Lee Yu Jen & users', 0
STR_GROUP:
    DB '8051 Calculator by Group I', 0

END

