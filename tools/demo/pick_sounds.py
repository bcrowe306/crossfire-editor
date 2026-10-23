#!/usr/bin/env python3
"""Copies the demo's sound effects from the workspace's GameSounds pack into
examples/demo_project/assets/sfx/, under the names the scripts use. Only the files listed
here are copied. The music and the bees' buzz stay synthesized (make_sounds.py): the pack has
no music and no insect.

    python3 tools/demo/pick_sounds.py [GameSounds folder]   (default: ../GameSounds)
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EDITOR = os.path.dirname(os.path.dirname(HERE))
PACK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(EDITOR, "..", "GameSounds")
OUT = os.path.join(EDITOR, "examples", "demo_project", "assets", "sfx")

SWIPES = "SWIPES - SLASHES - WHOOSHES - (58)"
IMPACTS = "IMPACTS - HITS - (50)"
COINS = "COINS - MONEY - TREASURE - (26)"
EVIL = "VOCAL EVIL - HITS - DEATHS - GROANS - (86)"
CUTE = "VOCAL CUTE - CHARACTERS - (113)"
STEPS = "FOOTSTEPS - WALKING - RUNNING - (93)"
SPLATS = "SPLATS - SQUELCHES - (36)"
POPS = "POPS - BURSTS - (26)"
CHIMES = "SUCCESS - CHIMES - (55)"
PICKUPS = "SUCCESS - PICKUPS - (109)"
TUNES = "SUCCESS - TUNES - CHEERS - (64)"
NEGATIVE = "NEGATIVE - FAILURE - TENSION - (73)"
TECH = "TECH INTERFACE - COMPUTERS - (121)"
DESTRUCTION = "EXPLOSIONS - DESTRUCTION - (80)"
SLIDERS = "SLIDERS - DRAG MOVEMENTS - (65)"
SQUEAKS = "SQUEAKS - CREAKS - (28)"
WATER = "WATER - BUBBLES - SPLASHES - (16)"

# The demo's name: (folder, the pack's file without .ogg)
PICKS = {
    # The hero
    "swing": (SWIPES, "SWIPE Whoosh 03"),
    "slash_hit": (SWIPES, "SWIPE Slash Splat 02"),
    "jump": (SWIPES, "SWIPE Whoosh 08"),
    "land": (STEPS, "FOOTSTEPS Walk Single Step Crunch Stones 05"),
    "step": (STEPS, "FOOTSTEPS (A) Single Step 01"),
    "stomp": (IMPACTS, "IMPACT Thump Thud 02"),
    "hero_hurt": (CUTE, "VOCAL CUTE Distress Pain Short 07"),
    "hero_death": (CUTE, "VOCAL CUTE Distress Pain Groan 02"),
    "splash": (WATER, "WATER Splash Short 01"),
    # The creatures
    "snail_hurt": (SPLATS, "SPLAT Short 02"),
    "snail_defeat": (SPLATS, "SPLAT Crush 05"),
    "boar_hurt": (EVIL, "VOCAL EVIL Impact Hit OOOF 03"),
    "boar_defeat": (EVIL, "VOCAL EVIL Impact Hit AHHH Short 05"),
    "bee_hurt": (CUTE, "VOCAL CUTE Distress Pain Short 03"),
    "bee_defeat": (POPS, "POP Brust 05"),
    # The boss
    "boss_hurt": (EVIL, "VOCAL EVIL Impact Hit OOOF Growl 01"),
    "boss_roar": (EVIL, "VOCAL EVIL Growl Grunt 07"),
    "boss_charge": (EVIL, "VOCAL EVIL Grunt Chomp 02"),
    "boss_slam": (DESTRUCTION, "EXPLOSION Bang Muffled 01"),
    "boss_stun": (IMPACTS, "IMPACT Metal Clang Heavy Bong 02"),
    "boss_defeat": (EVIL, "VOCAL EVIL Death Drone 07"),
    # Pickups and the world
    "coin": (COINS, "COINS Collect Chime 04"),
    "shard": (CHIMES, "SUCCESS CHIME Mystery Magic Spell Sparkle 10"),
    "heart": (CHIMES, "SUCCESS CHIME Mystery Magic Mana Swell 05"),
    "pot_break": (DESTRUCTION, "DESTRUCTION Break Impact Smash Short 01"),
    "checkpoint": (CHIMES, "SUCCESS CHIME Bells Sparkle Tune Short 01"),
    "saved": (CHIMES, "SUCCESS CHIME Bells Sparkle Tune Short 05"),
    "gate_open": (SLIDERS, "SLIDER Swipe Drag Movement Stone Heavy 01"),
    "platform": (SQUEAKS, "SQUEAK Creaking 01"),
    # Menus and dialogue
    "ui_move": (TECH, "TECH INTERFACE Computer Beeps Short 01"),
    "ui_select": (TECH, "TECH INTERFACE Beep Ascend 01"),
    "ui_back": (TECH, "TECH INTERFACE Computer Beeps Short 05"),
    "ui_toggle": (IMPACTS, "IMPACT Button Press Click 01"),
    "pause": (TECH, "TECH INTERFACE Slide Movement 07"),
    "dialogue_blip": (PICKUPS, "SUCCESS PICKUP Collect Beep Short 01"),
    # Jingles
    "level_complete": (TUNES, "SUCCESS TUNE Win Complete 03"),
    "game_over": (NEGATIVE, "NEGATIVE Failure Descending Chime 03"),
    "victory": (TUNES, "SUCCESS TUNE Win Complete Long 01"),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (folder, source) in PICKS.items():
        src = os.path.join(PACK, folder, source + ".ogg")
        if not os.path.exists(src):
            sys.exit(f"pick_sounds: {src} is missing")
        shutil.copyfile(src, os.path.join(OUT, name + ".ogg"))
    print(f"pick_sounds: {len(PICKS)} sounds from {PACK} into {OUT}")


if __name__ == "__main__":
    main()
