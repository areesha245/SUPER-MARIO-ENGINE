; ============================================================
; SUPER MARIO ENGINE
; Collectibles, score, health, and enemy integration
;
; Included by MARIO.ASM.
; This file includes ENEMIES.INC at the end.
; Do not assemble this file separately.
; ============================================================

; ------------------------------------------------------------
; Game/item state record offsets
; ------------------------------------------------------------

IT_SCORE_LO     equ 0
IT_SCORE_HI     equ 2
IT_COINS        equ 4
IT_LIVES        equ 6
IT_HP           equ 8

IT_MUSHROOMS    equ 10
IT_SLOT_BYTES   equ 22
IT_SLOT_COUNT   equ 2

IT_POP_X        equ 54
IT_POP_Y        equ 56
IT_POP_TIMER    equ 58

IT_INVULN       equ 60
IT_CHAIN        equ 62
IT_PREV_FEET    equ 64
IT_DEAD         equ 66
IT_ENEMIES      equ 68

; ------------------------------------------------------------
; Game/item state
;
; First 10 bytes:
;   score low, score high, coins, lives, HP.
;
; Next 44 bytes:
;   Two mushroom slots.
;
; Next 6 bytes:
;   Coin-popup x, y, timer.
;
; Next 8 bytes:
;   Invulnerability, chain, previous feet, death flag.
;
; Final 168 bytes:
;   Six enemy records of 28 bytes each.
; ------------------------------------------------------------

item_state:
    dw 0,0,0,3,1
    times 44 db 0
    dw 0,0,0
    dw 0,0,160,0
    times 168 db 0

heart_filled:
    db 36h,7Fh,7Fh,3Eh,1Ch,08h

heart_outline:
    db 36h,49h,41h,22h,14h,08h

; ------------------------------------------------------------
; Procedure: ResetItemLevel
; Purpose:
;   Reset temporary items, HP, invulnerability, chain,
;   and all enemies for a level restart.
; Inputs:
;   [BP+4] = item/game-state record.
; Outputs:
;   Level-specific state reset.
;   Score, coins, and lives retained.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 2 bytes.
; ------------------------------------------------------------

ResetItemLevel:
    push bp
    mov bp, sp

    pushf
    push ax
    push cx
    push si
    push di
    push es

    mov si, [bp + 4]
    mov word [si + IT_HP], 1

    ; Clear mushrooms and coin-popup state.
    lea di, [si + IT_MUSHROOMS]

    push ds
    pop es

    xor ax, ax
    mov cx, 25
    cld
    rep stosw

    ; Reset hero-related enemy interaction state.
    mov word [si + IT_INVULN], 0
    mov word [si + IT_CHAIN], 0
    mov word [si + IT_PREV_FEET], 160
    mov word [si + IT_DEAD], 0

    ; Initialize all enemy records from their templates.
    push si
    call InitEnemies

    pop es
    pop di
    pop si
    pop cx
    pop ax
    popf

    pop bp
    ret 2

; ------------------------------------------------------------
; Procedure: AddScore
; Purpose:
;   Add a reward to the two-word score and cap at 999999.
; Inputs:
;   [BP+4] = state.
;   [BP+6] = unsigned points.
; Outputs:
;   Score updated using ADD/ADC.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

AddScore:
    push bp
    mov bp, sp

    pushf
    push ax
    push si

    mov si, [bp + 4]
    mov ax, [bp + 6]

    add [si + IT_SCORE_LO], ax
    adc word [si + IT_SCORE_HI], 0

    cmp word [si + IT_SCORE_HI], 000Fh
    jb .done
    ja .clamp

    cmp word [si + IT_SCORE_LO], 423Fh
    jbe .done

.clamp:
    mov word [si + IT_SCORE_LO], 423Fh
    mov word [si + IT_SCORE_HI], 000Fh

.done:
    pop si
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: GiveCoin
; Purpose:
;   Award one coin and 200 points; handle 100-coin extra life.
; Inputs:
;   [BP+4] = state.
; Outputs:
;   Score, coins, and possibly lives updated.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 2 bytes.
; ------------------------------------------------------------

GiveCoin:
    push bp
    mov bp, sp

    pushf
    push ax
    push si

    mov si, [bp + 4]

    mov ax, 200
    push ax
    push si
    call AddScore

    inc word [si + IT_COINS]

    cmp word [si + IT_COINS], 100
    jb .done

    mov word [si + IT_COINS], 0

    cmp word [si + IT_LIVES], 99
    jae .done

    inc word [si + IT_LIVES]

.done:
    pop si
    pop ax
    popf

    pop bp
    ret 2

; ------------------------------------------------------------
; Procedure: TilePointer
; Purpose:
;   Calculate a valid tile's memory address.
; Inputs:
;   [BP+4] = map.
;   [BP+6] = valid world x.
;   [BP+8] = valid world y.
; Outputs:
;   BX = tile-byte address within DS.
; Registers changed:
;   BX only. Flags preserved.
; Preconditions:
;   Coordinates already validated through GetTile.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

TilePointer:
    push bp
    mov bp, sp

    pushf
    push ax
    push cx
    push dx

    mov ax, [bp + 6]
    mov cl, 4
    shr ax, cl
    mov bx, ax

    mov dx, [bp + 8]
    shr dx, cl

    ; Row * 60 = row * 64 - row * 4.
    mov ax, dx
    mov cl, 6
    shl ax, cl
    shl dx, 1
    shl dx, 1
    sub ax, dx

    add bx, ax
    add bx, [bp + 4]

    pop dx
    pop cx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: TriggerBlock
; Purpose:
;   Apply brick/question-block rules at the head centre.
; Inputs:
;   [BP+4]  = hero.
;   [BP+6]  = map.
;   [BP+8]  = head-centre world x.
;   [BP+10] = probe world y inside the struck tile.
;   [BP+12] = state.
; Outputs:
;   Map, item, and scoring state updated.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 10 bytes.
; ------------------------------------------------------------

TriggerBlock:
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
    mov di, [bp + 12]

    mov ax, [bp + 10]
    push ax
    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    call GetTile

    cmp ax, 2
    je .brick

    cmp ax, 3
    je .coin_block

    cmp ax, 4
    je .mushroom_block

    jmp .done

.brick:
    cmp word [si + H_HEIGHT], 32
    je .break_brick
    jmp .done

.break_brick:
    mov ax, [bp + 10]
    push ax
    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    call TilePointer

    mov byte [bx], 0

    mov ax, 50
    push ax
    push di
    call AddScore

    jmp .done

.coin_block:
    mov ax, [bp + 10]
    push ax
    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    call TilePointer

    ; Mark used before awarding its one-time coin.
    mov byte [bx], 5

    push di
    call GiveCoin

    ; Start the coin-popup effect.
    mov ax, [bp + 8]
    and ax, 0FFF0h
    mov [di + IT_POP_X], ax

    mov ax, [bp + 10]
    and ax, 0FFF0h
    sub ax, 16
    mov [di + IT_POP_Y], ax

    mov word [di + IT_POP_TIMER], 9
    jmp .done

.mushroom_block:
    mov ax, [bp + 10]
    push ax
    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    call TilePointer

    mov byte [bx], 5

    ; Find a free mushroom slot.
    mov bx, di
    add bx, IT_MUSHROOMS
    mov cx, IT_SLOT_COUNT

.find_slot:
    cmp word [bx], 0
    je .spawn

    add bx, IT_SLOT_BYTES
    loop .find_slot

    jmp .done

.spawn:
    mov word [bx], 1

    ; Zero the motion record.
    lea si, [bx + 2]
    mov dx, si
    mov cx, H_BYTES / 2

.clear_motion:
    mov word [si], 0
    add si, 2
    loop .clear_motion

    mov si, dx

    mov ax, [bp + 8]
    and ax, 0FFF0h
    mov [si + H_X], ax

    mov ax, [bp + 10]
    and ax, 0FFF0h
    sub ax, 16
    mov [si + H_Y], ax

    mov word [si + H_VX], 422
    mov word [si + H_HEIGHT], 16
    mov word [si + H_GROUND], 1

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
; Procedure: CollectCoinAt
; Purpose:
;   Remove/reward a coin tile at one sampled position.
; Inputs:
;   [BP+4]=map, +6=x, +8=y, +10=state.
; Outputs:
;   Map coin removed and GiveCoin applied if present.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 8 bytes.
; ------------------------------------------------------------

CollectCoinAt:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx

    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    mov ax, [bp + 4]
    push ax
    call GetTile

    cmp ax, 11
    jne .done

    mov ax, [bp + 8]
    push ax
    mov ax, [bp + 6]
    push ax
    mov ax, [bp + 4]
    push ax
    call TilePointer

    mov byte [bx], 0

    mov ax, [bp + 10]
    push ax
    call GiveCoin

.done:
    pop bx
    pop ax
    popf

    pop bp
    ret 8

; ------------------------------------------------------------
; Procedure: StepMushroom
; Purpose:
;   Move, turn, fall, and remove one mushroom.
; Inputs:
;   [BP+4]=slot, +6=map, +8=camera x.
; Outputs:
;   Mushroom slot updated.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

StepMushroom:
    push bp
    mov bp, sp

    pushf
    push ax
    push dx
    push si
    push di

    mov di, [bp + 4]

    cmp word [di], 0
    jne .active
    jmp .done

.active:
    lea si, [di + 2]

    mov ax, [si + H_VY]
    add ax, GRAVITY

    cmp ax, FALL_LIMIT
    jle .fall_ready

    mov ax, FALL_LIMIT

.fall_ready:
    mov [si + H_VY], ax

    ; Keep the previous direction for wall turning.
    mov dx, [si + H_VX]

    mov ax, [bp + 6]
    push ax
    push si
    call MoveHorizontal

    cmp word [si + H_VX], 0
    jne .vertical

    neg dx
    mov [si + H_VX], dx

.vertical:
    mov ax, [bp + 6]
    push ax
    push si
    call MoveVertical

    cmp word [si + H_Y], WORLD_H
    jge .remove

    mov ax, [bp + 8]
    sub ax, 32
    cmp [si + H_X], ax
    jl .remove

    jmp .done

.remove:
    mov word [di], 0

.done:
    pop di
    pop si
    pop dx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: HeroItemOverlap
; Purpose:
;   Test centred 12-wide hitboxes for rectangle overlap.
; Inputs:
;   [BP+4]=first motion record, +6=second motion record.
;   First height comes from its record; second height is 16.
; Outputs:
;   AX=1 overlap, AX=0 no overlap.
; Registers changed:
;   AX only. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

HeroItemOverlap:
    push bp
    mov bp, sp

    pushf
    push bx
    push dx
    push si
    push di

    mov si, [bp + 4]
    mov di, [bp + 6]

    mov ax, [si + H_X]
    add ax, 14

    mov dx, [di + H_X]
    add dx, 2

    cmp ax, dx
    jle .no

    mov ax, [di + H_X]
    add ax, 14

    mov dx, [si + H_X]
    add dx, 2

    cmp ax, dx
    jle .no

    mov ax, [si + H_Y]
    add ax, [si + H_HEIGHT]

    cmp ax, [di + H_Y]
    jle .no

    mov ax, [di + H_Y]
    add ax, 16

    cmp ax, [si + H_Y]
    jle .no

    mov ax, 1
    jmp .done

.no:
    xor ax, ax

.done:
    pop di
    pop si
    pop dx
    pop bx
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: UpdateItems
; Purpose:
;   Update enemies, map coins, mushrooms, and collection.
; Inputs:
;   [BP+4]=hero, +6=map, +8=state, +10=camera value.
; Outputs:
;   Game interaction state updated.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 8 bytes.
; ------------------------------------------------------------

UpdateItems:
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

    ; Keep the G development form test consistent with HP.
    mov word [di + IT_HP], 1

    cmp word [si + H_HEIGHT], 16
    je .hp_ready

    mov word [di + IT_HP], 2

.hp_ready:
    ; UpdateEnemies(hero,map,state,camera,keys,blink-address).
    mov ax, blink_demo
    push ax

    mov ax, frame_keys
    push ax

    mov ax, [bp + 10]
    push ax

    push di

    mov ax, [bp + 6]
    push ax

    push si

    call UpdateEnemies

    ; Do not collect items after a fatal enemy collision.
    cmp word [di + IT_DEAD], 0
    je .popup
    jmp .done

.popup:
    cmp word [di + IT_POP_TIMER], 0
    je .coin_setup

    dec word [di + IT_POP_TIMER]
    dec word [di + IT_POP_Y]

.coin_setup:
    ; Sample every tile row touched by the hero hitbox.
    mov dx, [si + H_Y]
    and dx, 0FFF0h

    mov cx, [si + H_Y]
    add cx, [si + H_HEIGHT]
    dec cx

.coin_row:
    mov bx, [si + H_X]
    add bx, 2

    push di
    push dx
    push bx

    mov ax, [bp + 6]
    push ax

    call CollectCoinAt

    add bx, 11

    push di
    push dx
    push bx

    mov ax, [bp + 6]
    push ax

    call CollectCoinAt

    add dx, 16
    cmp dx, cx
    jle .coin_row

    ; Move and collect the two possible mushrooms.
    lea bx, [di + IT_MUSHROOMS]
    mov cx, IT_SLOT_COUNT

.mushroom:
    mov ax, [bp + 10]
    push ax

    mov ax, [bp + 6]
    push ax

    push bx
    call StepMushroom

    cmp word [bx], 0
    je .next_mushroom

    lea ax, [bx + 2]
    push ax
    push si
    call HeroItemOverlap

    or ax, ax
    jz .next_mushroom

    mov word [bx], 0

    mov ax, 1000
    push ax
    push di
    call AddScore

    ; Preserve feet when changing to the taller form.
    cmp word [si + H_HEIGHT], 16
    jne .already_super

    sub word [si + H_Y], 16
    mov word [si + H_HEIGHT], 32

.already_super:
    mov word [di + IT_HP], 2

.next_mushroom:
    add bx, IT_SLOT_BYTES
    dec cx
    jnz .mushroom

    ; Next frame's stomp classification needs previous feet.
    mov ax, [si + H_Y]
    add ax, [si + H_HEIGHT]
    mov [di + IT_PREV_FEET], ax

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
; Procedure: DrawItems
; Purpose:
;   Render enemies, mushrooms, and coin-popup artwork.
; Inputs:
;   [BP+4]=state, +6=camera value.
;   ES=frame-buffer segment.
; Outputs:
;   Entity sprites rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 4 bytes.
; ------------------------------------------------------------

DrawItems:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push si

    mov si, [bp + 4]

    ; DrawEnemies(state,camera).
    mov ax, [bp + 6]
    push ax
    push si
    call DrawEnemies

    lea bx, [si + IT_MUSHROOMS]
    mov cx, IT_SLOT_COUNT

.slot:
    cmp word [bx], 0
    je .next

    xor ax, ax
    push ax

    mov ax, sprite_mushroom
    push ax

    mov ax, [bx + 2 + H_Y]
    push ax

    mov ax, [bx + 2 + H_X]
    sub ax, [bp + 6]
    push ax

    call DrawSprite

.next:
    add bx, IT_SLOT_BYTES
    loop .slot

    cmp word [si + IT_POP_TIMER], 0
    je .done

    xor ax, ax
    push ax

    mov ax, sprite_coin
    push ax

    mov ax, [si + IT_POP_Y]
    push ax

    mov ax, [si + IT_POP_X]
    sub ax, [bp + 6]
    push ax

    call DrawSprite

.done:
    pop si
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 4

; ------------------------------------------------------------
; Procedure: DrawScore32
; Purpose:
;   Render six zero-padded digits from the two-word score.
; Inputs:
;   [BP+4]=state, +6=x, +8=y.
;   ES=frame-buffer segment.
; Outputs:
;   Score rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

DrawScore32:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov di, [bp + 4]

    mov ax, [di + IT_SCORE_LO]
    mov si, [di + IT_SCORE_HI]

    mov bx, 10
    mov cx, 6

.divide:
    ; Divide high word, then low word with the high remainder.
    push ax

    mov ax, si
    xor dx, dx
    div bx
    mov si, ax

    pop ax
    div bx
    push dx

    loop .divide

    mov di, [bp + 6]
    mov cx, 6

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
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf

    pop bp
    ret 6

; ------------------------------------------------------------
; Procedure: DrawHeart
; Purpose:
;   Draw one filled or outlined 7x6 heart.
; Inputs:
;   [BP+4]=x, +6=y, +8=filled flag.
;   ES=frame-buffer segment.
; Outputs:
;   Heart icon rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 6 bytes.
; ------------------------------------------------------------

DrawHeart:
    push bp
    mov bp, sp

    pushf
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, heart_outline

    cmp word [bp + 8], 0
    je .source_ready

    mov si, heart_filled

.source_ready:
    xor di, di

.row:
    xor bx, bx

.column:
    mov al, [si]

    mov cl, 6
    sub cl, bl
    shr al, cl

    test al, 1
    jz .next_pixel

    mov ax, 8

    cmp word [bp + 8], 0
    je .colour_ready

    mov ax, 4

.colour_ready:
    push ax

    mov ax, [bp + 6]
    add ax, di
    push ax

    mov ax, [bp + 4]
    add ax, bx
    push ax

    call PutPixel

.next_pixel:
    inc bx
    cmp bx, 7
    jl .column

    inc si
    inc di

    cmp di, 6
    jl .row

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
; Procedure: DrawItemHUD
; Purpose:
;   Render score, coins, lives, and two health hearts.
; Inputs:
;   [BP+4]=state.
;   ES=frame-buffer segment.
; Outputs:
;   Current item/game counters rendered.
; Registers changed:
;   None. Flags preserved.
; Stack:
;   Callee removes 2 bytes.
; Notes:
;   Full labels and WORLD field remain for final HUD layout.
; ------------------------------------------------------------

DrawItemHUD:
    push bp
    mov bp, sp

    pushf
    push ax
    push si

    mov si, [bp + 4]

    ; Score.
    mov ax, 3
    push ax

    mov ax, 40
    push ax

    push si
    call DrawScore32

    ; Coins.
    mov ax, 2
    push ax

    mov ax, 3
    push ax

    mov ax, 112
    push ax

    mov ax, [si + IT_COINS]
    push ax

    call DrawNumber

    ; Lives.
    mov ax, 2
    push ax

    mov ax, 3
    push ax

    mov ax, 160
    push ax

    mov ax, [si + IT_LIVES]
    push ax

    call DrawNumber

    ; First heart.
    xor ax, ax

    cmp word [si + IT_HP], 0
    je .first_heart

    inc ax

.first_heart:
    push ax

    mov ax, 4
    push ax

    mov ax, 208
    push ax

    call DrawHeart

    ; Second heart.
    xor ax, ax

    cmp word [si + IT_HP], 2
    jne .second_heart

    inc ax

.second_heart:
    push ax

    mov ax, 4
    push ax

    mov ax, 220
    push ax

    call DrawHeart

    pop si
    pop ax
    popf

    pop bp
    ret 2

; This include connects the actual enemy implementation.
%include "enemies.inc"