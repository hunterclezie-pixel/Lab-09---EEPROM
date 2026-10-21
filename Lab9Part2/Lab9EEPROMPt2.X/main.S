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
    timeout_count  EQU 0x0F   ; 15 Timer0 overflows

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
InterruptVector:

; Main code section starts at 0008h. User code goes here.
PSECT code,class=CODE,delta=2

Setup:
    ; Disable analog inputs
    BANKSEL ANSEL
    CLRF ANSEL
    CLRF ANSELH

    ; Configure diagnostic outputs
    BANKSEL PORTA
    BCF PORTA,0     ; Selection LED OFF
    BCF PORTA,1     ; Main-loop diagnostic LOW
    BCF PORTA,2     ; Error LED OFF

    ; Configure display outputs
    BANKSEL PORTC
    MOVLW 0x80
    MOVWF PORTC     ; Display Write HIGH

    ; Configure input and output pins
    BANKSEL TRISA
    BCF TRISA,0     ; RA0 selection LED output
    BCF TRISA,1	    ; RA1 main-loop diagnostic outpu
    BCF TRISA,2     ; RA2 error LED output
    BSF TRISB,0     ; RB0 Select button
    BSF TRISB,1     ; RB1 Write button
    CLRF TRISC      ; PORTC display outputs

    ; Enable PORTB weak pull-ups
    MOVLW 0x03
    MOVWF WPUB      ; Enable RB0 and RB1 pull-ups
    BCF OPTION_REG,7 ; Enable weak pull-ups

    ; Configure EEPROM
    BANKSEL EECON1
    BCF EECON1,7     ; Select data EEPROM
    BCF EECON1,2     ; Disable EEPROM writing
    
    ; Timer0 setup for one-second selection timeout
    BANKSEL OPTION_REG
    MOVLW 0x07
    MOVWF OPTION_REG    ; Internal clock, 1:256 prescaler
    BANKSEL TMR0
    CLRF TMR0           ; Clear Timer0 counter
    BANKSEL INTCON
    BCF INTCON,2        ; Clear Timer0 overflow flag

    ; Initialize GPRs
    BANKSEL selected_value
    MOVLW 0x41
    MOVWF selected_value ; Start selection at A
    CLRF stored_value
    CLRF write_down
    CLRF select_down
    CLRF ee_address
    CLRF ee_data
    CLRF ee_status
    CLRF selection_mode
    CLRF timeout_count

    WaitStartupRelease:
    ; Wait until Write button is released
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease
    CALL Delay10ms       ; Debounce release
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease

GOTO Main

Main:
    ; Pulse RA1 once per main-loop iteration
    BANKSEL PORTA
    BSF PORTA,1
    BCF PORTA,1

    ; Poll for EEPROM write completion
    BANKSEL ee_status
    BTFSS ee_status,EEPROM_WRITE
    GOTO UpdateErrorLED
    BANKSEL PIR2
    BTFSC PIR2,4
    CALL EEPROMVerifyWrite

UpdateErrorLED:
    ; RA2 follows EEPROM_ERROR on each loop
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_ERROR
    GOTO ErrorLEDOn
    BANKSEL PORTA
    BCF PORTA,2
    GOTO ServiceSelection

ErrorLEDOn:
    BANKSEL PORTA
    BSF PORTA,2

ServiceSelection:
    ; Time out selection before accepting another button press
    CALL CheckTimeout

    ; Ignore buttons while reading or writing EEPROM
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_READ
    GOTO UpdateDisplay
    BTFSC ee_status,EEPROM_WRITE
    GOTO UpdateDisplay
    CALL CheckSelect
    CALL CheckWrite

UpdateDisplay:
    ; During hardware write, leave the last character displayed
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_WRITE
    GOTO Main
    BTFSC ee_status,EEPROM_READ
    GOTO Main

    ; Show pending A/B during selection
    BANKSEL selection_mode
    BTFSC selection_mode,0
    GOTO ShowSelection

    ; Normal mode: read EEPROM address 0x00
    BANKSEL ee_address
    MOVLW DATA_EE_ADDR
    MOVWF ee_address
    CALL EEPROMRead
    BANKSEL ee_data
    MOVF ee_data,W
    MOVWF stored_value

    ; Display A or B if stored data matches
    MOVF stored_value,W
    XORLW 0x41
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
    BANKSEL stored_value
    MOVF stored_value,W
    CALL DisplayChar
    GOTO Main
    
ShowSelection:
    ; Display the pending RAM selection
    ; Do not write EEPROM while Write is held
    BANKSEL selected_value
    MOVF selected_value,W
    CALL DisplayChar
    GOTO Main

CheckTimeout:
    ; Only count time while selecting
    BANKSEL selection_mode
    BTFSS selection_mode,0
    RETURN

    ; Check for Timer0 overflow
    BANKSEL INTCON
    BTFSS INTCON,2
    RETURN

    ; Clear overflow flag
    BCF INTCON,2         

    ; Count one Timer0 overflow
    BANKSEL timeout_tick
    INCF timeout_tick,1

    ; Check if 15 overflows have occurred
    MOVLW timeout_count
    XORWF timeout_tick,W
    BTFSS STATUS,2
    RETURN

    ; One second passed without a Select press
    BANKSEL selection_mode
    BCF selection_mode,0
    BANKSEL PORTA
    BCF PORTA,0          ; Selection LED OFF
    RETURN


RestartSelectionTimer:
    ; Restart the one-second selection window
    BANKSEL timeout_tick
    CLRF timeout_tick
    BANKSEL TMR0
    CLRF TMR0
    BANKSEL INTCON
    BCF INTCON,2
    RETURN
    
CheckWrite:
    ; Ignore buttons while EEPROM is busy
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_READ
    RETURN
    BTFSC ee_status,EEPROM_WRITE
    RETURN
    BANKSEL PORTB
    BTFSC PORTB,1        ; HIGH means released
    GOTO WriteReleased

    ; Button is physically LOW
    BANKSEL write_down
    BTFSC write_down,0
    RETURN               ; Already registered as pressed

    ; Debounce the press
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,1
    RETURN               ; Invalid press

    BANKSEL write_down
    BSF write_down,0     ; Remember valid press

    ; Only write during selection mode
    BANKSEL selection_mode
    BTFSS selection_mode,0
    RETURN

    ; Exit selection mode
    BCF selection_mode,0
    BANKSEL PORTA
    BCF PORTA,0          ; Selection LED OFF

    ; Load the EEPROM address
    BANKSEL ee_address
    MOVLW DATA_EE_ADDR
    MOVWF ee_address

    ; Load the pending character
    BANKSEL selected_value
    MOVF selected_value,W
    BANKSEL ee_data
    MOVWF ee_data

    ; Start the write without waiting
    CALL EEPROMWrite
    RETURN

WriteReleased:
    BANKSEL write_down
    BTFSS write_down,0
    RETURN

    ; Debounce the release
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,1
    RETURN
    BANKSEL write_down
    BCF write_down,0
    RETURN

CheckSelect:
    ; Ignore buttons while EEPROM is busy
    BANKSEL ee_status
    BTFSC ee_status,EEPROM_READ
    RETURN
    BTFSC ee_status,EEPROM_WRITE
    RETURN

    BANKSEL PORTB
    BTFSC PORTB,0        ; HIGH means released
    GOTO SelectReleased

    ; Button is physically LOW
    BANKSEL select_down
    BTFSC select_down,0
    RETURN               ; Already registered as pressed

    ; Debounce the press
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,0
    RETURN               ; Invalid press

    BANKSEL select_down
    BSF select_down,0    ; Remember valid press

    ; Check if selection mode is already active
    BANKSEL selection_mode
    BTFSC selection_mode,0
    GOTO ToggleSelection

    ; First Select press starts with A
    BSF selection_mode,0
    BANKSEL selected_value
    MOVLW 0x41
    MOVWF selected_value
    BANKSEL PORTA
    BSF PORTA,0          ; Selection LED ON
    CALL RestartSelectionTimer
    RETURN

ToggleSelection:
    ; Check if current selection is A
    BANKSEL selected_value
    MOVF selected_value,W
    XORLW 0x41
    BTFSC STATUS,2
    GOTO SelectB

    ; Otherwise select A
    MOVLW 0x41
    MOVWF selected_value
    GOTO SelectionChanged

SelectB:
    MOVLW 0x42           ; Select B
    MOVWF selected_value

SelectionChanged:
    ; Every Select press restarts the timer
    CALL RestartSelectionTimer
    RETURN

SelectReleased:
    BANKSEL select_down
    BTFSS select_down,0
    RETURN

    ; Debounce the release
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,0
    RETURN

    BANKSEL select_down
    BCF select_down,0
    RETURN

    
EEPROMRead:
    ; Mark EEPROM read as active
    BANKSEL ee_status
    BSF ee_status,EEPROM_READ

    ; Set the EEPROM address
    BANKSEL ee_address
    MOVF ee_address,W
    BANKSEL EEADR
    MOVWF EEADR

    ; Start reading data EEPROM
    BANKSEL EECON1
    BCF EECON1,7         ; EEPGD = 0
    BSF EECON1,0         ; RD = 1

    ; Return the byte in ee_data
    BANKSEL EEDATA
    MOVF EEDATA,W
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

    ; Set the requested EEPROM address
    BANKSEL ee_address
    MOVF ee_address,W
    BANKSEL EEADR
    MOVWF EEADR

    ; Read the currently stored byte
    ; Keep the requested value in ee_data
    BANKSEL EECON1
    BCF EECON1,7
    BSF EECON1,0

    BANKSEL EEDATA
    MOVF EEDATA,W

    ; Compare stored data with requested data
    BANKSEL ee_data
    XORWF ee_data,W
    BTFSC STATUS,2
    RETURN               ; Same value, skip the write

    ; Copy requested data into EEPROM data register
    BANKSEL ee_data
    MOVF ee_data,W
    BANKSEL EEDATA
    MOVWF EEDATA

    ; Set EEPROM destination address
    BANKSEL ee_address
    MOVF ee_address,W
    BANKSEL EEADR
    MOVWF EEADR

    ; Mark the write as active
    BANKSEL ee_status
    BSF ee_status,EEPROM_WRITE

    ; Clear the saved interrupt-state bit
    BCF ee_status,GIE_SAVED

    ; Remember if global interrupts were enabled
    BANKSEL INTCON
    BTFSS INTCON,7
    GOTO DisableGIE

    BANKSEL ee_status
    BSF ee_status,GIE_SAVED

DisableGIE:
    ; Enable EEPROM writing
    BANKSEL EECON1
    BCF EECON1,7
    BSF EECON1,2         ; WREN = 1

    ; Disable global interrupts for unlock
    BANKSEL INTCON
    BCF INTCON,7

WaitGIEOff:
    BTFSC INTCON,7
    GOTO WaitGIEOff

    ; Required uninterrupted EEPROM unlock
    BANKSEL EECON1
    MOVLW 0x55
    MOVWF EECON2
    MOVLW 0xAA
    MOVWF EECON2
    BSF EECON1,1         ; WR = 1, start writing

    ; Restore previous global interrupt state
    BANKSEL ee_status
    BTFSS ee_status,GIE_SAVED
    GOTO GIEWasOff

    BANKSEL INTCON
    BSF INTCON,7         ; Restore GIE if previously ON

GIEWasOff:
    BANKSEL ee_status
    BCF ee_status,GIE_SAVED
    RETURN               ; Do not wait for completion
    
EEPROMVerifyWrite:
    ; Read back the EEPROM address
    BANKSEL ee_address
    MOVF ee_address,W
    BANKSEL EEADR
    MOVWF EEADR

    ; Start EEPROM read
    BANKSEL EECON1
    BCF EECON1,7
    BSF EECON1,0

    ; Read the stored byte
    BANKSEL EEDATA
    MOVF EEDATA,W

    ; Compare with the expected ee_data
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
    ; Disable further EEPROM writing
    BANKSEL EECON1
    BCF EECON1,2         ; WREN = 0

    ; Clear the write-complete flag
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
    NOP			  ; Allow data to settle
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
    Call    Delay50usLoop
    DECFSZ  Count5ms
    GOTO    Delay5msLoop
    MOVLW   0x04
    MOVWF   Count5ms
    DECFSZ  Count5ms
    GOTO    $-1
    RETURN
    
Delay50usLoop:
    ;Delay loop is equals 44 Tcy when count is 15
    MOVLW 0x0F             ;1 Tcy move W=15 to count
    MOVWF Count50us        ;1 Tcy make count equal 15                                    
    DECFSZ Count50us,1     ;1 Tcy if not zero, 2 Tcy if zero
    GOTO $-1               ;2 Tcy delay runs 15 times before skiping
    RETURN
    
END