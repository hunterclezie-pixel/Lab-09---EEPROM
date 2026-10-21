// Hunter Clezie
// RCET3375
// Lab9EEPROMPt2
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
    selected_value EQU 0x20 ; Pending RAM selection: A or B
    stored_value   EQU 0x21 ; Value read from EEPROM
    write_down     EQU 0x22 ; 1 when Write button is held
    select_down    EQU 0x23 ; 1 when Select button is held
    Count5ms	   EQU 0x24 ; Outer debounce delay counter
    Count50us      EQU 0x25 ; Inner debounce delay counter

    ; Reusable EEPROM registers (only these 3 GPRs used by EEPROM routines)
    ee_address     EQU 0x26  ; EEPROM address
    ee_data        EQU 0x27  ; Byte to read or write
    ee_status      EQU 0x28  ; EEPROM status bits
    
    ; Additional application registers
    selection_mode EQU 0x29  ; Bit 0 = selection mode active
    timeout_tick   EQU 0x2A  ; Counts 20 Timer1 overflows

    ; Constant (a number, NOT a register)
    TIMEOUT_OVERFLOWS EQU 15 ; 15 x 65.536 ms = about 1 second

    ; EEPROM status bit positions
    EEPROM_READ    EQU 0
    EEPROM_WRITE   EQU 1
    EEPROM_ERROR   EQU 2
    GIE_SAVED      EQU 3     ; Temporarily save GIE during unlock
      
    ; EEPROM address
    DATA_EE_ADDR   EQU 0x00  ; Store our character at address 0
 
; Reset Vector at 0000h. Execution starts here after reset.
PSECT resetVect,class=CODE,delta=2
ResetVector:
    goto Setup

; Interrupt Vector
PSECT isrVect,class=CODE,delta=2

; Main code section starts at 0008h. User code goes here.
PSECT code,class=CODE,delta=2

Setup:
    ; ---- Bank 0: set output latches BEFORE the pins become outputs ----
    BANKSEL PORTA
    BCF PORTA,0     ; Selection LED OFF
    BCF PORTA,1     ; Main-loop diagnostic LOW
    BCF PORTA,2     ; Error LED OFF
    MOVLW 0x80
    MOVWF PORTC     ; Display Write HIGH
 
    ; ---- Bank 3 ----
    BANKSEL ANSEL
    CLRF ANSEL      ; Disable analog inputs
    CLRF ANSELH
    BCF EECON1,7    ; Select data EEPROM
    BCF EECON1,2    ; Disable EEPROM writing
 
    ; ---- Bank 1 ----
    BANKSEL TRISA
    BCF TRISA,0     ; RA0 selection LED output
    BCF TRISA,1     ; RA1 main-loop diagnostic output
    BCF TRISA,2     ; RA2 error LED output
    BSF TRISB,0     ; RB0 Select button
    BSF TRISB,1     ; RB1 Write button
    CLRF TRISC      ; PORTC display outputs
    MOVLW 0x03
    MOVWF WPUB      ; Enable RB0 and RB1 pull-ups
    MOVLW 0x07
    MOVWF OPTION_REG ; RBPU=0 (pull-ups on), internal clock, 1:256 prescaler
 
    ; ---- Bank 0 ----
    BANKSEL TMR0
    CLRF TMR0           ; Clear Timer0 counter
    BCF INTCON,2        ; Clear Timer0 overflow flag
 
    ; Initialize GPRs
    MOVLW 0x41
    MOVWF selected_value ; Start selection at A
    CLRF stored_value
    CLRF write_down
    CLRF select_down
    CLRF ee_address
    CLRF ee_data
    CLRF ee_status
    CLRF selection_mode
    CLRF timeout_tick
 
WaitStartupRelease:
    ; Wait until Write button is released
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease
    CALL Delay10ms       ; Debounce release
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease
 
Main:
    ; Application registers and ports are all in bank 0
    BANKSEL PORTA
    
    ; Pulse RA1 once per main-loop iteration
    BSF PORTA,1
    BCF PORTA,1
 
    ; Poll for EEPROM write completion (EEIF = PIR2 bit 4)
    BTFSS ee_status,EEPROM_WRITE
    GOTO UpdateErrorLED
    BTFSC PIR2,4
    CALL EEPROMVerifyWrite
 
UpdateErrorLED:
    ; RA2 follows EEPROM_ERROR on each loop
    BANKSEL PORTA        ; EEPROMVerifyWrite may have changed banks
    BTFSS ee_status,EEPROM_ERROR
    BCF PORTA,2
    BTFSC ee_status,EEPROM_ERROR
    BSF PORTA,2
 
    ; Time out selection before accepting another button press
    CALL CheckTimeout
 
    ; Ignore buttons (and leave the display alone) while EEPROM is busy
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_READ
    GOTO Main
    BTFSC ee_status,EEPROM_WRITE
    GOTO Main
    CALL CheckSelect
    CALL CheckWrite
 
    ; If a write just started, keep the last character displayed
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_WRITE
    GOTO Main
 
    ; Show pending A/B during selection
    BTFSC selection_mode,0
    GOTO ShowSelection
 
    ; Normal mode: read EEPROM address 0x00
    MOVLW DATA_EE_ADDR
    MOVWF ee_address
    CALL EEPROMRead
    BANKSEL ee_data
    MOVF ee_data,W
    MOVWF stored_value
 
    ; Display A or B if stored data matches
    XORLW 0x41           ; W still holds the stored value
    BTFSC STATUS,2
    GOTO ShowStored
    MOVF stored_value,W
    XORLW 0x42
    BTFSC STATUS,2
    GOTO ShowStored
 
    ; Unknown EEPROM byte displays '?'
    MOVLW 0x3F
    CALL DisplayChar
    GOTO Main
 
ShowStored:
    MOVF stored_value,W
    CALL DisplayChar
    GOTO Main
 
ShowSelection:
    ; Display the pending RAM selection
    MOVF selected_value,W
    CALL DisplayChar
    GOTO Main
 
CheckTimeout:
    BANKSEL selection_mode
    ; Only count time while selecting
    BTFSS selection_mode,0
    RETURN
 
    ; Check for Timer0 overflow
    BTFSS INTCON,2
    RETURN
    BCF INTCON,2         ; Clear overflow flag
 
    ; Count one Timer0 overflow
    INCF timeout_tick,F
 
    ; Check if 15 overflows have occurred
    MOVLW TIMEOUT_OVERFLOWS
    XORWF timeout_tick,W
    BTFSS STATUS,2
    RETURN
 
    ; One second passed without a Select press
    BCF selection_mode,0
    BCF PORTA,0          ; Selection LED OFF
    RETURN
 
RestartSelectionTimer:
    ; Restart the one-second selection window
    BANKSEL timeout_tick
    CLRF timeout_tick
    CLRF TMR0
    BCF INTCON,2
    RETURN

CheckWrite:
    BANKSEL PORTB
    BTFSC PORTB,1        ; HIGH means released
    GOTO WriteReleased
 
    ; Button is physically LOW
    BTFSC write_down,0
    RETURN               ; Already registered as pressed
 
    ; Debounce the press
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,1
    RETURN               ; Invalid press
 
    BSF write_down,0     ; Remember valid press
 
    ; Only write during selection mode
    BTFSS selection_mode,0
    RETURN
 
    ; Exit selection mode
    BCF selection_mode,0
    BCF PORTA,0          ; Selection LED OFF
 
    ; Load the EEPROM address and the pending character
    MOVLW DATA_EE_ADDR
    MOVWF ee_address
    MOVF selected_value,W
    MOVWF ee_data
 
    ; Start the write without waiting
    CALL EEPROMWrite
    RETURN
 
WriteReleased:
    BTFSS write_down,0
    RETURN
 
    ; Debounce the release
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,1
    RETURN
    BCF write_down,0
    RETURN
 
CheckSelect:
    BANKSEL PORTB
    BTFSC PORTB,0        ; HIGH means released
    GOTO SelectReleased
 
    ; Button is physically LOW
    BTFSC select_down,0
    RETURN               ; Already registered as pressed
 
    ; Debounce the press
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,0
    RETURN               ; Invalid press
    BSF select_down,0    ; Remember valid press
 
    ; Check if selection mode is already active
    BTFSC selection_mode,0
    GOTO ToggleSelection
 
    ; First Select press starts with A
    BSF selection_mode,0
    MOVLW 0x41
    MOVWF selected_value
    BSF PORTA,0          ; Selection LED ON
    CALL RestartSelectionTimer
    RETURN
 
ToggleSelection:
    ; 'A' (0x41) XOR 0x03 = 'B' (0x42), and 'B' XOR 0x03 = 'A'
    MOVLW 0x03
    XORWF selected_value,F
    CALL RestartSelectionTimer
    RETURN
 
SelectReleased:
    BTFSS select_down,0
    RETURN
 
    ; Debounce the release
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,0
    RETURN
    BCF select_down,0
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
