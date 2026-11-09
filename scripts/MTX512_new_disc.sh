#!/bin/bash
# MTX512: make a new blank SDX disc in games/MTX512 (a copy of BLANK_SDX.mfl called DISC01.mfl, DISC02.mfl, ...).
# Run it from the MiSTer main menu: Scripts -> MTX512_new_disc.
DIR=${MTX_DIR:-/media/fat/games/MTX512}
SRC="$DIR/BLANK_SDX.mfl"
if [ ! -f "$SRC" ]; then
	echo "Cannot find $SRC"
	sleep 5
	exit 1
fi
n=1
while [ -e "$DIR/$(printf 'DISC%02d' $n).mfl" ]; do
	n=$((n + 1))
done
NEW="$DIR/$(printf 'DISC%02d' $n).mfl"
if cp "$SRC" "$NEW"; then
	echo "Made $NEW"
	echo "Mount it as SDX Disc A in the core, then type ROM 3."
else
	echo "Could not make $NEW"
fi
sleep 5
