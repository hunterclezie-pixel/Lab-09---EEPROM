// Hunter Clezie
// RCET3375
// Lab9EEPROMPt3
// https://github.com/hunterclezie-pixel/Lab-09---EEPROM.git

; PIC16F883 Configuration Bit Settings

; Assembly source line config statements

; CONFIG1
  CONFIG  FOSC = XT             ; Oscillator Selection bits (XT oscillator: Crystal/resonator on RA6/OSC2/CLKOUT and RA7/OSC1/CLKIN)
  CONFIG  WDTE = OFF            ; Watchdog Timer Enable bit (WDT disabled and can be enabled by SWDTEN bit of the WDTCON register)
  CONFIG  PWRTE = OFF           ; Power-up Timer Enable bit (PWRT disabled)
  CONFIG  MCLRE = ON            ; RE3/MCLR pin function select bit (RE3/MCLR pin function is MCLR)
  CONFIG  CP = OFF              ; Code Protection bit (Program memory code protection is disabled)
  CONFIG  CPD = OFF             ; Data Code Protection bit (Data memory code protection is disabled)
  CONFIG  BOREN = OFF           ; Brown Out Reset Selection bits (BOR disabled)
  CONFIG  IESO = OFF            ; Internal External Switchover bit (Internal/External Switchover mode is disabled)
  CONFIG  FCMEN = OFF           ; Fail-Safe Clock Monitor Enabled bit (Fail-Safe Clock Monitor is disabled)
  CONFIG  LVP = OFF             ; Low Voltage Programming Enable bit (RB3 pin has digital I/O, HV on MCLR must be used for programming)

; CONFIG2
  CONFIG  BOR4V = BOR40V        ; Brown-out Reset Selection bit (Brown-out Reset set to 4.0V)
  CONFIG  WRT = OFF             ; Flash Program Memory Self Write Enable bits (Write protection off)

; config statements should precede project file includes.
#include <xc.inc>  
    ; General Purpose Registers
    pin_digit1     EQU 0x20 ; First entered PIN digit
    pin_digit2     EQU 0x21 ; Second entered PIN digit
    pin_digit3     EQU 0x22 ; Third entered PIN digit
    pin_digit4     EQU 0x23 ; Fourth entered PIN digit
    Count5ms	   EQU 0x24 ; Outer debounce delay counter
    Count50us      EQU 0x25 ; Inner debounce delay counter

    ; Reusable EEPROM registers (only these 3 GPRs used by EEPROM routines)
    ee_address     EQU 0x26  ; EEPROM address
    ee_data        EQU 0x27  ; Byte to read or write
    ee_status      EQU 0x28  ; EEPROM status bits
    
    ; Additional application registers
    digit_count    EQU 0x29 ; Number of PIN digits entered
    key_held       EQU 0x2A ; Bit 0 = key has been pressed
    key_code       EQU 0x2B ; Scanned key (0-15, FF = none)
    candidate_key  EQU 0x2C ; Key saved during debounce
    keyLow         EQU 0x2D ; Key status bits for keys 1,2,3,A,4,5,6,B
    key_index      EQU 0x2E ; Scanned key position (0-15, FF = none)
    keyHigh        EQU 0x2F ; Key status bits for keys 7,8,9,C,*,0,#,D
    beep_count     EQU 0x30 ; Buzzer delay counter
    pulse_count    EQU 0x31 ; Timer0 overflow counter
    entry_error    EQU 0x32 ; Bit 0 = fifth digit entered
    pin_index      EQU 0x33 ; PIN comparison counter

    ; Constant (a number, NOT a register)
    TIMEOUT_OVERFLOWS EQU 15 ; 15 x 65.536 ms = about 1 second
    PIN_EE_START   EQU 0x00
    PIN_LENGTH     EQU 0x04

    ; EEPROM status bit positions
    EEPROM_READ    EQU 0
    EEPROM_WRITE   EQU 1
    EEPROM_ERROR   EQU 2
    GIE_SAVED      EQU 3     ; Temporarily save GIE during unlock
      
; Special keypad codes
    NO_KEY         EQU 0xFF
    STAR_KEY       EQU 0x0A
    HASH_KEY       EQU 0x0B
 
; Reset Vector at 0000h. Execution starts here after reset.
PSECT resetVect,class=CODE,delta=2
ResetVector:
    goto Setup

; Interrupt Vector
PSECT isrVect,class=CODE,delta=2

; Main code section starts at 0008h. User code goes here.
PSECT code,class=CODE,delta=2

Setup:
    ; Bank 0: Outputs OFF before the pins become outputs
    BANKSEL PORTA
    CLRF PORTA      ; Solenoid and buzzer OFF
    CLRF PORTB      ; Keep keypad rows LOW
    MOVLW 0x80
    MOVWF PORTC     ; Display Write HIGH
 
    ; Bank 3
    BANKSEL ANSEL
    CLRF ANSEL      ; Disable analog inputs
    CLRF ANSELH
    BCF EECON1,7    ; Select data EEPROM
    BCF EECON1,2    ; Disable EEPROM writing
 
    ; Bank 1
    BANKSEL TRISA
    BCF TRISA,0     ; RA0 simulated solenoid output
    BCF TRISA,1     ; RA1 buzzer output
    BCF TRISA,2     ; RA2 unused output
    MOVLW 0xFF
    MOVWF TRISB     ; RB0-RB7 start as inputs
    CLRF TRISC      ; Display outputs
    MOVLW 0xFF
    MOVWF WPUB      ; Weak pull-ups on keypad columns
    MOVLW 0x07
    MOVWF OPTION_REG ; RBPU=0 (pull-ups on), internal clock, 1:256 prescaler
 
    ; Bank 0
    BANKSEL TMR0
    CLRF TMR0        ; Clear Timer0 counter
    BCF INTCON,2     ; Clear Timer0 overflow flag
    BCF INTCON,7     ; Leave global interrupts disabled
 
    ; Clear all application registers
    CLRF pin_digit1
    CLRF pin_digit2
    CLRF pin_digit3
    CLRF pin_digit4
    CLRF digit_count
    CLRF key_held
    CLRF candidate_key
    CLRF keyLow
    CLRF key_index
    CLRF keyHigh
    CLRF beep_count
    CLRF pulse_count
    CLRF entry_error
    CLRF pin_index
    CLRF ee_address
    CLRF ee_data
    CLRF ee_status
    MOVLW NO_KEY
    MOVWF key_code
    BCF STATUS,7     ; IRP = 0: indirect addressing uses bank 0/1
 
    ; Begin in the locked state and initialize pin
    CALL InitializePIN
    MOVLW 0x4C       ; 'L' = locked
    CALL DisplayChar
    
GOTO Main
 
Main:
    ; Check for a keypad press
    CALL ScanKey
    BANKSEL key_code
    MOVLW NO_KEY
    XORWF key_code,W
    BTFSC STATUS,2
    GOTO KeyReleased
 
    ; Ignore a key that is still being held
    BTFSC key_held,0
    GOTO Main
 
    ; Debounce a new key press
    MOVF key_code,W
    MOVWF candidate_key
    CALL Delay10ms
    CALL ScanKey
    BANKSEL candidate_key
    MOVF candidate_key,W
    XORWF key_code,W
    BTFSS STATUS,2
    GOTO Main        ; Not a stable press
    BSF key_held,0   ; Count this press only once
    CALL BeepKey     ; All 16 keys produce a beep
    CALL HandleKey   ; Process the new key
    GOTO Main
   
KeyReleased:
    ; Wait for a stable release before accepting another press
    BTFSS key_held,0
    GOTO Main
    CALL Delay10ms
    CALL ScanKey
    BANKSEL key_code
    MOVLW NO_KEY
    XORWF key_code,W
    BTFSS STATUS,2
    GOTO Main
    BCF key_held,0
    GOTO Main
    
ScanKey:
    ; Determine which key is pressed on the 4x4 keypad
    BANKSEL keyLow
    CLRF keyLow      ; Clearing lower key status bits
    CLRF keyHigh     ; Clearing higher key status bits
 
; Checks Row 4 of the 4x4 matrix
    BANKSEL TRISB
    MOVLW 0xF7       ; RB3 output LOW, rest of PORTB inputs
    MOVWF TRISB
    BANKSEL PORTB
    NOP              ; Let the row settle
    NOP
 
; Checks each column 1-4
    BTFSS PORTB,4    ; Column 1 for '*' key being pressed
    BSF keyHigh,4
    BTFSS PORTB,5    ; Column 2 for '0' key being pressed
    BSF keyHigh,5
    BTFSS PORTB,6    ; Column 3 for '#' key being pressed
    BSF keyHigh,6
    BTFSS PORTB,7    ; Column 4 for 'D' key being pressed
    BSF keyHigh,7
 
; Checks Row 3 of the 4x4 matrix
    BANKSEL TRISB
    MOVLW 0xFB       ; RB2 output LOW, rest of PORTB inputs
    MOVWF TRISB
    BANKSEL PORTB
    NOP
    NOP
 
    BTFSS PORTB,4    ; Column 1 for '7' key being pressed
    BSF keyHigh,0
    BTFSS PORTB,5    ; Column 2 for '8' key being pressed
    BSF keyHigh,1
    BTFSS PORTB,6    ; Column 3 for '9' key being pressed
    BSF keyHigh,2
    BTFSS PORTB,7    ; Column 4 for 'C' key being pressed
    BSF keyHigh,3
 
; Checks Row 2 of the 4x4 matrix
    BANKSEL TRISB
    MOVLW 0xFD       ; RB1 output LOW, rest of PORTB inputs
    MOVWF TRISB
    BANKSEL PORTB
    NOP
    NOP
 
    BTFSS PORTB,4    ; Column 1 for '4' key being pressed
    BSF keyLow,4
    BTFSS PORTB,5    ; Column 2 for '5' key being pressed
    BSF keyLow,5
    BTFSS PORTB,6    ; Column 3 for '6' key being pressed
    BSF keyLow,6
    BTFSS PORTB,7    ; Column 4 for 'B' key being pressed
    BSF keyLow,7
 
; Checks Row 1 of the 4x4 matrix
    BANKSEL TRISB
    MOVLW 0xFE       ; RB0 output LOW, rest of PORTB inputs
    MOVWF TRISB
    BANKSEL PORTB
    NOP
    NOP
 
    BTFSS PORTB,4    ; Column 1 for '1' key being pressed
    BSF keyLow,0
    BTFSS PORTB,5    ; Column 2 for '2' key being pressed
    BSF keyLow,1
    BTFSS PORTB,6    ; Column 3 for '3' key being pressed
    BSF keyLow,2
    BTFSS PORTB,7    ; Column 4 for 'A' key being pressed
    BSF keyLow,3
 
; Release all rows (all of PORTB back to inputs)
    BANKSEL TRISB
    MOVLW 0xFF
    MOVWF TRISB
    BANKSEL keyLow
 
; Pick one key if several are pressed (D = highest priority)
; Store the actual key value instead of using KeyTable
Test_D:
    BTFSS keyHigh,7  ; Test if D is pressed
    GOTO Test_Hash
    MOVLW 0x0F
    GOTO SaveKeyIndex

Test_Hash:
    BTFSS keyHigh,6  ; Test if # is pressed
    GOTO Test_0
    MOVLW HASH_KEY
    GOTO SaveKeyIndex

Test_0:
    BTFSS keyHigh,5  ; Test if 0 is pressed
    GOTO Test_Star
    MOVLW 0x00
    GOTO SaveKeyIndex

Test_Star:
    BTFSS keyHigh,4  ; Test if * is pressed
    GOTO Test_C
    MOVLW STAR_KEY
    GOTO SaveKeyIndex

Test_C:
    BTFSS keyHigh,3  ; Test if C is pressed
    GOTO Test_9
    MOVLW 0x0E
    GOTO SaveKeyIndex

Test_9:
    BTFSS keyHigh,2  ; Test if 9 is pressed
    GOTO Test_8
    MOVLW 0x09
    GOTO SaveKeyIndex

Test_8:
    BTFSS keyHigh,1  ; Test if 8 is pressed
    GOTO Test_7
    MOVLW 0x08
    GOTO SaveKeyIndex

Test_7:
    BTFSS keyHigh,0  ; Test if 7 is pressed
    GOTO Test_B
    MOVLW 0x07
    GOTO SaveKeyIndex

Test_B:
    BTFSS keyLow,7   ; Test if B is pressed
    GOTO Test_6
    MOVLW 0x0D
    GOTO SaveKeyIndex

Test_6:
    BTFSS keyLow,6   ; Test if 6 is pressed
    GOTO Test_5
    MOVLW 0x06
    GOTO SaveKeyIndex

Test_5:
    BTFSS keyLow,5   ; Test if 5 is pressed
    GOTO Test_4
    MOVLW 0x05
    GOTO SaveKeyIndex

Test_4:
    BTFSS keyLow,4   ; Test if 4 is pressed
    GOTO Test_A
    MOVLW 0x04
    GOTO SaveKeyIndex

Test_A:
    BTFSS keyLow,3   ; Test if A is pressed
    GOTO Test_3
    MOVLW 0x0C
    GOTO SaveKeyIndex

Test_3:
    BTFSS keyLow,2   ; Test if 3 is pressed
    GOTO Test_2
    MOVLW 0x03
    GOTO SaveKeyIndex

Test_2:
    BTFSS keyLow,1   ; Test if 2 is pressed
    GOTO Test_1
    MOVLW 0x02
    GOTO SaveKeyIndex

Test_1:
    BTFSS keyLow,0   ; Test if 1 is pressed
    GOTO NoKey
    MOVLW 0x01
    GOTO SaveKeyIndex

NoKey:
    MOVLW NO_KEY     ; No key active

SaveKeyIndex:
    BANKSEL key_code
    MOVWF key_code   ; Save the actual key value
    RETURN
 
; Handle one debounced keypad press
HandleKey:
    BANKSEL key_code
    MOVLW STAR_KEY
    XORWF key_code,W
    BTFSC STATUS,2
    GOTO CancelPIN
    MOVLW HASH_KEY
    XORWF key_code,W
    BTFSC STATUS,2
    GOTO SubmitPIN
 
    ; A-D do not change PIN entry
    MOVLW 0x0A
    SUBWF key_code,W    ; Carry=1 when key >= 10
    BTFSC STATUS,0
    RETURN
 
    ; Ignore digits after a fifth digit was already rejected
    BTFSC entry_error,0
    RETURN
 
    ; Reject a fifth digit, even if first four were correct
    MOVLW PIN_LENGTH
    XORWF digit_count,W
    BTFSC STATUS,2
    GOTO TooManyDigits
 
    ; Store the entered digit: FSR = pin_digit1 + digit_count
    MOVF digit_count,W
    ADDLW pin_digit1
    MOVWF FSR
    MOVF key_code,W
    MOVWF INDF
    INCF digit_count,F
 
    ; Display how many digits have been entered (1-4)
    MOVF digit_count,W
    ADDLW 0x30           ; ASCII '1' through '4'
    CALL DisplayChar
    RETURN
 
TooManyDigits:
    BSF entry_error,0
    MOVLW 0x45           ; 'E' = rejected entry
    CALL DisplayChar
    RETURN
 
CancelPIN:
    CALL ClearEntry
    MOVLW 0x43           ; 'C' = canceled
    CALL DisplayChar
    RETURN
 
SubmitPIN:
    ; An invalid length or fifth digit must never unlock
    BTFSC entry_error,0
    GOTO RejectPIN
    MOVLW PIN_LENGTH
    XORWF digit_count,W
    BTFSS STATUS,2
    GOTO RejectPIN
    CALL ComparePIN
    CALL ClearEntry
    RETURN
 
RejectPIN:
    CALL ClearEntry
    MOVLW 0x45           ; 'E' = wrong/incomplete PIN
    CALL DisplayChar
    RETURN
 
ClearEntry:
    BANKSEL digit_count
    CLRF digit_count
    CLRF entry_error
    CLRF pin_digit1
    CLRF pin_digit2
    CLRF pin_digit3
    CLRF pin_digit4
    RETURN
 
ComparePIN:
    ; Compare all four RAM digits with data EEPROM
    BANKSEL pin_index
    CLRF pin_index
 
CompareNextDigit:
    MOVF pin_index,W
    ADDLW PIN_EE_START
    MOVWF ee_address
    CALL EEPROMRead       ; Part 2 routine, stored digit returns in ee_data
 
    BANKSEL pin_index     ; EEPROMRead changes banks
    MOVF pin_index,W
    ADDLW pin_digit1
    MOVWF FSR
    MOVF INDF,W          ; Entered digit
    XORWF ee_data,W      ; Compare with stored EEPROM digit
    BTFSS STATUS,2
    GOTO WrongPIN
    INCF pin_index,F
    MOVLW PIN_LENGTH
    XORWF pin_index,W
    BTFSS STATUS,2
    GOTO CompareNextDigit
 
    ; All four digits matched
    MOVLW 0x55           ; 'U' = unlocked
    CALL DisplayChar
    CALL SolenoidPulse
    MOVLW 0x4C           ; 'L' = locked again
    CALL DisplayChar
    RETURN
 
WrongPIN:
    MOVLW 0x45           ; 'E' = incorrect PIN
    CALL DisplayChar
    RETURN
 
BeepKey:
    ; Sound the active buzzer for about 150 ms
    BANKSEL PORTA
    BSF PORTA,1          ; Buzzer ON
    MOVLW 0x0F
    MOVWF beep_count     ; 15 x 10 ms
 
BeepLoop:
    CALL Delay10ms
    BANKSEL beep_count
    DECFSZ beep_count,F
    GOTO BeepLoop
    BCF PORTA,1          ; Buzzer OFF
    RETURN
 
SolenoidPulse:
    ; Turn on the simulated solenoid for about one second
    BANKSEL PORTA
    BSF PORTA,0          ; Unlock output HIGH
    CLRF pulse_count
    CLRF TMR0
    BCF INTCON,2
 
SolenoidWait:
    BTFSS INTCON,2
    GOTO SolenoidWait
    BCF INTCON,2
    INCF pulse_count,F
    MOVLW TIMEOUT_OVERFLOWS
    XORWF pulse_count,W
    BTFSS STATUS,2
    GOTO SolenoidWait
    BCF PORTA,0          ; Lock output LOW
    RETURN

EEPROMFetch:
    ; Internal helper: read the EEPROM byte at ee_address, return it in W
    BANKSEL ee_address
    MOVF ee_address,W
    BANKSEL EEADR
    MOVWF EEADR
    BANKSEL EECON1
    BCF EECON1,7         ; EEPGD = 0, data EEPROM
    BSF EECON1,0         ; RD = 1
    BANKSEL EEDATA
    MOVF EEDATA,W
    RETURN
    
EEPROMRead:
    ; Mark EEPROM read as active
    BANKSEL ee_status
    BSF ee_status,EEPROM_READ
 
    ; Read the byte and return it in ee_data
    CALL EEPROMFetch
    BANKSEL ee_data
    MOVWF ee_data
 
    ; Read is finished
    BANKSEL ee_status
    BCF ee_status,EEPROM_READ
    RETURN
 
EEPROMWrite:
    ; Do not start if a write is already active
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_WRITE
    RETURN
 
    ; Do not start if EEIF is already set
    BANKSEL PIR2
    BTFSC PIR2,4
    RETURN
 
    ; Read the currently stored byte (EEADR is now loaded)
    CALL EEPROMFetch
 
    ; Compare stored data with requested data (ee_data is not changed)
    BANKSEL ee_data
    XORWF ee_data,W
    BTFSC STATUS,2
    RETURN               ; Same value, skip the write
 
    ; Copy requested data into EEPROM data register
    MOVF ee_data,W
    BANKSEL EEDATA
    MOVWF EEDATA
 
    ; Mark the write as active and remember if GIE was on
    BANKSEL ee_status
    BSF ee_status,EEPROM_WRITE
    BCF ee_status,GIE_SAVED
    BTFSC INTCON,7       ; INTCON can be read from any bank
    BSF ee_status,GIE_SAVED
 
    ; Enable EEPROM writing
    BANKSEL EECON1
    BCF EECON1,7         ; EEPGD = 0
    BSF EECON1,2         ; WREN = 1
 
    ; Disable global interrupts for unlock
    BCF INTCON,7

WaitGIEOff:
    BTFSC INTCON,7
    GOTO WaitGIEOff
 
    ; Required uninterrupted EEPROM unlock
    MOVLW 0x55
    MOVWF EECON2
    MOVLW 0xAA
    MOVWF EECON2
    BSF EECON1,1         ; WR = 1, start writing
 
    ; Restore previous global interrupt state
    BANKSEL ee_status
    BTFSC ee_status,GIE_SAVED
    BSF INTCON,7         ; Turn GIE back on only if it was on before
    BCF ee_status,GIE_SAVED
    RETURN               ; Do not wait for completion
 
EEPROMVerifyWrite:
    ; Read back the byte at ee_address
    CALL EEPROMFetch
 
    ; Compare with the expected ee_data (ee_data is not changed)
    BANKSEL ee_data
    ; MOVLW 0xFF           ; Testing Error
    XORWF ee_data,W
    BTFSC STATUS,2
    GOTO VerifySuccess
 
    ; Verification failed
    BANKSEL ee_status
    BCF ee_status,EEPROM_WRITE
    BSF ee_status,EEPROM_ERROR
    GOTO VerifyFinished
 
VerifySuccess:
    ; Verification passed, clear all status flags
    BANKSEL ee_status
    CLRF ee_status
 
VerifyFinished:
    BANKSEL EECON1
    BCF EECON1,2         ; WREN = 0
    BANKSEL PIR2
    BCF PIR2,4           ; EEIF = 0
    RETURN

DisplayChar:
    ; DLG7137 Display
    ANDLW 0x7F            ; Keep the seven ASCII data bits
    IORLW 0x80            ; Keep RC7 Write HIGH
    BANKSEL PORTC
    MOVWF PORTC           ; Put character on the data pins
    NOP                   ; Allow data to settle
    BCF PORTC,7           ; Pulse display Write LOW
    NOP
    BSF PORTC,7           ; Finish the display write
    RETURN
 
Delay10ms:
    CALL Delay5ms
    CALL Delay5ms
    RETURN
 
Delay5ms:
    BANKSEL Count5ms
    MOVLW   0x5E
    MOVWF   Count5ms
 
Delay5msLoop:
    CALL    Delay50usLoop
    DECFSZ  Count5ms,F
    GOTO    Delay5msLoop
    MOVLW   0x04
    MOVWF   Count5ms
    DECFSZ  Count5ms,F
    GOTO    $-1
    RETURN
 
Delay50usLoop:
    ; Delay loop is equal to 44 Tcy when count is 15
    MOVLW 0x0F             ; 1 Tcy move W=15 to count
    MOVWF Count50us        ; 1 Tcy make count equal 15
    DECFSZ Count50us,F     ; 1 Tcy if not zero, 2 Tcy if zero
    GOTO $-1               ; 2 Tcy delay runs 15 times before skipping
    RETURN
 
END