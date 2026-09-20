#!/bin/bash

# Set up the Java environment
export JAVA_TOOL_OPTIONS='-Xverify:none -Djava.util.prefs.systemRoot=./.java -Djava.util.prefs.userRoot=./.java/.userPrefs -Djava.library.path=./'

# Change to the script's directory
cd "$(dirname "$0")"

# Get the game path
GAME_PATH="$1"

# Extract the resolution from the path (e.g. 320x240 in /roms/j2me/320x240/game.jar)
WIDTH=320
HEIGHT=240

if [ -n "$GAME_PATH" ]; then
    # Try to match a resolution pattern in the path (e.g. 320x240, 640x480, etc.)
    RESOLUTION=$(echo "$GAME_PATH" | grep -oP '\d{2,4}x\d{2,4}' | head -1)
    if [ -n "$RESOLUTION" ]; then
        WIDTH=$(echo "$RESOLUTION" | cut -d'x' -f1)
        HEIGHT=$(echo "$RESOLUTION" | cut -d'x' -f2)
        echo "Resolution parsed from path: ${WIDTH}x${HEIGHT}"
    else
        echo "No resolution found in path, using default: ${WIDTH}x${HEIGHT}"
    fi
fi

# If width and height were given on the command line, use those arguments
if [ -n "$2" ] && [ -n "$3" ]; then
    WIDTH="$2"
    HEIGHT="$3"
    echo "Using resolution specified on the command line: ${WIDTH}x${HEIGHT}"
fi

echo "Launching game: $GAME_PATH"
echo "Resolution: ${WIDTH}x${HEIGHT}"

# Launch the game
java -jar freej2me-sdl.jar "$GAME_PATH" "$WIDTH" "$HEIGHT" 100
