@echo off
rem make_boot3_rom.bat - make boot3.rom (SDX ROM + 80 column character ROM + CP/M bootstrap PROM) on Windows, no Python needed.
rem
rem     make_boot3_rom.bat sdx.rom font.bin prom.rom
rem
rem Each file must be exactly 8192 bytes (the character ROM as a binary file: a HEX file needs make_boot3_rom.py).
rem The result is boot3.rom in the current folder: copy it to games\MTX512 on the SD card.
if "%~3"=="" goto usage
for %%F in ("%~1" "%~2" "%~3") do (
  if not exist "%%~F" ( echo Cannot find %%~F & goto end )
  if not "%%~zF"=="8192" ( echo %%~F is %%~zF bytes: it must be exactly 8192 & goto end )
)
if exist boot3.rom ( echo boot3.rom exists in this folder: rename or delete it first & goto end )
copy /b "%~1"+"%~2"+"%~3" boot3.rom >nul
for %%F in (boot3.rom) do echo Made boot3.rom, %%~zF bytes.
goto end
:usage
echo usage: make_boot3_rom.bat sdx.rom font.bin prom.rom
:end
