#!/bin/bash
# MTX512: make boot3.rom (SDX ROM + 80 column character ROM + CP/M bootstrap PROM) on the MiSTer itself.
# Put your three ROM files in games/MTX512/boot3_parts/ with these names, each exactly 8192 bytes:
#     sdx.rom       an SDX ROM (SDX BASIC)        -- or the CP/M PROM again if you have no SDX ROM
#     font.bin      the 80 column character ROM, as a binary file (a HEX file needs tools/make_boot3_rom.py on a PC)
#     prom.rom      the SDX CP/M bootstrap PROM
# Then run it from the MiSTer main menu: Scripts -> MTX512_make_boot3. Load the core again afterwards.
DIR=${MTX_DIR:-/media/fat/games/MTX512}
P="$DIR/boot3_parts"
for f in sdx.rom font.bin prom.rom; do
	if [ ! -f "$P/$f" ]; then
		echo "Cannot find $P/$f"
		sleep 6
		exit 1
	fi
	n=$(wc -c < "$P/$f")
	if [ "$n" -ne 8192 ]; then
		echo "$P/$f is $n bytes: it must be exactly 8192"
		sleep 6
		exit 1
	fi
done
if [ -f "$DIR/boot3.rom" ] && [ ! -f "$DIR/boot3.rom.bak" ]; then
	cp "$DIR/boot3.rom" "$DIR/boot3.rom.bak"
fi
if cat "$P/sdx.rom" "$P/font.bin" "$P/prom.rom" > "$DIR/boot3.rom"; then
	echo "Made $DIR/boot3.rom (24576 bytes). Load the core again."
else
	echo "Could not write $DIR/boot3.rom"
fi
sleep 6
