// Hunter Clezie
// RCET3375
// Lab9EEPROMPt1
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
    delay_outer    EQU 0x24 ; Outer debounce delay counter
    delay_inner    EQU 0x25 ; Inner debounce delay counter

    ; EEPROM address
    DATA_EE_ADDR   EQU 0x00 ; Store our character at address 0
 
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
    BCF PORTA,1	    ; Read diagnostic LOW
    BCF PORTA,2     ; Write diagnostic LOW

    ; Configure display outputs
    BANKSEL PORTC
    MOVLW 0x80
    MOVWF PORTC     ; Display Write HIGH

    ; Configure input and output pins
    BANKSEL TRISA
    BCF TRISA,1	    ; RA1 read diagnostic
    BCF TRISA,2     ; RA2 write diagnostic
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

    ; Initialize GPRs
    BANKSEL selected_value
    MOVLW 0x41
    MOVWF selected_value ; Start selection at A
    CLRF stored_value
    CLRF write_down
    CLRF select_down

    ; Wait until Write button is released
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease
    CALL Delay10ms  ; Debounce release
    BANKSEL PORTB
    BTFSS PORTB,1
    GOTO WaitStartupRelease

GOTO Main

Main:
    ; Check both buttons
    CALL CheckWrite
    CALL CheckSelect

    ; If Write is held, display the RAM selection
    BANKSEL write_down
    BTFSC write_down,0
    GOTO ShowSelection
    CALL ReadEEPROM ; Continuously read and display EEPROM

    ; Check for stored A
    BANKSEL stored_value
    MOVF stored_value,W
    XORLW 0x41
    BTFSC STATUS,2
    GOTO ShowStored

    ; Check for stored B
    MOVF stored_value,W
    XORLW 0x42
    BTFSC STATUS,2
    GOTO ShowStored

    ; Unknown EEPROM data displays ?
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

CheckWrite:
    BANKSEL PORTB
    BTFSC PORTB,1         ; HIGH means released
    GOTO WriteReleased

    ; Button is physically LOW
    BANKSEL write_down
    BTFSC write_down,0
    RETURN               ; Already registered as pressed

    ; Check that the press remains LOW after debounce
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,1
    RETURN               ; Bounce, not a valid press

    BANKSEL write_down
    BSF write_down,0     ; Enter selection mode
    RETURN               ; Do not write on press

WriteReleased:
    BANKSEL write_down
    BTFSS write_down,0
    RETURN               ; No earlier valid press

    ; Verify that the button stays released
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,1
    RETURN               ; Bounce, not a valid release

    BANKSEL write_down
    BCF write_down,0      ; End selection mode

    ; One completed press-and-release cycle
    CALL WriteEEPROM     ; Write exactly once
    RETURN

CheckSelect:
    BANKSEL PORTB
    BTFSC PORTB,0         ; HIGH means released
    GOTO SelectReleased

    ; Button is physically LOW
    BANKSEL select_down
    BTFSC select_down,0
    RETURN               ; Already registered as pressed
    CALL Delay10ms
    BANKSEL PORTB
    BTFSC PORTB,0
    RETURN               ; Invalid press due to bounce

    BANKSEL select_down
    BSF select_down,0    ; Remember valid press

    ; Only toggle while Write is being held
    BANKSEL write_down
    BTFSS write_down,0
    RETURN

    ; Check if the current selection is A
    MOVF selected_value,W
    XORLW 0x41
    BTFSC STATUS,2
    GOTO SelectB
    
    ; Otherwise select the Character "A"
    MOVLW 0x41		 
    MOVWF selected_value
    RETURN

SelectB:
    MOVLW 0x42		 ; Display the Character "B"
    MOVWF selected_value
    RETURN

SelectReleased:
    BANKSEL select_down
    BTFSS select_down,0
    RETURN               ; Already registered as released
    CALL Delay10ms
    BANKSEL PORTB
    BTFSS PORTB,0
    RETURN               ; Release was only bounce
    BANKSEL select_down
    BCF select_down,0
    RETURN
    
ReadEEPROM:
    ; Start read timing diagnostic
    BANKSEL PORTA
    BSF PORTA,1           ; RA1 HIGH

    ; Select EEPROM address 0x00
    BANKSEL EEADR
    MOVLW DATA_EE_ADDR
    MOVWF EEADR

    ; Select data EEPROM and begin reading
    BANKSEL EECON1
    BCF EECON1,7          ; EEPGD = 0
    BSF EECON1,0          ; RD = 1

    ; Read the saved data into RAM
    BANKSEL EEDAT
    MOVF EEDAT,W
    BANKSEL stored_value
    MOVWF stored_value

    ; Finish read diagnostic before display update
    BANKSEL PORTA
    BCF PORTA,1           ; RA1 LOW
    RETURN

WriteEEPROM:
    ; Begin write timing diagnostic
    BANKSEL PORTA
    BSF PORTA,2           ; RA2 HIGH

    ; Copy the pending selection into EEDAT
    BANKSEL selected_value
    MOVF selected_value,W
    BANKSEL EEDAT
    MOVWF EEDAT

    ; Set EEPROM destination address
    BANKSEL EEADR
    MOVLW DATA_EE_ADDR
    MOVWF EEADR

    ; Enable writing to data EEPROM
    BANKSEL EECON1
    BCF EECON1,7          ; EEPGD = 0
    BSF EECON1,2          ; WREN = 1

    ; Protect the EEPROM write-unlock sequence
    BCF INTCON,7          ; Global interrupts OFF

WaitGIEOff:
    BTFSC INTCON,7
    GOTO WaitGIEOff

    ; Required EEPROM unlock sequence
    MOVLW 0x55
    MOVWF EECON2
    MOVLW 0xAA
    MOVWF EECON2
    BSF EECON1,1          ; WR = 1, start writing

WaitForWrite:
    ; Wait for the EEPROM write to finish
    BTFSC EECON1,1
    GOTO WaitForWrite

    ; Disable further EEPROM writes
    BCF EECON1,2          ; WREN = 0

    ; Clear the EEPROM write-complete flag
    BANKSEL PIR2
    BCF PIR2,4            ; EEIF = 0

    ; End write diagnostic
    BANKSEL PORTA
    BCF PORTA,2           ; RA2 LOW
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