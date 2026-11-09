"""OSD 'Joysticks: On / Off' (default On). Off disconnects both joystick ports from the keyboard matrix: a way to tell whether a joystick (or a USB
device that looks like one) is pressing keys."""
import os

P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'MTX512.sv')
s = open(P, newline='').read()
crlf = chr(13) + chr(10) in s
s = s.replace(chr(13) + chr(10), chr(10))
for a, b in (
    ('\t"O[12],Joystick ports,Normal,Swapped;",\n', '\t"O[12],Joystick ports,Normal,Swapped;",\n\t"O[24],Joysticks,On,Off;",\n'),
    ("wire [31:0] joy_port1 = joy_armed ? joy_raw1 : 32'd0;", "wire [31:0] joy_port1 = (joy_armed & ~status[24]) ? joy_raw1 : 32'd0;"),
    ("wire [31:0] joy_port2 = joy_armed ? joy_raw2 : 32'd0;", "wire [31:0] joy_port2 = (joy_armed & ~status[24]) ? joy_raw2 : 32'd0;"),
):
    assert a in s, a
    s = s.replace(a, b, 1)
open(P, 'w', newline='').write(s.replace(chr(10), chr(13) + chr(10)) if crlf else s)
print('patched')
