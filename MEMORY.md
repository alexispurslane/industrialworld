# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- we should use manual compositing with the colors on the lower layers for the bg, if what you say is true that BLT doesn't layer bgs; but use BLT's layering to composite the two *symbols* together

## Gotchas & Errors

- Archive:  monoretropixel.zip
- tobytes? False — Fix: To actually make Monosquare *fill* a 16×16 cell, you'd need to either:
- Validation failed for tool "ask_user_question": — Fix: we should use manual compositing with the colors on the lower layers for the bg, if what you say is true that BLT doesn't layer bgs; but use BLT's layering to composite the two *symbols* together
- So symbols *can* be composited by BLT — only bg fills can't.

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/world.lua (6 reads) — Found it — that's a bug in my CORE handling. When `alpha == 0`, the code falls i
- /Users/alexispurslane/Development/industrialworld/vendor/bearlibterminal/Terminal/Source/Terminal.cpp (5 reads) — The compositing happens around line 2146–2199. Let me read it.
