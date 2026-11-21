; ============================================================
; SUPER MARIO ENGINE - integrated state-machine revision
; 16-bit NASM / DOSBox, 8086 instructions, VGA Mode 13h.
;
; Required: mario.asm, assets.inc, items.inc, enemies.inc.
; ITEMS.INC includes ENEMIES.INC: do not include it twice.
; Build: nasm -f bin mario.asm -o MARIO.COM
;
; Menus: Up/Down and Enter. Esc: gameplay/pause -> title;
; title -> DOS. P pauses/resumes. Arrows move, Left Shift runs,
; Space jumps (hold for full height).
; Documented debug keys while playing: G tests form, T sets time
; to 5, C sets coins to 99, V toggles the frozen sprite gallery.
;
; Timer remains at BIOS rate (~18.2Hz). Position uses a whole-pixel
; word plus a 0..255 fractional word; velocity is signed 8.8.
; State handlers preserve registers; state/context changes are
; intentional outputs. Reusable drawing/physics uses stack inputs.
; This revision requires DOSBox gameplay validation before submission.
; ============================================================

bits 16
cpu 8086
org 100h

jmp start

; ------------------------------------------------------------
; Display and world constants
; ------------------------------------------------------------

SCREEN_W        equ 320
SCREEN_H        equ 200
VIDEO_SEG       equ 0A000h

MAP_W           equ 60
MAP_BYTES       equ 720
WORLD_W         equ 960
WORLD_H         equ 192

CAMERA_MAX      equ 640
PLAYER_MAX_X    equ 944
FRAME_WORDS     equ 32000

; ------------------------------------------------------------
; Keyboard scan codes
; ------------------------------------------------------------

K_ESC           equ 01h
K_LEFT          equ 4Bh
K_RIGHT         equ 4Dh
K_SHIFT         equ 2Ah
K_SPACE         equ 39h

K_P             equ 19h
K_R             equ 13h
K_G             equ 22h
K_V             equ 2Fh
K_B             equ 30h
K_ENTER         equ 1Ch

; ------------------------------------------------------------
; Physics constants
; ------------------------------------------------------------

ACCEL           equ 88
FRICTION        equ 44
WALK_LIMIT      equ 640
RUN_LIMIT       equ 1067

GRAVITY         equ 178
JUMP_SPEED      equ -2347
JUMP_CUT        equ -853
FALL_LIMIT      equ 1707

; ------------------------------------------------------------
; Hero/motion record offsets
; ------------------------------------------------------------

H_X             equ 0
H_XF            equ 2
H_Y             equ 4
H_YF            equ 6
H_VX            equ 8
H_VY            equ 10
H_GROUND        equ 12
H_FACE          equ 14
H_POSE          equ 16
H_HEIGHT        equ 18

H_BYTES         equ 20

; ------------------------------------------------------------
; Memory and interrupt state
; ------------------------------------------------------------

buffer_seg:
    dw 0

old_keyboard:
    dd 0

old_timer:
    dd 0

ticks:
    dw 0

last_tick:
    dw 0

elapsed_ticks:
    dw 0

; ------------------------------------------------------------
; Camera and clock
; ------------------------------------------------------------

camera_x:
    dw 0

time_left:
    dw 300

second_low:
    dw 0

second_high:
    dw 0

; ------------------------------------------------------------
; Development state
; ------------------------------------------------------------

gallery:
    db 0

blink_demo:
    db 0

; ------------------------------------------------------------
; Keyboard tables
; ------------------------------------------------------------

keys:
    times 128 db 0

frame_keys:
    times 128 db 0

previous_keys:
    times 128 db 0

; ------------------------------------------------------------
; Hero and working map
; ------------------------------------------------------------

spawn_hero:
    dw 32,0,144,0,0,0,1,0,0,16

hero:
    times H_BYTES db 0

working_map:
    times MAP_BYTES db 0

; ------------------------------------------------------------
; Messages
; ------------------------------------------------------------

memory_error:
    db 'Unable to allocate frame buffer.',13,10,'$'

exit_message:
    db 'Keyboard and timer restored. Game exited cleanly.'
    db 13,10,'$'

; ------------------------------------------------------------
; Decimal font
; Each digit has five rows, using the low three bits.
; ------------------------------------------------------------

digit_font:
    db 7,5,5,5,7
    db 2,6,2,2,7
    db 7,1,7,4,7
    db 7,1,7,1,7
    db 5,5,7,1,1
    db 7,4,7,1,7
    db 7,4,7,5,7
    db 7,1,1,1,1
    db 7,5,7,5,7
    db 7,5,7,1,7

; ------------------------------------------------------------
; Entry point: start
; Purpose:
;   Initialize resources, install handlers, and run the game
;   development loop.
; Inputs:
;   None.
; Outputs:
;   Graphics display and clean DOS termination.
; Registers changed:
;   Main-program working registers; does not return.
; ------------------------------------------------------------


; State handlers own the game context. Parameterized drawing/physics
; procedures below preserve registers and receive stack arguments.
%macro SAVE_CONTEXT 0
    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
%endmacro
%macro RESTORE_CONTEXT 0
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
%endmacro

%macro TEXT 5
    push ax
    mov ax,%5
    push ax
    mov ax,%4
    push ax
    mov ax,%3
    push ax
    mov ax,%2
    push ax
    mov ax,%1
    push ax
    call DrawText
    pop ax
%endmacro
%macro VALUE 5
    push ax
    mov ax,%5
    push ax
    mov ax,%4
    push ax
    mov ax,%3
    push ax
    mov ax,%2
    push ax
    mov ax,%1
    push ax
    call DrawHUDValue
    pop ax
%endmacro
%macro PRESS 2
    cmp byte [frame_keys+%1],0
    jne %%held
    jmp near %2
%%held:
    cmp byte [previous_keys+%1],0
    je %%fresh
    jmp near %2
%%fresh:
%endmacro
ST_TITLE equ 0
ST_PLAY equ 1
ST_PAUSE equ 2
ST_DYING equ 3
ST_LIFE equ 4
ST_WIN equ 5
ST_COMPLETE equ 6
ST_OVER equ 7
ST_EXIT equ 8
K_UP equ 48h
K_DOWN equ 50h
K_T equ 14h
K_C equ 2Eh

state dw ST_TITLE
state_ticks dw 0
pending_ticks dw 0
menu_choice dw 0
visual_ticks dw 0
saved_hero_y dw 0
saved_hero_vy dw 0
finish_time dw 0
time_bonus dw 0
flag_reward dw 0
hide_hero db 0
state_updates:
    dw StateTitle,StatePlaying,StatePaused,StateDying,StateLifeLost
    dw StateWinning,StateEndScreen,StateEndScreen,StateExit

; Entry: reserve a complete 64-K segment and a separate 64000-byte
; frame buffer; install hooks only after allocation succeeds.
start:
    cli
    mov ax,cs
    mov ss,ax
    mov sp,0FFFEh
    sti
    mov ds,ax
    mov es,ax
    cld
    mov bx,1000h
    mov ah,4Ah
    int 21h
    jnc short .branch_bridge_1
    jmp near MemoryError
.branch_bridge_1:
    mov bx,0FA0h
    mov ah,48h
    int 21h
    jnc short .branch_bridge_2
    jmp near MemoryError
.branch_bridge_2:
    mov [buffer_seg],ax
    call NewGame
    mov word [state],ST_TITLE
    mov ax,0013h
    int 10h
    mov ax,3509h
    int 21h
    mov [old_keyboard],bx
    mov [old_keyboard+2],es
    mov ax,351Ch
    int 21h
    mov [old_timer],bx
    mov [old_timer+2],es
    mov dx,TimerHandler
    mov ax,251Ch
    int 21h
    mov dx,KeyboardHandler
    mov ax,2509h
    int 21h
    mov ax,[ticks]
    mov [last_tick],ax
.wait:
    cli
    mov ax,[ticks]
    cmp ax,[last_tick]
    je short .branch_bridge_3
    jmp near .ready
.branch_bridge_3:
    sti
    hlt
    jmp .wait
.ready:
    sub ax,[last_tick]
    mov [pending_ticks],ax
    mov ax,[ticks]
    mov [last_tick],ax
    push ds
    pop es
    mov si,keys
    mov di,frame_keys
    mov cx,128
    cld
    rep movsb
    sti
.step:
    mov bx,[state]
    shl bx,1
    call word [state_updates+bx]
    ; Copy after EACH simulated tick: held keys cannot retrigger menus.
    mov ax,128
    push ax
    mov ax,frame_keys
    push ax
    mov ax,previous_keys
    push ax
    call CopyBytes
    dec word [pending_ticks]
    jz short .branch_bridge_4
    jmp near .step
.branch_bridge_4:
    call RenderGame
    jmp .wait

; NewGame: clear persistent counters, then restore all level state.
; Input/output: game context. Preserves registers/flags.
NewGame:
    SAVE_CONTEXT
    mov word [item_state+IT_SCORE_LO],0
    mov word [item_state+IT_SCORE_HI],0
    mov word [item_state+IT_COINS],0
    mov word [item_state+IT_LIVES],3
    call ResetLevel
    RESTORE_CONTEXT
    ret
; ResetLevel: preserve score/coins/lives; restore map with REP MOVSB,
; hero, enemies, items, clock and camera. Preserves registers/flags.
ResetLevel:
    SAVE_CONTEXT
    mov ax,MAP_BYTES
    push ax
    mov ax,original_map
    push ax
    mov ax,working_map
    push ax
    call CopyBytes
    mov ax,H_BYTES
    push ax
    mov ax,spawn_hero
    push ax
    mov ax,hero
    push ax
    call CopyBytes
    mov ax,item_state
    push ax
    call ResetItemLevel
    mov word [camera_x],0
    mov word [time_left],300
    mov word [second_low],0
    mov word [second_high],0
    mov word [state_ticks],0
    mov byte [blink_demo],0
    mov byte [gallery],0
    mov byte [hide_hero],0
    mov word [visual_ticks],0
    RESTORE_CONTEXT
    ret
; StateTitle: edge-triggered Up/Down, Enter and Esc.
StateTitle:
    SAVE_CONTEXT
    PRESS K_ESC,.up
    mov word [state],ST_EXIT
    RESTORE_CONTEXT
    ret
.up:
    PRESS K_UP,.down
    xor word [menu_choice],1
.down:
    PRESS K_DOWN,.enter
    xor word [menu_choice],1
.enter:
    PRESS K_ENTER,.done
    cmp word [menu_choice],0
    je short .branch_bridge_5
    jmp near .exit
.branch_bridge_5:
    call NewGame
    mov word [state],ST_PLAY
    RESTORE_CONTEXT
    ret
.exit:
    mov word [state],ST_EXIT
.done:
    RESTORE_CONTEXT
    ret
; StatePlaying: exactly one fixed-timestep physics update per BIOS tick.
; Items already update/draw enemies: never duplicate those calls.
StatePlaying:
    SAVE_CONTEXT
    PRESS K_ESC,.pause
    mov word [state],ST_TITLE
    mov word [menu_choice],0
    RESTORE_CONTEXT
    ret
.pause:
    PRESS K_P,.debug
    mov word [state],ST_PAUSE
    RESTORE_CONTEXT
    ret
.debug:
    ; Documented viva helpers: T -> 5 seconds, C -> 99 coins.
    PRESS K_T,.coins
    mov word [time_left],5
    mov word [second_low],0
    mov word [second_high],0
.coins:
    PRESS K_C,.gallery_key
    mov word [item_state+IT_COINS],99
.gallery_key:
    PRESS K_V,.gallery_check
    xor byte [gallery],1
.gallery_check:
    cmp byte [gallery],0
    je short .branch_bridge_6
    jmp near .done
.branch_bridge_6:
    PRESS K_G,.move
    cmp word [hero+H_HEIGHT],16
    je short .branch_bridge_7
    jmp near .small
.branch_bridge_7:
    cmp word [hero+H_Y],32
    jge short .branch_bridge_8
    jmp near .move
.branch_bridge_8:
    ; Use the same upper-corner clearance tests as ordinary collision.
    mov ax,[hero+H_Y]
    sub ax,16
    push ax
    mov ax,[hero+H_X]
    add ax,2
    push ax
    mov ax,working_map
    push ax
    call GetTile
    cmp ax,1
    jae short .branch_bridge_9
    jmp near .right_clearance
.branch_bridge_9:
    cmp ax,10
    ja short .branch_bridge_10
    jmp near .move
.branch_bridge_10:
.right_clearance:
    mov ax,[hero+H_Y]
    sub ax,16
    push ax
    mov ax,[hero+H_X]
    add ax,13
    push ax
    mov ax,working_map
    push ax
    call GetTile
    cmp ax,1
    jae short .branch_bridge_11
    jmp near .grow
.branch_bridge_11:
    cmp ax,10
    ja short .branch_bridge_12
    jmp near .move
.branch_bridge_12:
.grow:
    sub word [hero+H_Y],16
    mov word [hero+H_HEIGHT],32
    jmp .move
.small:
    add word [hero+H_Y],16
    mov word [hero+H_HEIGHT],16
.move:
    inc word [visual_ticks]
    mov ax,previous_keys
    push ax
    mov ax,frame_keys
    push ax
    mov ax,working_map
    push ax
    mov ax,hero
    push ax
    call UpdateHero
    cmp word [hero+H_Y],WORLD_H
    jl short .branch_bridge_13
    jmp near .pit
.branch_bridge_13:
    mov ax,[hero+H_Y]
    mov [saved_hero_y],ax
    mov ax,[hero+H_VY]
    mov [saved_hero_vy],ax
    mov ax,[camera_x]
    push ax
    mov ax,item_state
    push ax
    mov ax,working_map
    push ax
    mov ax,hero
    push ax
    call UpdateItems
    cmp word [item_state+IT_DEAD],0
    je short .branch_bridge_14
    jmp near .enemy_death
.branch_bridge_14:
    ; BIOS period is 65536 / 1193182 seconds. Accumulate clocks exactly.
    inc word [second_high]
    cmp word [second_high],12h
    jae short .branch_bridge_15
    jmp near .flag
.branch_bridge_15:
    jbe short .branch_bridge_16
    jmp near .second
.branch_bridge_16:
    cmp word [second_low],34DEh
    jae short .branch_bridge_17
    jmp near .flag
.branch_bridge_17:
.second:
    sub word [second_low],34DEh
    sbb word [second_high],12h
    cmp word [time_left],0
    jne short .branch_bridge_18
    jmp near .timeout
.branch_bridge_18:
    dec word [time_left]
    jnz short .branch_bridge_19
    jmp near .timeout
.branch_bridge_19:
.flag:
    ; Actual pole is at x=56*16+7, y=32..143.
    mov ax,[hero+H_X]
    add ax,14
    cmp ax,903
    jg short .branch_bridge_20
    jmp near .camera
.branch_bridge_20:
    sub ax,12
    cmp ax,905
    jl short .branch_bridge_21
    jmp near .camera
.branch_bridge_21:
    mov ax,[hero+H_Y]
    cmp ax,144
    jl short .branch_bridge_22
    jmp near .camera
.branch_bridge_22:
    add ax,[hero+H_HEIGHT]
    cmp ax,32
    jg short .branch_bridge_23
    jmp near .camera
.branch_bridge_23:
    call BeginWin
    RESTORE_CONTEXT
    ret
.camera:
    mov ax,camera_x
    push ax
    mov ax,hero
    push ax
    call UpdateCamera
.done:
    RESTORE_CONTEXT
    ret
.pit:
    mov ax,1
    push ax
    call BeginDeath
    RESTORE_CONTEXT
    ret
.enemy_death:
    ; Enemy module marks Y=192; recover the visible contact position.
    mov ax,[saved_hero_y]
    mov [hero+H_Y],ax
.timeout:
    xor ax,ax
    push ax
    call BeginDeath
    RESTORE_CONTEXT
    ret
; StatePaused: update nothing except P/Esc edges.
StatePaused:
    SAVE_CONTEXT
    PRESS K_ESC,.resume
    mov word [state],ST_TITLE
    mov word [menu_choice],0
    RESTORE_CONTEXT
    ret
.resume:
    PRESS K_P,.done
    mov word [state],ST_PLAY
.done:
    RESTORE_CONTEXT
    ret
; BeginDeath(pit): [BP+4] nonzero skips hop; ret 2.
; Preserves AX, flags and BP; game context changes intentionally.
BeginDeath:
    push bp
    mov bp,sp
    pushf
    push ax
    mov word [state],ST_DYING
    mov word [state_ticks],28
    mov word [hero+H_POSE],2
    mov word [hero+H_VX],0
    mov word [hero+H_YF],0
    mov byte [blink_demo],0
    cmp word [bp+4],0
    je short .branch_bridge_24
    jmp near .fall
.branch_bridge_24:
    mov word [hero+H_VY],-3264
    jmp .done
.fall:
    mov word [hero+H_VY],1707
.done:
    pop ax
    popf
    pop bp
    ret 2

; StateDying: 28 ticks (~1.54s), no tile/entity collisions or clock.
StateDying:
    SAVE_CONTEXT
    mov ax,[hero+H_VY]
    add ax,384
    mov [hero+H_VY],ax
    add ax,[hero+H_YF]
    mov dx,ax
    and dx,255
    mov [hero+H_YF],dx
    mov cl,8
    sar ax,cl
    add [hero+H_Y],ax
    dec word [state_ticks]
    jz short .branch_bridge_25
    jmp near .done
.branch_bridge_25:
    cmp word [item_state+IT_LIVES],0
    jne short .branch_bridge_26
    jmp near .over
.branch_bridge_26:
    dec word [item_state+IT_LIVES]
    jnz short .branch_bridge_27
    jmp near .over
.branch_bridge_27:
    mov word [state],ST_LIFE
    mov word [state_ticks],36
    RESTORE_CONTEXT
    ret
.over:
    mov word [state],ST_OVER
.done:
    RESTORE_CONTEXT
    ret
; StateLifeLost: 36 ticks (~1.98s), then restore level only.
StateLifeLost:
    SAVE_CONTEXT
    dec word [state_ticks]
    jz short .branch_bridge_28
    jmp near .done
.branch_bridge_28:
    call ResetLevel
    mov word [state],ST_PLAY
.done:
    RESTORE_CONTEXT
    ret
; BeginWin: score from feet row, save remaining time, snap to pole.
; Called by state engine; preserves registers/flags.
BeginWin:
    SAVE_CONTEXT
    mov ax,[hero+H_Y]
    add ax,[hero+H_HEIGHT]
    mov cl,4
    shr ax,cl
    mov bx,5000
    cmp ax,3
    ja short .branch_bridge_29
    jmp near .points
.branch_bridge_29:
    mov bx,2000
    cmp ax,4
    jne short .branch_bridge_30
    jmp near .points
.branch_bridge_30:
    mov bx,800
    cmp ax,5
    jne short .branch_bridge_31
    jmp near .points
.branch_bridge_31:
    mov bx,400
    cmp ax,6
    jne short .branch_bridge_32
    jmp near .points
.branch_bridge_32:
    mov bx,100
.points:
    mov [flag_reward],bx
    push bx
    mov ax,item_state
    push ax
    call AddScore
    mov ax,[time_left]
    mov [finish_time],ax
    mov bx,50
    mul bx
    mov [time_bonus],ax
    mov word [hero+H_X],890
    mov word [hero+H_FACE],0
    mov word [hero+H_POSE],0
    mov word [state_ticks],0
    mov byte [blink_demo],0
    mov word [state],ST_WIN
    mov word [camera_x],CAMERA_MAX
    RESTORE_CONTEXT
    ret
; StateWinning: 18-tick slide + 18-tick walk; then apply time bonus ONCE.
StateWinning:
    SAVE_CONTEXT
    cmp word [state_ticks],18
    jb short .branch_bridge_33
    jmp near .walk
.branch_bridge_33:
    mov ax,144
    sub ax,[hero+H_HEIGHT]
    sub ax,[hero+H_Y]
    jg short .branch_bridge_34
    jmp near .base
.branch_bridge_34:
    mov bx,18
    sub bx,[state_ticks]
    add ax,bx
    dec ax
    xor dx,dx
    div bx
    add [hero+H_Y],ax
    jmp .tick
.base:
    mov ax,144
    sub ax,[hero+H_HEIGHT]
    mov [hero+H_Y],ax
    jmp .tick
.walk:
    mov ax,144
    sub ax,[hero+H_HEIGHT]
    mov [hero+H_Y],ax
    add word [hero+H_X],2
    mov word [hero+H_POSE],1
.tick:
    inc word [state_ticks]
    cmp word [state_ticks],36
    jae short .branch_bridge_35
    jmp near .done
.branch_bridge_35:
    mov byte [hide_hero],1
    mov ax,[time_bonus]
    push ax
    mov ax,item_state
    push ax
    call AddScore
    mov word [state],ST_COMPLETE
.done:
    RESTORE_CONTEXT
    ret
; StateEndScreen: Enter returns to title, new game starts ONLY at START.
StateEndScreen:
    SAVE_CONTEXT
    PRESS K_ENTER,.done
    mov word [state],ST_TITLE
    mov word [menu_choice],0
.done:
    RESTORE_CONTEXT
    ret
; StateExit: restore both hooks before freeing buffer and returning DOS.
StateExit:
    mov dx,[old_keyboard]
    mov ax,[old_keyboard+2]
    push ds
    mov ds,ax
    mov ax,2509h
    int 21h
    pop ds
    mov dx,[old_timer]
    mov ax,[old_timer+2]
    push ds
    mov ds,ax
    mov ax,251Ch
    int 21h
    pop ds
    mov ax,[buffer_seg]
    mov es,ax
    mov ah,49h
    int 21h
    mov ax,0003h
    int 10h
    mov dx,exit_message
    mov ah,09h
    int 21h
    mov ax,4C00h
    int 21h


KeyboardHandler:
    push ax
    push bx
    push ds

    push cs
    pop ds

    in al, 60h

    cmp al, 0E0h
    jne short .branch_bridge_36
    jmp near .ack
.branch_bridge_36:

    mov ah, al
    and al, 7Fh

    xor bx, bx
    mov bl, al

    mov al, 1
    test ah, 80h
    jnz short .branch_bridge_37
    jmp near .store
.branch_bridge_37:

    xor al, al

.store:
    mov [keys + bx], al

.ack:
    ; Legacy keyboard acknowledge, preserving other bits.
    in al, 61h
    mov ah, al

    or al, 80h
    out 61h, al

    mov al, ah
    out 61h, al

    ; End of interrupt to the master PIC.
    mov al, 20h
    out 20h, al

    pop ds
    pop bx
    pop ax

    iret

; ------------------------------------------------------------
; Interrupt handler: TimerHandler
; Purpose:
;   Count timer ticks and chain the original INT 1Ch hook.
; Inputs:
;   BIOS timer context.
; Outputs:
;   ticks incremented.
; Registers changed:
;   None. Incoming flags restored before chaining.
; ------------------------------------------------------------

TimerHandler:
    pushf
    inc word [cs:ticks]
    popf

    jmp far [cs:old_timer]

; ------------------------------------------------------------
; Procedure: CopyBytes
; Purpose:
;   Copy a byte block within the program segment.
; Inputs:
;   [BP+4]=destination, +6=source, +8=count.
; Outputs:
;   Destination block replaced.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

CopyBytes:
    push bp
    mov bp, sp

    pushf
    push cx
    push si
    push di
    push es

    push ds
    pop es

    mov di, [bp + 4]
    mov si, [bp + 6]
    mov cx, [bp + 8]

    cld
    rep movsb

    pop es
    pop di
    pop si
    pop cx
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: UpdateHero
; Purpose:
;   Apply horizontal acceleration, friction, jump control,
;   gravity, and axis-separated tile collision.
; Inputs:
;   [BP+4]=hero, +6=map,
;   +8=current key table, +10=previous key table.
; Outputs:
;   Hero motion record updated.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 8 bytes.
; ------------------------------------------------------------

UpdateHero:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, [bp + 4]
    mov di, [bp + 8]

    ; Shift changes the horizontal speed limit.
    mov bx, WALK_LIMIT

    cmp byte [di + K_SHIFT], 0
    jne short .branch_bridge_38
    jmp near .speed_ready
.branch_bridge_38:

    mov bx, RUN_LIMIT

.speed_ready:
    ; Opposing held directions cancel into friction.
    cmp byte [di + K_RIGHT], 0
    jne short .branch_bridge_39
    jmp near .check_left
.branch_bridge_39:

    cmp byte [di + K_LEFT], 0
    je short .branch_bridge_40
    jmp near .friction
.branch_bridge_40:

    jmp .right

.check_left:
    cmp byte [di + K_LEFT], 0
    je short .branch_bridge_41
    jmp near .left
.branch_bridge_41:

.friction:
    mov ax, [si + H_VX]
    or ax, ax
    jnz short .branch_bridge_42
    jmp near .jump_check
.branch_bridge_42:

    jns short .branch_bridge_43
    jmp near .negative_friction
.branch_bridge_43:

    sub ax, FRICTION
    js short .branch_bridge_44
    jmp near .store_velocity
.branch_bridge_44:

    xor ax, ax
    jmp .store_velocity

.negative_friction:
    add ax, FRICTION
    jns short .branch_bridge_45
    jmp near .store_velocity
.branch_bridge_45:

    xor ax, ax
    jmp .store_velocity

.right:
    mov word [si + H_FACE], 0
    mov ax, [si + H_VX]

    ; Reversing direction brakes faster than passive friction.
    cmp ax, 0
    jl short .branch_bridge_46
    jmp near .right_acceleration
.branch_bridge_46:

    add ax, ACCEL

.right_acceleration:
    add ax, ACCEL

    cmp ax, bx
    jg short .branch_bridge_47
    jmp near .store_velocity
.branch_bridge_47:

    mov ax, bx
    jmp .store_velocity

.left:
    mov word [si + H_FACE], 1
    mov ax, [si + H_VX]

    cmp ax, 0
    jg short .branch_bridge_48
    jmp near .left_acceleration
.branch_bridge_48:

    sub ax, ACCEL

.left_acceleration:
    sub ax, ACCEL
    neg bx

    cmp ax, bx
    jl short .branch_bridge_49
    jmp near .store_velocity
.branch_bridge_49:

    mov ax, bx

.store_velocity:
    mov [si + H_VX], ax

.jump_check:
    cmp byte [di + K_SPACE], 0
    jne short .branch_bridge_50
    jmp near .cut_jump
.branch_bridge_50:

    ; A new press is required for a new jump.
    mov bx, [bp + 10]

    cmp byte [bx + K_SPACE], 0
    je short .branch_bridge_51
    jmp near .gravity
.branch_bridge_51:

    cmp word [si + H_GROUND], 0
    jne short .branch_bridge_52
    jmp near .gravity
.branch_bridge_52:

    mov word [si + H_VY], JUMP_SPEED
    mov word [si + H_GROUND], 0
    jmp .gravity

.cut_jump:
    ; Releasing Space limits the remaining upward speed.
    cmp word [si + H_VY], JUMP_CUT
    jl short .branch_bridge_53
    jmp near .gravity
.branch_bridge_53:

    mov word [si + H_VY], JUMP_CUT

.gravity:
    mov ax, [si + H_VY]
    add ax, GRAVITY

    cmp ax, FALL_LIMIT
    jg short .branch_bridge_54
    jmp near .fall_speed_ready
.branch_bridge_54:

    mov ax, FALL_LIMIT

.fall_speed_ready:
    mov [si + H_VY], ax

    ; Horizontal motion and correction first.
    mov ax, [bp + 6]
    push ax

    push si
    call MoveHorizontal

    ; Vertical motion and correction second.
    mov ax, [bp + 6]
    push ax

    push si
    call MoveVertical

    ; Pose is derived from grounded state and movement.
    mov word [si + H_POSE], 2

    cmp word [si + H_GROUND], 0
    jne short .branch_bridge_55
    jmp near .done
.branch_bridge_55:

    mov word [si + H_POSE], 0

    cmp word [si + H_VX], 0
    jne short .branch_bridge_56
    jmp near .done
.branch_bridge_56:

    mov word [si + H_POSE], 1

.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 8

; ------------------------------------------------------------
; Procedure: MoveHorizontal
; Purpose:
;   Integrate x and resolve a centred 12-pixel hitbox
;   against every tile row along its side.
; Inputs:
;   [BP+4]=motion record, +6=map.
; Outputs:
;   X position, fraction, and velocity corrected.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

MoveHorizontal:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, [bp + 4]

    ; Fractional integration and signed normalization.
    mov ax, [si + H_XF]
    add ax, [si + H_VX]

    mov dx, ax
    and dx, 255
    mov [si + H_XF], dx

    mov cl, 8
    sar ax, cl
    add [si + H_X], ax

    ; Absolute left world boundary.
    cmp word [si + H_X], 0
    jl short .branch_bridge_57
    jmp near .check_right_edge
.branch_bridge_57:

    mov word [si + H_X], 0
    mov word [si + H_XF], 0
    mov word [si + H_VX], 0

.check_right_edge:
    cmp word [si + H_X], PLAYER_MAX_X
    jg short .branch_bridge_58
    jmp near .scan_setup
.branch_bridge_58:

    mov word [si + H_X], PLAYER_MAX_X
    mov word [si + H_XF], 0
    mov word [si + H_VX], 0

.scan_setup:
    cmp word [si + H_VX], 0
    je short .branch_bridge_59
    jmp near .moving
.branch_bridge_59:

    jmp .done

.moving:
    ; Left hitbox edge starts at sprite x+2.
    mov bx, [si + H_X]
    add bx, 2

    cmp word [si + H_VX], 0
    jge short .branch_bridge_60
    jmp near .side_ready
.branch_bridge_60:

    ; Right inclusive hitbox edge is sprite x+13.
    add bx, 11

.side_ready:
    mov dx, [si + H_Y]
    and dx, 0FFF0h

    mov di, [si + H_Y]
    add di, [si + H_HEIGHT]
    dec di

.scan:
    push dx
    push bx

    mov ax, [bp + 6]
    push ax

    call GetTile

    cmp ax, 1
    jae short .branch_bridge_61
    jmp near .next_row
.branch_bridge_61:

    cmp ax, 10
    ja short .branch_bridge_62
    jmp near .hit
.branch_bridge_62:

.next_row:
    add dx, 16
    cmp dx, di
    jg short .branch_bridge_63
    jmp near .scan
.branch_bridge_63:

    jmp .done

.hit:
    mov ax, bx
    and ax, 0FFF0h

    cmp word [si + H_VX], 0
    jge short .branch_bridge_64
    jmp near .hit_left
.branch_bridge_64:

    ; Place the exclusive right edge at the tile's left edge.
    sub ax, 14
    jmp .correct

.hit_left:
    ; Place the left hitbox edge at the tile's right edge.
    add ax, 14

.correct:
    mov [si + H_X], ax
    mov word [si + H_XF], 0
    mov word [si + H_VX], 0

.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: MoveVertical
; Purpose:
;   Integrate y, resolve head/feet collisions, and trigger
;   the centre head block when rising into a solid tile.
; Inputs:
;   [BP+4]=motion record, +6=map.
; Outputs:
;   Y position, fraction, velocity, and grounded corrected.
;   Head hits invoke TriggerBlock for upward-moving records.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

MoveVertical:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, [bp + 4]
    mov word [si + H_GROUND], 0

    ; Fractional integration and signed normalization.
    mov ax, [si + H_YF]
    add ax, [si + H_VY]

    mov dx, ax
    and dx, 255
    mov [si + H_YF], dx

    mov cl, 8
    sar ax, cl
    add [si + H_Y], ax

    ; Keep the top of the sprite below the reserved HUD.
    cmp word [si + H_Y], 16
    jl short .branch_bridge_65
    jmp near .probe_setup
.branch_bridge_65:

    mov word [si + H_Y], 16
    mov word [si + H_YF], 0
    mov word [si + H_VY], 0
    jmp .done

.probe_setup:
    mov dx, [si + H_Y]

    cmp word [si + H_VY], 0
    jge short .branch_bridge_66
    jmp near .probe
.branch_bridge_66:

    ; Feet use the lower boundary for stable floor support.
    add dx, [si + H_HEIGHT]

.probe:
    mov bx, [si + H_X]
    add bx, 2

    ; First corner.
    push dx
    push bx

    mov ax, [bp + 6]
    push ax

    call GetTile

    cmp ax, 1
    jae short .branch_bridge_67
    jmp near .right_probe
.branch_bridge_67:

    cmp ax, 10
    ja short .branch_bridge_68
    jmp near .hit
.branch_bridge_68:

.right_probe:
    ; Second corner.
    add bx, 11

    push dx
    push bx

    mov ax, [bp + 6]
    push ax

    call GetTile

    cmp ax, 1
    jae short .branch_bridge_69
    jmp near .done
.branch_bridge_69:

    cmp ax, 10
    jbe short .branch_bridge_70
    jmp near .done
.branch_bridge_70:

.hit:
    mov ax, dx
    and ax, 0FFF0h

    cmp word [si + H_VY], 0
    jge short .branch_bridge_71
    jmp near .head
.branch_bridge_71:

    ; Land on the tile.
    sub ax, [si + H_HEIGHT]
    mov word [si + H_GROUND], 1
    jmp .correct

.head:
    ; Preserve the tile-row correction value in AX.
    push ax

    ; TriggerBlock(hero,map,head-centre-x,probe-y,state).
    mov ax, item_state
    push ax

    push dx

    mov ax, [si + H_X]
    add ax, 8
    push ax

    mov ax, [bp + 6]
    push ax

    push si
    call TriggerBlock

    pop ax

    ; Place the top immediately below the struck tile.
    add ax, 16

.correct:
    mov [si + H_Y], ax
    mov word [si + H_YF], 0
    mov word [si + H_VY], 0

.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: UpdateCamera
; Purpose:
;   Follow the hero beyond screen x=160, never moving left.
; Inputs:
;   [BP+4]=hero, +6=camera word address.
; Outputs:
;   Camera updated; hero stopped at the camera's left edge.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

UpdateCamera:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push si
    push di

    mov si, [bp + 4]
    mov di, [bp + 6]

    mov ax, [si + H_X]

    cmp ax, [di]
    jl short .branch_bridge_72
    jmp near .left_ready
.branch_bridge_72:

    mov ax, [di]
    mov [si + H_X], ax
    mov word [si + H_XF], 0
    mov word [si + H_VX], 0

.left_ready:
    mov bx, ax
    sub bx, [di]

    cmp bx, 160
    jg short .branch_bridge_73
    jmp near .done
.branch_bridge_73:

    sub ax, 160

    cmp ax, CAMERA_MAX
    jg short .branch_bridge_74
    jmp near .maximum_ready
.branch_bridge_74:

    mov ax, CAMERA_MAX

.maximum_ready:
    cmp ax, [di]
    jg short .branch_bridge_75
    jmp near .done
.branch_bridge_75:

    mov [di], ax

.done:
    pop di
    pop si
    pop bx
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: GetTile
; Purpose:
;   Convert world-pixel coordinates into a map lookup.
; Inputs:
;   [BP+4]=map, +6=world x, +8=world y.
; Outputs:
;   AX=zero-extended tile code.
;   Out-of-map coordinates return sky.
; Registers changed:
;   AX only. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

GetTile:
    push bp
    mov bp, sp

    pushf
    push bx
    push cx
    push dx
    push si

    mov ax, [bp + 6]
    cmp ax, WORLD_W
    jb short .branch_bridge_76
    jmp near .outside
.branch_bridge_76:

    mov dx, [bp + 8]
    cmp dx, WORLD_H
    jb short .branch_bridge_77
    jmp near .outside
.branch_bridge_77:

    ; Column = x/16.
    mov cl, 4
    shr ax, cl
    mov bx, ax

    ; Row = y/16.
    shr dx, cl

    ; Row*60 = row*64 - row*4.
    mov ax, dx

    mov cl, 6
    shl ax, cl

    shl dx, 1
    shl dx, 1

    sub ax, dx
    add bx, ax

    mov si, [bp + 4]

    xor ax, ax
    mov al, [si + bx]
    jmp .done

.outside:
    xor ax, ax

.done:
    pop si
    pop dx
    pop cx
    pop bx
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: DrawMap
; Purpose:
;   Render visible map rows using 21 clipped tile columns.
; Inputs:
;   [BP+4]=map, +6=camera x.
;   ES=frame-buffer segment.
; Outputs:
;   Visible tiles rendered with pixel-offset scrolling.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

DrawMap:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov dx, 16
    mov di, 11

.row:
    ; First world column begins at camera rounded down to 16.
    mov si, [bp + 6]
    and si, 0FFF0h

    ; First screen column starts at the negative pixel offset.
    mov bx, [bp + 6]
    and bx, 15
    neg bx

    mov cx, 21

.column:
    push dx
    push si

    mov ax, [bp + 4]
    push ax

    call GetTile

    push ax
    push dx
    push bx

    call DrawTile

    add si, 16
    add bx, 16

    loop .column

    add dx, 16
    dec di
    jz short .branch_bridge_78
    jmp near .row
.branch_bridge_78:

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: DrawTile
; Purpose:
;   Render one tile using clipped rectangles or a coin sprite.
; Inputs:
;   [BP+4]=x, +6=y, +8=tile code.
;   ES=frame-buffer segment.
; Outputs:
;   Tile artwork rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

DrawTile:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push dx
    push si

    mov si, [bp + 8]

    cmp si, 0
    je short .branch_bridge_79
    jmp near .visible
.branch_bridge_79:
    jmp .done

.visible:
    cmp si, 12
    ja short .branch_bridge_80
    jmp near .valid
.branch_bridge_80:
    jmp .done

.valid:
    mov bx, [bp + 4]
    mov dx, [bp + 6]

    cmp si, 11
    je short .branch_bridge_81
    jmp near .check_flag
.branch_bridge_81:

    xor ax, ax
    push ax

    mov ax, sprite_coin
    push ax

    push dx
    push bx

    call DrawSprite
    jmp .done

.check_flag:
    cmp si, 12
    je short .branch_bridge_82
    jmp near .solid
.branch_bridge_82:

    jmp .flag

.solid:
    ; Black outside border.
    xor ax, ax
    push ax

    mov ax, 16
    push ax
    push ax

    push dx
    push bx

    call FillRect

    ; Coloured inside.
    inc bx
    inc dx

    xor ax, ax
    mov al, [tile_colours + si]
    push ax

    mov ax, 14
    push ax
    push ax

    push dx
    push bx

    call FillRect

    cmp si, 1
    je short .branch_bridge_83
    jmp near .brick_check
.branch_bridge_83:

    cmp word [bp + 6], 160
    jne short .branch_bridge_84
    jmp near .grass
.branch_bridge_84:

    jmp .done

.brick_check:
    cmp si, 2
    jne short .branch_bridge_85
    jmp near .brick
.branch_bridge_85:

    cmp si, 3
    jne short .branch_bridge_86
    jmp near .question
.branch_bridge_86:

    cmp si, 4
    jne short .branch_bridge_87
    jmp near .question
.branch_bridge_87:

    jmp .done

.grass:
    mov ax, 10
    push ax

    mov ax, 3
    push ax

    mov ax, 14
    push ax

    push dx
    push bx

    call FillRect
    jmp .done

.brick:
    add dx, 6

    xor ax, ax
    push ax

    mov ax, 1
    push ax

    mov ax, 14
    push ax

    push dx
    push bx

    call FillRect
    jmp .done

.question:
    add bx, 5
    add dx, 3

    xor ax, ax
    push ax

    mov ax, 5
    push ax

    mov ax, 3
    push ax

    push dx
    push bx

    call FillRect

    add dx, 7

    xor ax, ax
    push ax

    mov ax, 2
    push ax
    push ax

    push dx
    push bx

    call FillRect
    jmp .done

.flag:
    add bx, 7

    mov ax, 10
    push ax

    mov ax, 16
    push ax

    mov ax, 2
    push ax

    push dx
    push bx

    call FillRect

    cmp word [bp + 6], 32
    jne short .branch_bridge_88
    jmp near .pennant
.branch_bridge_88:

    jmp .done

.pennant:
    sub bx, 6
    add dx, 2

    mov ax, 15
    push ax

    mov ax, 5
    push ax

    mov ax, 6
    push ax

    push dx
    push bx

    call FillRect

.done:
    pop si
    pop dx
    pop bx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: PutPixel
; Purpose:
;   Write one pixel only when inside physical screen bounds.
; Inputs:
;   [BP+4]=x, +6=y, +8=colour.
;   ES=frame-buffer segment.
; Outputs:
;   Valid pixel written.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

PutPixel:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push di

    ; Unsigned comparisons also reject negative word values.
    mov bx, [bp + 4]
    cmp bx, SCREEN_W
    jb short .branch_bridge_89
    jmp near .done
.branch_bridge_89:

    mov ax, [bp + 6]
    cmp ax, SCREEN_H
    jb short .branch_bridge_90
    jmp near .done
.branch_bridge_90:

    ; Pixel offset = y*256 + y*64 + x.
    mov di, ax

    mov cl, 8
    shl di, cl

    mov cl, 6
    shl ax, cl

    add di, ax
    add di, bx

    mov ax, [bp + 8]
    mov [es:di], al

.done:
    pop di
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: FillRect
; Purpose:
;   Clip a rectangle to the screen and fill its intersection.
; Inputs:
;   [BP+4]=x, +6=y, +8=width, +10=height, +12=colour.
;   ES=frame-buffer segment.
; Outputs:
;   Visible rectangle pixels written.
; Registers changed:
;   None. Flags preserved.
; Preconditions:
;   Ordinary small rendering coordinates, without signed
;   arithmetic overflow.
; Stack:
;   Callee removes 10 bytes.
; ------------------------------------------------------------

FillRect:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov bx, [bp + 4]
    mov cx, [bp + 6]
    mov si, [bp + 8]
    mov dx, [bp + 10]

    cmp si, 0
    jle short .branch_bridge_91
    jmp near .w_ok
.branch_bridge_91:
    jmp .done

.w_ok:
    cmp dx, 0
    jle short .branch_bridge_92
    jmp near .h_ok
.branch_bridge_92:
    jmp .done

.h_ok:
    ; Clip left.
    cmp bx, 0
    jl short .branch_bridge_93
    jmp near .left_ok
.branch_bridge_93:

    add si, bx
    xor bx, bx

.left_ok:
    ; Clip top.
    cmp cx, 0
    jl short .branch_bridge_94
    jmp near .top_ok
.branch_bridge_94:

    add dx, cx
    xor cx, cx

.top_ok:
    cmp si, 0
    jle short .branch_bridge_95
    jmp near .width_visible
.branch_bridge_95:
    jmp .done

.width_visible:
    cmp dx, 0
    jle short .branch_bridge_96
    jmp near .height_visible
.branch_bridge_96:
    jmp .done

.height_visible:
    cmp bx, SCREEN_W
    jge short .branch_bridge_97
    jmp near .x_ok
.branch_bridge_97:
    jmp .done

.x_ok:
    cmp cx, SCREEN_H
    jge short .branch_bridge_98
    jmp near .y_ok
.branch_bridge_98:
    jmp .done

.y_ok:
    ; Clip right.
    mov ax, SCREEN_W
    sub ax, bx

    cmp si, ax
    jg short .branch_bridge_99
    jmp near .right_ok
.branch_bridge_99:

    mov si, ax

.right_ok:
    ; Clip bottom.
    mov ax, SCREEN_H
    sub ax, cx

    cmp dx, ax
    jg short .branch_bridge_100
    jmp near .bottom_ok
.branch_bridge_100:

    mov dx, ax

.bottom_ok:
    ; Compute the first destination offset.
    mov ax, cx
    mov di, ax

    mov cl, 8
    shl di, cl

    mov cl, 6
    shl ax, cl

    add di, ax
    add di, bx

    ; Skip the unused part of each scanline.
    mov bx, SCREEN_W
    sub bx, si

    mov ax, [bp + 12]
    cld

.row:
    mov cx, si
    rep stosb

    add di, bx
    dec dx
    jz short .branch_bridge_101
    jmp near .row
.branch_bridge_101:

.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 10

; ------------------------------------------------------------
; Procedure: DrawSprite
; Purpose:
;   Render a transparent, optionally mirrored sprite.
; Inputs:
;   [BP+4]=x, +6=y, +8=descriptor, +10=flags.
;   Descriptor begins with output height, then 8-wide ASCII
;   source artwork. Source pixels expand to 2x2 pixels.
;   Flags bit 0 mirrors horizontally.
;   ES=frame-buffer segment.
; Outputs:
;   Clipped nontransparent sprite pixels rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 8 bytes.
; ------------------------------------------------------------

DrawSprite:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, [bp + 8]
    mov cx, [si]
    xor dx, dx

.row:
    xor bx, bx

.column:
    ; Source row = output row / 2; each source row is 8 bytes.
    mov di, dx
    shr di, 1

    shl di, 1
    shl di, 1
    shl di, 1

    ; Source column = selected output column / 2.
    mov ax, bx

    test word [bp + 10], 1
    jnz short .branch_bridge_102
    jmp near .column_ready
.branch_bridge_102:

    mov ax, 15
    sub ax, bx

.column_ready:
    shr ax, 1

    add di, ax
    add di, si
    add di, 2

    xor ax, ax
    mov al, [di]
    sub al, '0'

    cmp al, 9
    jbe short .branch_bridge_103
    jmp near .next_column
.branch_bridge_103:

    push bx
    mov bx, ax
    mov al, [art_palette + bx]
    pop bx

    ; Colour zero is never written.
    or al, al
    jnz short .branch_bridge_104
    jmp near .next_column
.branch_bridge_104:

    xor ah, ah
    push ax

    mov ax, [bp + 6]
    add ax, dx
    push ax

    mov ax, [bp + 4]
    add ax, bx
    push ax

    call PutPixel

.next_column:
    inc bx
    cmp bx, 16
    jge short .branch_bridge_105
    jmp near .column
.branch_bridge_105:

    inc dx
    cmp dx, cx
    jge short .branch_bridge_106
    jmp near .row
.branch_bridge_106:

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 8

; ------------------------------------------------------------
; Procedure: DrawGallery
; Purpose:
;   Display all twelve original sprite descriptors.
; Inputs:
;   DS=program segment; ES=frame-buffer segment.
; Outputs:
;   Sprite gallery rendered.
; Registers changed:
;   None. Flags preserved.
; ------------------------------------------------------------

DrawGallery:
    pushf
    push ax
    push bx
    push cx
    push dx
    push si

    xor si, si
    mov bx, 16
    mov dx, 40
    mov cx, 12

.next:
    xor ax, ax
    push ax

    mov ax, [gallery_table + si]
    push ax

    push dx
    push bx

    call DrawSprite

    add si, 2
    add bx, 48

    cmp si, 12
    je short .branch_bridge_107
    jmp near .continue
.branch_bridge_107:

    mov bx, 16
    mov dx, 112

.continue:
    loop .next

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    ret

; ------------------------------------------------------------
; Procedure: DrawNumber
; Purpose:
;   Render a zero-padded unsigned 16-bit number.
; Inputs:
;   [BP+4]=value, +6=x, +8=y, +10=digit count.
;   ES=frame-buffer segment.
; Outputs:
;   Decimal digits rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 8 bytes.
; ------------------------------------------------------------

DrawNumber:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push di

    mov ax, [bp + 4]
    mov bx, 10
    mov cx, [bp + 10]

.divide:
    xor dx, dx
    div bx
    push dx

    loop .divide

    mov cx, [bp + 10]
    mov di, [bp + 6]

.emit:
    pop ax

    mov dx, [bp + 8]
    push dx

    push di
    push ax

    call DrawDigit

    add di, 8
    loop .emit

    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 8

; ------------------------------------------------------------
; Procedure: DrawDigit
; Purpose:
;   Draw one 3x5 decimal glyph at 2x scale.
; Inputs:
;   [BP+4]=digit 0..9, +6=x, +8=y.
;   ES=frame-buffer segment.
; Outputs:
;   White digit rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

DrawDigit:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov ax, [bp + 4]
    mov bx, 5
    mul bx

    mov si, digit_font
    add si, ax

    xor di, di

.row:
    xor bx, bx

.column:
    mov al, [si]

    mov cl, 2
    sub cl, bl
    shr al, cl

    test al, 1
    jnz short .branch_bridge_108
    jmp near .next
.branch_bridge_108:

    mov ax, 15
    push ax

    mov ax, 2
    push ax
    push ax

    mov ax, di
    shl ax, 1
    add ax, [bp + 8]
    push ax

    mov ax, bx
    shl ax, 1
    add ax, [bp + 6]
    push ax

    call FillRect

.next:
    inc bx
    cmp bx, 3
    jge short .branch_bridge_109
    jmp near .column
.branch_bridge_109:

    inc si
    inc di

    cmp di, 5
    jge short .branch_bridge_110
    jmp near .row
.branch_bridge_110:

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: ClearFrameBuffer
; Purpose:
;   Clear exactly 64000 bytes using REP STOSW.
; Inputs:
;   [BP+4]=frame-buffer segment.
; Outputs:
;   Buffer becomes black.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 2 bytes.
; ------------------------------------------------------------

ClearFrameBuffer:
    push bp
    mov bp, sp

    pushf
    push ax
    push cx
    push di
    push es

    mov ax, [bp + 4]
    mov es, ax

    xor di, di
    xor ax, ax

    mov cx, FRAME_WORDS

    cld
    rep stosw

    pop es
    pop di
    pop cx
    pop ax
    popf

    pop bp
    ret 2

; ------------------------------------------------------------
; Procedure: PresentFrame
; Purpose:
;   Copy exactly 64000 bytes to VGA using REP MOVSW.
; Inputs:
;   [BP+4]=frame-buffer segment.
; Outputs:
;   Completed frame displayed.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 2 bytes.
; ------------------------------------------------------------

PresentFrame:
    push bp
    mov bp, sp

    pushf
    push ax
    push cx
    push si
    push di
    push ds
    push es

    mov ax, [bp + 4]
    mov ds, ax
    xor si, si

    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di

    mov cx, FRAME_WORDS

    cld
    rep movsw

    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    popf

    pop bp
    ret 2

; ------------------------------------------------------------
; Procedure: MemoryError
; Purpose:
;   Report allocation failure before installing handlers.
; Inputs:
;   DS=program segment.
; Outputs:
;   Message and DOS exit code 1.
; Registers changed:
;   AX,DX; does not return.
; ------------------------------------------------------------


; Draw text into the off-screen buffer, not directly through BIOS.

%macro RECT 5
    push ax
    mov ax,%5
    push ax
    mov ax,%4
    push ax
    mov ax,%3
    push ax
    mov ax,%2
    push ax
    mov ax,%1
    push ax
    call FillRect
    pop ax
%endmacro

; RenderGame: draw one complete frame in ES=buffer, then present once.
; Inputs: state context. Preserves registers/flags.
RenderGame:
    SAVE_CONTEXT
    mov ax,[buffer_seg]
    push ax
    call ClearFrameBuffer
    mov ax,[buffer_seg]
    mov es,ax
    cmp word [state],ST_TITLE
    jne short .branch_bridge_111
    jmp near .title
.branch_bridge_111:
    cmp word [state],ST_LIFE
    jne short .branch_bridge_112
    jmp near .life
.branch_bridge_112:
    cmp word [state],ST_OVER
    jne short .branch_bridge_113
    jmp near .over
.branch_bridge_113:
    cmp word [state],ST_COMPLETE
    jne short .branch_bridge_114
    jmp near .complete
.branch_bridge_114:
    cmp byte [gallery],0
    jne short .branch_bridge_115
    jmp near .scene
.branch_bridge_115:
    cmp word [state],ST_PLAY
    je short .branch_bridge_116
    jmp near .scene
.branch_bridge_116:
    call DrawGallery
    TEXT msg_gallery,70,20,15,1
    jmp .present
.scene:
    call DrawScene
    cmp word [state],ST_PAUSE
    je short .branch_bridge_117
    jmp near .present
.branch_bridge_117:
    RECT 46,66,228,70,15
    RECT 49,69,222,64,1
    TEXT msg_paused,124,80,14,2
    TEXT msg_resume,94,108,15,1
    TEXT msg_esc,100,120,15,1
    jmp .present
.title:
    call DrawPanel
    TEXT msg_title,52,40,14,2
    TEXT msg_world,130,66,15,1
    cmp word [menu_choice],0
    je short .branch_bridge_118
    jmp near .exit_highlight
.branch_bridge_118:
    RECT 86,88,148,20,4
    jmp .options
.exit_highlight:
    RECT 86,114,148,20,4
.options:
    TEXT msg_start,100,92,15,2
    TEXT msg_exit,136,118,15,2
    TEXT msg_menuhelp,85,145,15,1
    TEXT msg_control,25,162,15,1
    jmp .present
.life:
    call DrawPanel
    TEXT msg_world,106,47,14,2
    TEXT msg_lost,106,75,15,2
    xor ax,ax
    push ax
    mov ax,sprite_small_stand
    push ax
    mov ax,104
    push ax
    mov ax,126
    push ax
    call DrawSprite
    TEXT msg_x,150,110,15,1
    VALUE [item_state+IT_LIVES],0,2,168,110
    TEXT msg_getready,100,145,15,1
    jmp .present
.over:
    call DrawPanel
    TEXT msg_over,106,52,12,2
    TEXT msg_finalscore,100,88,15,1
    mov ax,106
    push ax
    mov ax,136
    push ax
    mov ax,item_state
    push ax
    call DrawScore32
    TEXT msg_return,79,146,14,1
    jmp .present
.complete:
    call DrawPanel
    TEXT msg_complete,76,40,14,2
    TEXT msg_flag,62,70,15,1
    VALUE [flag_reward],0,4,218,70
    TEXT msg_timeleft,62,84,15,1
    VALUE [finish_time],0,3,224,84
    TEXT msg_bonus,62,98,15,1
    VALUE [time_bonus],0,5,212,98
    TEXT msg_coins,62,112,15,1
    VALUE [item_state+IT_COINS],0,2,230,112
    TEXT msg_finalscore,62,126,15,1
    VALUE [item_state+IT_SCORE_LO],[item_state+IT_SCORE_HI],6,206,126
    TEXT msg_return,79,154,14,1
.present:
    mov ax,[buffer_seg]
    push ax
    call PresentFrame
    RESTORE_CONTEXT
    ret
; DrawPanel: reusable coloured screen border in current buffer.
; No inputs; preserves AX through RECT. ES must be the buffer.
DrawPanel:
    SAVE_CONTEXT
    RECT 0,0,320,200,1
    RECT 14,24,292,154,14
    RECT 17,27,286,148,0
    RECT 20,30,280,142,1
    RESTORE_CONTEXT
    ret
; DrawScene: draw immutable-position scenery and current entities.
; Input: game context; ES buffer. Preserves registers/flags.
DrawScene:
    SAVE_CONTEXT
    RECT 0,16,320,176,3
    mov ax,[camera_x]
    push ax
    mov ax,working_map
    push ax
    call DrawMap
    mov ax,[camera_x]
    push ax
    mov ax,item_state
    push ax
    call DrawItems
    cmp byte [hide_hero],0
    je short .branch_bridge_119
    jmp near .hud
.branch_bridge_119:
    cmp byte [blink_demo],0
    jne short .branch_bridge_120
    jmp near .hero
.branch_bridge_120:
    test word [visual_ticks],1
    jz short .branch_bridge_121
    jmp near .hud
.branch_bridge_121:
.hero:
    mov bx,[hero+H_POSE]
    cmp word [hero+H_HEIGHT],16
    jne short .branch_bridge_122
    jmp near .descriptor
.branch_bridge_122:
    add bx,3
.descriptor:
    shl bx,1
    mov si,[hero_sprite_table+bx]
    mov ax,[hero+H_FACE]
    push ax
    push si
    mov ax,[hero+H_Y]
    push ax
    mov ax,[hero+H_X]
    sub ax,[camera_x]
    push ax
    call DrawSprite
.hud:
    call DrawFullHUD
    RESTORE_CONTEXT
    ret
; DrawFullHUD: 7-pixel labels and 7-pixel values fit rows 0..15.
; Input: game context; ES buffer. No scrolling applied to HUD.
DrawFullHUD:
    SAVE_CONTEXT
    TEXT msg_score,4,0,14,1
    TEXT msg_coins,58,0,14,1
    TEXT msg_worldlabel,104,0,14,1
    TEXT msg_time,150,0,14,1
    TEXT msg_lives,194,0,14,1
    TEXT msg_health,254,0,14,1
    VALUE [item_state+IT_SCORE_LO],[item_state+IT_SCORE_HI],6,4,8
    TEXT msg_x,58,8,15,1
    VALUE [item_state+IT_COINS],0,2,66,8
    TEXT msg_worldnumber,110,8,15,1
    VALUE [time_left],0,3,150,8
    TEXT msg_x,194,8,15,1
    VALUE [item_state+IT_LIVES],0,2,202,8
    xor ax,ax
    cmp word [item_state+IT_HP],0
    jne short .branch_bridge_123
    jmp near .first
.branch_bridge_123:
    inc ax
.first:
    push ax
    mov ax,9
    push ax
    mov ax,264
    push ax
    call DrawHeart
    xor ax,ax
    cmp word [item_state+IT_HP],2
    je short .branch_bridge_124
    jmp near .second
.branch_bridge_124:
    inc ax
.second:
    push ax
    mov ax,9
    push ax
    mov ax,276
    push ax
    call DrawHeart
    RESTORE_CONTEXT
    ret
; DrawHUDValue(low,high,digits,x,y): 32-bit division into local ASCII.
; Stack +4 low,+6 high,+8 digits(1..6),+10 x,+12 y; ret 10.
; All registers/flags preserved. Only local stack storage is modified.
DrawHUDValue:
    push bp
    mov bp,sp
    sub sp,8
    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov ax,[bp+4]
    mov si,[bp+6]
    mov cx,[bp+8]
    lea di,[bp-8]
    add di,cx
    mov byte [di],0
    mov bx,10
.divide:
    push ax
    mov ax,si
    xor dx,dx
    div bx
    mov si,ax
    pop ax
    div bx
    add dl,'0'
    dec di
    mov [di],dl
    loop .divide
    mov ax,1
    push ax
    mov ax,15
    push ax
    mov ax,[bp+12]
    push ax
    mov ax,[bp+10]
    push ax
    push di
    call DrawText
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    mov sp,bp
    pop bp
    ret 10

; DrawText(text,x,y,colour,scale): original 5x7 uppercase bitmap text.
; Stack +4 text,+6 x,+8 y,+10 colour,+12 scale (1 or 2); ret 10.
; All registers and flags preserved; clipped pixels through FillRect.
DrawText:
    push bp
    mov bp,sp
    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si,[bp+4]
    mov bx,[bp+6]
    mov dx,[bp+8]
    cld
.character:
    lodsb
    or al,al
    jnz short .branch_bridge_125
    jmp near .done
.branch_bridge_125:
    cmp al,32
    jae short .branch_bridge_126
    jmp near .character
.branch_bridge_126:
    cmp al,90
    jbe short .branch_bridge_127
    jmp near .character
.branch_bridge_127:
    xor ah,ah
    sub ax,32
    push si
    mov di,ax
    shl ax,1
    shl ax,1
    shl ax,1
    sub ax,di
    mov di,ui_font
    add di,ax
    xor si,si
.row:
    mov al,[di]
    mov cx,5
    push bx
.column:
    test al,16
    jnz short .branch_bridge_128
    jmp near .next_column
.branch_bridge_128:
    push ax
    mov ax,[bp+10]
    push ax
    mov ax,[bp+12]
    push ax
    push ax
    push dx
    push bx
    call FillRect
    pop ax
.next_column:
    add bx,[bp+12]
    shl al,1
    loop .column
    pop bx
    add dx,[bp+12]
    inc di
    inc si
    cmp si,7
    jae short .branch_bridge_129
    jmp near .row
.branch_bridge_129:
    mov ax,[bp+12]
    mov cx,6
    mul cx
    add bx,ax
    mov dx,[bp+8]
    pop si
    jmp .character
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    pop bp
    ret 10

msg_title db 'SUPER MARIO ENGINE',0
msg_world db 'WORLD 1-1',0
msg_start db 'START GAME',0
msg_exit db 'EXIT',0
msg_menuhelp db 'UP DOWN SELECT  ENTER PLAY',0
msg_control db 'ARROWS MOVE  SHIFT RUN  SPACE JUMP  P PAUSE',0
msg_paused db 'PAUSED',0
msg_resume db 'P CONTINUES THE GAME',0
msg_esc db 'ESC RETURNS TO TITLE',0
msg_lost db 'LIFE LOST',0
msg_getready db 'GET READY TO TRY AGAIN',0
msg_over db 'GAME OVER',0
msg_finalscore db 'FINAL SCORE',0
msg_return db 'PRESS ENTER TO RETURN TO TITLE',0
msg_complete db 'LEVEL COMPLETE',0
msg_flag db 'FLAG POINTS',0
msg_timeleft db 'TIME LEFT',0
msg_bonus db 'TIME BONUS X50',0
msg_score db 'SCORE',0
msg_coins db 'COINS',0
msg_worldlabel db 'WORLD',0
msg_worldnumber db '1-1',0
msg_time db 'TIME',0
msg_lives db 'LIVES',0
msg_health db 'HEALTH',0
msg_x db 'X',0
msg_gallery db 'SPRITE GALLERY - V RETURNS',0


ui_font:
    db 0,0,0,0,0,0,0 ;  
    db 0,0,0,0,0,0,0 ; !
    db 0,0,0,0,0,0,0 ; "
    db 0,0,0,0,0,0,0 ; #
    db 0,0,0,0,0,0,0 ; $
    db 0,0,0,0,0,0,0 ; %
    db 0,0,0,0,0,0,0 ; &
    db 0,0,0,0,0,0,0 ; '
    db 0,0,0,0,0,0,0 ; (
    db 0,0,0,0,0,0,0 ; )
    db 0,0,0,0,0,0,0 ; *
    db 0,0,0,0,0,0,0 ; +
    db 0,0,0,0,0,0,0 ; ,
    db 0,0,0,31,0,0,0 ; -
    db 0,0,0,0,0,0,0 ; .
    db 0,0,0,0,0,0,0 ; /
    db 14,17,19,21,25,17,14 ; 0
    db 4,12,4,4,4,4,14 ; 1
    db 14,17,1,2,4,8,31 ; 2
    db 30,1,1,14,1,1,30 ; 3
    db 2,6,10,18,31,2,2 ; 4
    db 31,16,16,30,1,1,30 ; 5
    db 14,16,16,30,17,17,14 ; 6
    db 31,1,2,4,8,8,8 ; 7
    db 14,17,17,14,17,17,14 ; 8
    db 14,17,17,15,1,1,14 ; 9
    db 0,4,4,0,4,4,0 ; :
    db 0,0,0,0,0,0,0 ; ;
    db 0,0,0,0,0,0,0 ; <
    db 0,0,0,0,0,0,0 ; =
    db 0,0,0,0,0,0,0 ; >
    db 0,0,0,0,0,0,0 ; ?
    db 0,0,0,0,0,0,0 ; @
    db 14,17,17,31,17,17,17 ; A
    db 30,17,17,30,17,17,30 ; B
    db 15,16,16,16,16,16,15 ; C
    db 30,17,17,17,17,17,30 ; D
    db 31,16,16,30,16,16,31 ; E
    db 31,16,16,30,16,16,16 ; F
    db 14,17,16,23,17,17,14 ; G
    db 17,17,17,31,17,17,17 ; H
    db 31,4,4,4,4,4,31 ; I
    db 7,2,2,2,18,18,12 ; J
    db 17,18,20,24,20,18,17 ; K
    db 16,16,16,16,16,16,31 ; L
    db 17,27,21,21,17,17,17 ; M
    db 17,25,21,19,17,17,17 ; N
    db 14,17,17,17,17,17,14 ; O
    db 30,17,17,30,16,16,16 ; P
    db 14,17,17,17,21,18,13 ; Q
    db 30,17,17,30,20,18,17 ; R
    db 15,16,16,14,1,1,30 ; S
    db 31,4,4,4,4,4,4 ; T
    db 17,17,17,17,17,17,14 ; U
    db 17,17,17,17,17,10,4 ; V
    db 17,17,17,21,21,21,10 ; W
    db 17,17,10,4,10,17,17 ; X
    db 17,17,10,4,4,4,4 ; Y
    db 31,1,2,4,8,16,31 ; Z

MemoryError:
    mov dx, memory_error
    mov ah, 09h
    int 21h

    mov ax, 4C01h
    int 21h

; ------------------------------------------------------------
; Included project modules
; ------------------------------------------------------------

%include "assets.inc"
%include "items.inc"
; Assembly-time guard, not a preprocessor %if.
; Emits zero bytes when code/data fit below offset E100h.
; A negative TIMES count signals that the stack reserve is exceeded.
times -(($-$$) / 0E001h) db 0
