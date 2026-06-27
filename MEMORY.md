# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- we should use manual compositing with the colors on the lower layers for the bg, if what you say is true that BLT doesn't layer bgs; but use BLT's layering to composite the two *symbols* together
- for the pause and main screens, let's use the serif font, not the tile font.
- since we now have a UI layer, we should add clicks and hovers (with {x,y} data) to the event bus, and make a function that will blit in a button, which just consists of rendering some text, and setting up an event...
- let's create a progress bar ui thing, that renders filled boxes (so, we should use bg color), and sets up a listener for an event based on the id provided to it that tells it what percent to fill to next, and also...

## Gotchas & Errors

- Archive:  monoretropixel.zip
- tobytes? False — Fix: To actually make Monosquare *fill* a 16×16 cell, you'd need to either:
- Validation failed for tool "ask_user_question": — Fix: we should use manual compositing with the colors on the lower layers for the bg, if what you say is true that BLT doesn't layer bgs; but use BLT's layering to composite the two *symbols* together
- So symbols *can* be composited by BLT — only bg fills can't.
- Could not find edits[0] in /Users/alexispurslane/Development/industrialworld/src/ui.lua. The oldText must match exactly including all whitespace and newlines.

## Heavily Read

- /Users/alexispurslane/Development/industrialworld/src/main.lua (3 reads)
- /Users/alexispurslane/Development/industrialworld/src/ui.lua (3 reads)
