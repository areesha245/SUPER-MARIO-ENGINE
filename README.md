# Super Mario Engine

A single-player platform game written in 16-bit x86 Assembly using
NASM and running in DOSBox.

Course: Computer Organization and Assembly Language  
Section: BSE-3B

## Team

| Member | Roll Number |
|---|---|
| Areesha Matloob | 25F-3007 |
| Breera Mushtaq | 25F-3025 |

## Contributions and Responsibilities

### Areesha Matloob
Handled the local project setup, AI-assisted source integration,
NASM/DOSBox builds, troubleshooting of assembly errors, gameplay
checks, final executable generation, and initial repository upload.

### Breera Mushtaq
Assigned responsibility for detailed rules verification, screenshots
and captions, independent verification of build/run instructions,
and preparation of testing and documentation sections.

Breera's assigned tasks will be recorded as completed contributions
only after they have actually been performed.

## Tools and Requirements

- NASM assembler.
- DOSBox.
- A text editor for reviewing and modifying the source.

The current executable was built and run by Areesha using NASM
0.98.38 in DOSBox.

## Project Files

| File | Purpose |
|---|---|
| `mario.asm` | Program setup, interrupts, movement, collision, camera, rendering, game states and screen transitions |
| `assets.inc` | Sprite artwork, palette selectors and original level map |
| `items.inc` | Collectibles, scoring, health, HUD helpers and enemy integration |
| `enemies.inc` | Goombas, Koopas, shells, stomps and enemy damage |
| `MARIO.COM` | Compiled DOS executable |

Keep all four source files in the same directory.

`mario.asm` includes `assets.inc` and `items.inc`.
`items.inc` includes `enemies.inc`; do not include it a second time.

## Build and Run

The following example assumes the project is stored in the Windows
folder `C:\Assembly`. Replace that path if your folder is elsewhere.

Start DOSBox and enter:

```dos
mount c "C:\Assembly"
c:
nasm -f bin mario.asm -o MARIO.COM
```

Only after assembly completes without errors, run:

```dos
MARIO.COM
```

If `MARIO.COM` is already available, assembly is not required merely
to play the existing executable.

When files have changed outside DOSBox, use `rescan` before rebuilding.
Do not run an older executable after a failed build.

## Controls

| Key | Action |
|---|---|
| Left / Right | Move |
| Left Shift | Run |
| Space | Jump; hold for a higher jump |
| Up / Down | Change title-menu selection |
| Enter | Select a menu option or return from an end screen |
| P | Pause / resume |
| Esc | Return from gameplay/pause to title; exit from title |

## Debug Controls

These keys are available during gameplay for testing:

| Key | Action |
|---|---|
| G | Test Small/Super form; growth checks clearance above Mario |
| T | Set remaining time to 5 seconds |
| C | Set coins to 99; collect another coin to test an extra life |
| V | Open/close the sprite gallery; simulation freezes while it is open |

Debug controls are testing aids, not replacements for normal gameplay
verification.

## Game States

The game uses a state variable and an indexed update-handler table.

- Title: choose Start Game or Exit.
- Playing: update movement, collisions, entities, scoring and time.
- Paused: freeze gameplay until resume or return to title.
- Dying: run the death animation without normal gameplay updates.
- Life Lost: show remaining lives before restarting the level.
- Win Sequence: slide down the flag pole and walk away.
- Level Complete: display results, including the remaining-time bonus.
- Game Over: display the final score after the last life is lost.
- Exit: restore the system state and return to DOS.

## Memory and Rendering

The program is a `.COM` executable with entry offset `100h`.

Code, game data and stack share the program segment. A separate
64,000-byte segment is allocated for the off-screen frame buffer
using DOS memory services.

Frames are drawn into that buffer and then copied to VGA video memory.
Block operations use string instructions such as `REP STOSW`,
`REP MOVSW` and `REP MOVSB`.

The original level map is kept separately from the working map.
Restarting a level restores the working map from the original.

Positions use a whole-pixel word plus a fractional word containing
0–255. Velocities use signed 8.8 fixed-point values. This position
representation should be distinguished from a single-word 8.8 format.

The game uses the unchanged BIOS timer rate of approximately
18.2 ticks per second. Keyboard and timer hooks are restored on exit.

## Reset Behaviour

After losing a life, score and coins are retained, while the level,
entities, Mario's position/form, camera and clock are reset.

Starting a new game resets score and coins to zero, lives to 3,
health to Small Mario and time to 300.

## Verification Status

Areesha has reported successful assembly and execution of the current
`MARIO.COM`.

Detailed rule-by-rule results and screenshots will be added after
the corresponding tests are individually recorded. Successful
execution alone is not evidence that every specification check passes.

## Current Limitations and Documentation Status

- Personal team details have not yet been inserted into the title screen.
- Detailed testing evidence and screenshots are still being prepared.
- GitHub tracking began after the working implementation; the initial
  upload does not represent the earlier development history.
- The position representation differs from a single-word 8.8 format,
  as explained above.
- Build/run verification currently reflects the team's reported setup,
  not compatibility testing across multiple assembler versions.

## AI Assistance

AI assistance was used extensively for code generation, integration,
debugging suggestions and documentation drafts. This is not a claim
of unaided authorship.

The team must understand the submitted code, verify its behaviour,
and ensure that this use complies with the instructor's permission.