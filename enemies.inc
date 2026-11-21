; ============================================================
; SUPER MARIO ENGINE
; Enemy logic, shells, stomps, and damage
;
; Included by ITEMS.INC.
; Do not assemble separately.
;
; Enemy record:
;   +0  state
;   +2  type: 0 Goomba, 1 Koopa
;   +4  timer
;   +6  shell grace timer
;   +8  compatible 20-byte H_* motion record
;
; State:
;   0 dormant
;   1 walking
;   2 flat Goomba
;   3 stationary shell
;   4 sliding shell
;   5 removed
; ============================================================

EN_COUNT        equ 6
EN_BYTES        equ 28

EN_STATE        equ 0
EN_TYPE         equ 2
EN_TIMER        equ 4
EN_GRACE        equ 6
EN_MOTION       equ 8

EN_DORMANT      equ 0
EN_WALKING      equ 1
EN_FLAT         equ 2
EN_SHELL_STILL  equ 3
EN_SHELL_SLIDE  equ 4
EN_REMOVED      equ 5

GOOMBA_SPEED    equ 211
KOOPA_SPEED     equ 316
SHELL_SPEED     equ 1266

; Original enemy templates:
; header: state,type,timer,grace
; motion: x,xf,y,yf,vx,vy,ground,face,pose,height

enemy_templates:
    dw 0,0,0,0
    dw 160,0,144,0,-GOOMBA_SPEED,0,1,1,0,16

    dw 0,0,0,0
    dw 224,0,144,0,-GOOMBA_SPEED,0,1,1,0,16

    dw 0,0,0,0
    dw 432,0,144,0,-GOOMBA_SPEED,0,1,1,0,16

    dw 0,1,0,0
    dw 480,0,144,0,-KOOPA_SPEED,0,1,1,0,16

    dw 0,1,0,0
    dw 736,0,144,0,-KOOPA_SPEED,0,1,1,0,16

    dw 0,0,0,0
    dw 768,0,144,0,-GOOMBA_SPEED,0,1,1,0,16

stomp_points:
    dw 100,200,400,500,800
    dw 1000,2000,4000,5000,8000

; ------------------------------------------------------------
; InitEnemies
; Purpose: Restore enemy records from original templates.
; Input: [BP+4]=item/game-state record.
; Output: Enemy table reset.
; Registers changed: None; flags preserved.
; Callee removes 2 bytes.
; ------------------------------------------------------------

InitEnemies:
    push bp
    mov bp, sp
    pushf
    push ax
    push di

    mov di, [bp + 4]
    add di, IT_ENEMIES

    mov ax, EN_COUNT * EN_BYTES
    push ax
    mov ax, enemy_templates
    push ax
    push di
    call CopyBytes

    pop di
    pop ax
    popf
    pop bp
    ret 2

; ------------------------------------------------------------
; StepEnemy
; Purpose: Activate and move one enemy or shell.
; Inputs: [BP+4]=enemy, +6=map, +8=camera x.
; Output: Enemy record updated.
; Registers changed: None; flags preserved.
; Callee removes 6 bytes.
; ------------------------------------------------------------

StepEnemy:
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
    lea si, [di + EN_MOTION]

    cmp word [di + EN_STATE], EN_REMOVED
    jne .check_bounds
    jmp .done

.check_bounds:
    cmp word [si + H_Y], WORLD_H
    jl .check_left
    jmp .remove

.check_left:
    mov ax, [bp + 8]
    sub ax, 32
    cmp [si + H_X], ax
    jge .check_dormant
    jmp .remove

.check_dormant:
    cmp word [di + EN_STATE], EN_DORMANT
    jne .active

    mov ax, [bp + 8]
    add ax, SCREEN_W + 16
    cmp [si + H_X], ax
    jle .activate
    jmp .done

.activate:
    mov word [di + EN_STATE], EN_WALKING

.active:
    cmp word [di + EN_GRACE], 0
    je .check_flat
    dec word [di + EN_GRACE]

.check_flat:
    cmp word [di + EN_STATE], EN_FLAT
    jne .ledge_check

    cmp word [di + EN_TIMER], 0
    jne .flat_timer_running
    jmp .remove

.flat_timer_running:
    dec word [di + EN_TIMER]
    jmp .done

.ledge_check:
    ; Only a walking Koopa avoids platform edges.
    cmp word [di + EN_STATE], EN_WALKING
    jne .gravity
    cmp word [di + EN_TYPE], 1
    jne .gravity
    cmp word [si + H_GROUND], 0
    je .gravity

    mov bx, [si + H_X]
    cmp word [si + H_VX], 0
    jl .left_probe

    add bx, 16
    jmp .probe

.left_probe:
    dec bx

.probe:
    mov ax, [si + H_Y]
    add ax, 16
    push ax
    push bx
    mov ax, [bp + 6]
    push ax
    call GetTile

    cmp ax, 1
    jb .turn_at_edge
    cmp ax, 10
    jbe .gravity

.turn_at_edge:
    neg word [si + H_VX]

.gravity:
    mov ax, [si + H_VY]
    add ax, GRAVITY
    cmp ax, FALL_LIMIT
    jle .fall_ready
    mov ax, FALL_LIMIT

.fall_ready:
    mov [si + H_VY], ax
    mov dx, [si + H_VX]

    mov ax, [bp + 6]
    push ax
    push si
    call MoveHorizontal

    ; A wall sets VX to zero: reverse the previous direction.
    cmp word [si + H_VX], 0
    jne .vertical
    or dx, dx
    jz .vertical
    neg dx
    mov [si + H_VX], dx

.vertical:
    ; Enemies do not jump; this is downward tile resolution.
    mov ax, [bp + 6]
    push ax
    push si
    call MoveVertical

    cmp word [si + H_Y], WORLD_H
    jge .remove
    jmp .done

.remove:
    mov word [di + EN_STATE], EN_REMOVED

.done:
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
; CollideWalkers
; Purpose: Turn walking enemies when their rectangles overlap.
; Input: [BP+4]=item/game-state record.
; Output: Walking directions/positions corrected.
; Registers changed: None; flags preserved.
; Callee removes 2 bytes.
; ------------------------------------------------------------

CollideWalkers:
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
    add si, IT_ENEMIES
    mov cx, EN_COUNT - 1

.outer:
    mov di, si
    add di, EN_BYTES
    mov dx, cx

.inner:
    cmp word [si + EN_STATE], EN_WALKING
    jne .next
    cmp word [di + EN_STATE], EN_WALKING
    jne .next

    lea ax, [di + EN_MOTION]
    push ax
    lea ax, [si + EN_MOTION]
    push ax
    call HeroItemOverlap

    or ax, ax
    jz .next

    neg word [si + EN_MOTION + H_VX]
    neg word [di + EN_MOTION + H_VX]

    ; Separate the pair to prevent repeated reversal in overlap.
    mov ax, [si + EN_MOTION + H_X]
    mov bx, [di + EN_MOTION + H_X]
    cmp ax, bx
    jge .place_right

    mov ax, bx
    sub ax, 16
    jmp .place

.place_right:
    mov ax, bx
    add ax, 16

.place:
    mov [si + EN_MOTION + H_X], ax
    mov word [si + EN_MOTION + H_XF], 0

.next:
    add di, EN_BYTES
    dec dx
    jnz .inner

    add si, EN_BYTES
    dec cx
    jnz .outer

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    pop bp
    ret 2

; ------------------------------------------------------------
; ResolveShellKills
; Purpose: Sliding shells remove walking enemies for +500 each.
; Input: [BP+4]=item/game-state record.
; Output: Enemy states and score updated.
; Registers changed: None; flags preserved.
; Callee removes 2 bytes.
; ------------------------------------------------------------

ResolveShellKills:
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
    add si, IT_ENEMIES
    mov cx, EN_COUNT

.shell:
    cmp word [si + EN_STATE], EN_SHELL_SLIDE
    jne .next_shell

    mov di, [bp + 4]
    add di, IT_ENEMIES
    mov dx, EN_COUNT

.target:
    cmp word [di + EN_STATE], EN_WALKING
    jne .next_target

    lea ax, [di + EN_MOTION]
    push ax
    lea ax, [si + EN_MOTION]
    push ax
    call HeroItemOverlap

    or ax, ax
    jz .next_target

    mov word [di + EN_STATE], EN_REMOVED

    mov ax, 500
    push ax
    mov ax, [bp + 4]
    push ax
    call AddScore

.next_target:
    add di, EN_BYTES
    dec dx
    jnz .target

.next_shell:
    add si, EN_BYTES
    dec cx
    jnz .shell

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    pop bp
    ret 2

; ------------------------------------------------------------
; AwardStomp
; Purpose: Apply the manual's stomp-chain points/extra life.
; Input: [BP+4]=item/game-state record.
; Output: Chain, score, or lives updated.
; Registers changed: None; flags preserved.
; Callee removes 2 bytes.
; ------------------------------------------------------------

AwardStomp:
    push bp
    mov bp, sp
    pushf
    push ax
    push bx
    push si

    mov si, [bp + 4]
    inc word [si + IT_CHAIN]
    mov bx, [si + IT_CHAIN]

    cmp bx, 10
    ja .extra_life

    dec bx
    shl bx, 1
    mov ax, [stomp_points + bx]
    push ax
    push si
    call AddScore
    jmp .done

.extra_life:
    ; Saturate the chain index and cap the life count.
    mov word [si + IT_CHAIN], 11
    cmp word [si + IT_LIVES], 99
    jae .done
    inc word [si + IT_LIVES]

.done:
    pop si
    pop bx
    pop ax
    popf
    pop bp
    ret 2

; ------------------------------------------------------------
; ResolveHeroEnemy
; Purpose: Resolve one hero/enemy overlap: kick, stomp, or hurt.
; Inputs: [BP+4]=hero, +6=enemy, +8=state, +10=key table.
; Output: Motion, enemy, score, HP, and damage flags updated.
; Registers changed: None; flags preserved.
; Callee removes 8 bytes.
; ------------------------------------------------------------

ResolveHeroEnemy:
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
    mov di, [bp + 6]
    mov bx, [bp + 8]

    mov ax, [di + EN_STATE]
    cmp ax, EN_WALKING
    je .test_overlap
    cmp ax, EN_SHELL_STILL
    je .test_overlap
    cmp ax, EN_SHELL_SLIDE
    je .check_grace
    jmp .done

.check_grace:
    cmp word [di + EN_GRACE], 0
    je .test_overlap
    jmp .done

.test_overlap:
    lea ax, [di + EN_MOTION]
    push ax
    push si
    call HeroItemOverlap
    or ax, ax
    jnz .overlap
    jmp .done

.overlap:
    ; A stationary shell is harmless and is kicked on contact.
    cmp word [di + EN_STATE], EN_SHELL_STILL
    jne .stomp_test

    mov word [di + EN_STATE], EN_SHELL_SLIDE
    mov word [di + EN_GRACE], 8
    mov ax, SHELL_SPEED

    mov dx, [si + H_X]
    cmp dx, [di + EN_MOTION + H_X]
    jl .kick_ready
    neg ax

.kick_ready:
    mov [di + EN_MOTION + H_VX], ax

    mov ax, 400
    push ax
    push bx
    call AddScore
    jmp .done

.stomp_test:
    cmp word [si + H_VY], 0
    jg .previous_feet
    jmp .hurt_test

.previous_feet:
    mov ax, [di + EN_MOTION + H_Y]
    add ax, 8
    cmp [bx + IT_PREV_FEET], ax
    jle .stomp
    jmp .hurt_test

.stomp:
    cmp word [di + EN_STATE], EN_SHELL_SLIDE
    jne .walking_stomp

    mov word [di + EN_STATE], EN_SHELL_STILL
    mov word [di + EN_MOTION + H_VX], 0
    mov word [di + EN_GRACE], 0
    jmp .bounce

.walking_stomp:
    cmp word [di + EN_TYPE], 1
    je .koopa_shell

    mov word [di + EN_STATE], EN_FLAT
    mov word [di + EN_TIMER], 18
    mov word [di + EN_MOTION + H_VX], 0
    jmp .bounce

.koopa_shell:
    mov word [di + EN_STATE], EN_SHELL_STILL
    mov word [di + EN_MOTION + H_VX], 0

.bounce:
    mov ax, [di + EN_MOTION + H_Y]
    sub ax, [si + H_HEIGHT]
    mov [si + H_Y], ax
    mov word [si + H_YF], 0
    mov word [si + H_GROUND], 0

    mov ax, -1280
    mov dx, [bp + 10]
    push bx
    mov bx, dx
    cmp byte [bx + K_SPACE], 0
    pop bx
    je .bounce_ready
    mov ax, -2000

.bounce_ready:
    mov [si + H_VY], ax
    push bx
    call AwardStomp
    jmp .done

.hurt_test:
    cmp word [bx + IT_INVULN], 0
    je .hp_check
    jmp .done

.hp_check:
    cmp word [bx + IT_HP], 2
    jne .fatal

    ; Shrink while preserving the feet position.
    mov word [bx + IT_HP], 1
    cmp word [si + H_HEIGHT], 32
    jne .invulnerable
    add word [si + H_Y], 16
    mov word [si + H_HEIGHT], 16

.invulnerable:
    mov word [bx + IT_INVULN], 36
    jmp .done

.fatal:
    ; Phase 5 replaces the immediate reset with DYING.
    mov word [bx + IT_HP], 0
    mov word [bx + IT_DEAD], 1
    mov word [si + H_Y], WORLD_H
    mov word [si + H_VY], 0

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
; UpdateEnemies
; Purpose: Update all enemies and resolve their interactions.
; Inputs:
;   [BP+4]=hero, +6=map, +8=state, +10=camera value,
;   +12=key table, +14=address of blink-control byte.
; Output: Enemy/game state and blink-control updated.
; Registers changed: None; flags preserved.
; Callee removes 12 bytes.
; ------------------------------------------------------------

UpdateEnemies:
    push bp
    mov bp, sp
    pushf
    push ax
    push bx
    push cx
    push si
    push di

    mov si, [bp + 4]
    mov di, [bp + 8]

    cmp word [di + IT_INVULN], 0
    je .chain
    dec word [di + IT_INVULN]

.chain:
    cmp word [si + H_GROUND], 0
    je .movement
    mov word [di + IT_CHAIN], 0

.movement:
    lea bx, [di + IT_ENEMIES]
    mov cx, EN_COUNT

.step:
    mov ax, [bp + 10]
    push ax
    mov ax, [bp + 6]
    push ax
    push bx
    call StepEnemy
    add bx, EN_BYTES
    loop .step

    push di
    call CollideWalkers
    push di
    call ResolveShellKills

    lea bx, [di + IT_ENEMIES]
    mov cx, EN_COUNT

.hero_collision:
    mov ax, [bp + 12]
    push ax
    push di
    push bx
    push si
    call ResolveHeroEnemy

    cmp word [di + IT_DEAD], 0
    jne .blink
    add bx, EN_BYTES
    dec cx
    jnz .hero_collision

.blink:
    ; Main rendering already supports alternate-frame blinking.
    mov bx, [bp + 14]
    mov byte [bx], 0

    cmp word [di + IT_INVULN], 0
    jne .set_blink
    jmp .done

.set_blink:
    mov byte [bx], 1

.done:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    popf
    pop bp
    ret 12

; ------------------------------------------------------------
; DrawEnemies
; Purpose: Render active enemies/shells using existing sprites.
; Inputs: [BP+4]=state, +6=camera x; ES=frame buffer.
; Output: Enemy sprites rendered.
; Registers changed: None; flags preserved.
; Callee removes 4 bytes.
; ------------------------------------------------------------

DrawEnemies:
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
    add si, IT_ENEMIES
    mov cx, EN_COUNT

.enemy:
    mov ax, [si + EN_STATE]
    cmp ax, EN_DORMANT
    je .next
    cmp ax, EN_REMOVED
    je .next

    mov di, sprite_shell
    cmp ax, EN_SHELL_STILL
    je .descriptor
    cmp ax, EN_SHELL_SLIDE
    je .descriptor

    mov di, sprite_goomba_flat
    cmp ax, EN_FLAT
    je .descriptor

    mov di, sprite_goomba
    cmp word [si + EN_TYPE], 0
    je .descriptor
    mov di, sprite_koopa

.descriptor:
    xor ax, ax
    cmp word [si + EN_MOTION + H_VX], 0
    jge .facing
    inc ax

.facing:
    push ax
    push di
    mov ax, [si + EN_MOTION + H_Y]
    push ax
    mov ax, [si + EN_MOTION + H_X]
    sub ax, [bp + 6]
    push ax
    call DrawSprite

.next:
    add si, EN_BYTES
    loop .enemy

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    pop bp
    ret 4