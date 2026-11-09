--
-- mtx_kbd.vhd - Convert to MTX keyboard grid
--
-- The MTX keyboard is essentially an 8 x 10 grid of keys.
-- In response to PS/2 keys being pressed or released, update the grid.
--
-- Memotech keys are represented in k(79 downto 0).
-- Here is what is written on each of the keycaps :-
--
--   k     x0    x1    x2    x3    x4    x5    x6    x7    x8    x9
--
--   0x    1!    3##   5%    7'    9)    -=    \|    PAGE  BREAK F1
--   1x    ESC   2"    4$    6&    8(    0     ^~    EOL   BS    F5
--   2x    CTRL  W     R     Y     I     P     [{    UP    TAB   F2
--   3x    Q     E     T     U     O     @'    LF    LEFT  DEL   F6
--   4x    CAPS  S     F     H     K     ;+    ]}    RIGHT -     F7
--   5x    A     D     G     J     L     :*    RET   HOME  -     F3
--   6x    LSHIF X     V     N     ,<    /?    RSHIF DOWN  -     F8
--   7x    Z     C     B     M     .>   _      INS   ENT   SPACE F4
--
-- Shift+; (the PC colon) is the MTX colon key (:*, row 5 column 5) without a shift.
-- Some symbols are in different places: ( is PS/2 shift 9, MTX shift 8.
-- To avoid typing glitches, we must ensure that shifted keys on the MTX
-- keyboard map are caused by shifted presses on the PS/2 keyboard, so
--   type ^ for =
--   type = for ^
--   type ' for @
--   type @ for '
--   type # for :
--   type shift ` for `
-- This is the same remapping performed in MEMU.
--
-- BackSpace: the MTX BS key only moves the cursor left (control code 8); the key that erases is DEL,
-- which removes the character under the cursor and closes the gap (operator's manual, cursor keypad:
-- "the DEL and EOL keys to erase text"). A PC BackSpace is expected to remove the character to its left,
-- so BackSpace sends BS and then DEL, each held long enough for the OS keyboard scan to see it, with a gap
-- between. Shift+BackSpace is the plain MTX BS key. The PC Delete key is the MTX DEL key.
--
-- At present, only the UK PS/2 keyboard and UK MTX layouts are supported.
-- There are some comments in the code below about the US PS/2 keyboard.
--
-- In principle, the French, German and Swedish MTX keyboard layouts could be
-- inferred from the ROM listing, combined with photos of the keyboards.
--
-- in(6) data changed to match Claus Baekkel observation (top 4 bits zero).
--
-- References
--   http://www.usna.edu/EE/ec463/labs/lab1/PS2_KB_Rapid_Prototyping_SOPC.pdf
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx_kbd is
  port
    (
    -- keys from PS/2 keyboard
    clk_1mhz   : in  std_logic;
    key_ready  : in  std_logic;
    key_stroke : in  std_logic;
    key_code   : in  std_logic_vector(9 downto 0);
    -- CPU interface
    drive      : in  std_logic_vector(7 downto 0);
    sense5     : out std_logic_vector(7 downto 0);
    sense6     : out std_logic_vector(7 downto 0);
    -- other non-MTX keys
    extra_keys : out std_logic_vector(13 downto 0);
      -- 0=>F9, 1=>F10, 2=>F11, 3=>F12,
      -- 4=>PrtScrn, 5=>ScrollLock, 6=>Num-, 7=>Num+
      -- 8=>NumEnter, 9=>Menu, 10=>NumIns, 11=>NumDel
      -- 12=>LeftWindows, 13=>RightWindows
    -- keys pressed by the core itself (0 = pressed, in the numbering of k below): mtx_autorom types ROM 3
    inj        : in  std_logic_vector(79 downto 0) := (others => '1');
    -- CP/M is running (OSD Disc ROM = CP/M): BackSpace is the plain MTX BS key. The BS then DEL pair is for the MTX OS and BASIC; in CP/M
    -- both codes erase (^H and rubout), so the pair would take two characters
    cpm_mode   : in  std_logic := '0'
    );
end mtx_kbd;

architecture behavior of mtx_kbd is

  function driven8(k : std_logic_vector(7 downto 0); d : std_logic)
    return std_logic_vector is
  begin
    return k or ( d&d&d&d&d&d&d&d );
  end;

  function driven2(k : std_logic_vector(1 downto 0); d : std_logic)
    return std_logic_vector is
  begin
    return k or ( d&d );
  end;

  -- Normal MTX keys
  signal k : std_logic_vector(79 downto 0) := (others => '1');

  -- Remember if PS/2 key was pressed with shift
  -- so that when it is released, we remove the same MTX key
  signal shifts : std_logic_vector(11 downto 0);
  signal colon_sh : std_logic := '0';             -- Shift+; is down as the MTX colon key: the shift keys are hidden
  signal col_st   : integer range 0 to 3 := 0;    -- 0 idle, 1 shift hidden and waiting to press the colon key, 2 colon key down, 3 released, waiting to show the shift
  signal col_cnt  : integer range 0 to 2000000 := 0;
  constant COL_HOLD : integer := 1000000;         -- 20 ms at 50 MHz
  signal km, cmask : std_logic_vector(79 downto 0);

  -- CP/M mode: the shift and control keys as the CPU sees them are frozen while another key is held (see below)
  signal kl : std_logic_vector(79 downto 0);
  signal any_key : std_logic;
  signal any_d   : std_logic := '0';
  signal lat60, lat66, lat20 : std_logic := '1';

  -- Extra non-MTX keys
  signal xk : std_logic_vector(13 downto 0) := (others => '1');
  signal pause_cnt : integer range 0 to 131071 := 0;   -- Pause is a press without a release: counts 1MHz clocks until BREAK is let go

  -- BackSpace sequence: BS then DEL. seqk(0) = BS key, seqk(1) = DEL key, 0 = pressed
  signal seqk   : std_logic_vector(1 downto 0) := "11";
  signal bs_ph  : integer range 0 to 4 := 0;       -- 0 idle, 1 BS down, 2 gap, 3 DEL down, 4 gap
  signal bs_cnt : integer range 0 to 4194303 := 0;
  constant BS_HOLD : integer := 3000000;           -- 60 ms at 50 MHz
  constant BS_GAP1 : integer := 2000000;           -- 40 ms
  constant BS_GAP2 : integer := 1000000;           -- 20 ms: the PS/2 repeat cannot start the next one too soon

  -- the keys as the CPU sees them: the real keys plus the BackSpace sequence
  signal kx : std_logic_vector(79 downto 0);

begin

  -- respond to PS/2 key presses or releases
  -- some key numbers (76..89) generate fake shifts and shift releases
  -- these fake shifts have extended key codes and we ignore them
  process ( clk_1mhz )
    variable shift : std_logic;
    variable bs_go : std_logic;
  begin
    if rising_edge(clk_1mhz) then
      bs_go := '0';
      if key_ready = '1' then
        shift := ( k(60) and k(66) );
        case key_code is
                                                   -- key number, symbol
          when "00"&x"76" => k(10) <= key_stroke;  -- 110, Esc
          when "00"&x"05" => k(09) <= key_stroke;  -- 112, F1
          when "00"&x"06" => k(29) <= key_stroke;  -- 113, F2
          when "00"&x"04" => k(59) <= key_stroke;  -- 114, F3
          when "00"&x"0c" => k(79) <= key_stroke;  -- 115, F4
          when "00"&x"03" => k(19) <= key_stroke;  -- 116, F5
          when "00"&x"0b" => k(39) <= key_stroke;  -- 117, F6
          when "00"&x"83" => k(49) <= key_stroke;  -- 118, F7
          when "00"&x"0a" => k(69) <= key_stroke;  -- 119, F8
          when "00"&x"01" => xk(0) <= key_stroke;  -- 120, F9
          when "00"&x"09" => xk(1) <= key_stroke;  -- 121, F10
          when "00"&x"78" => xk(2) <= key_stroke;  -- 122, F11
          when "00"&x"07" => xk(3) <= key_stroke;  -- 123, F12
          when "01"&x"7c" => xk(4) <= key_stroke;  -- 124, PrtScn
          when "00"&x"84" => xk(4) <= key_stroke;  -- 124, Alt+PrtScn
          when "00"&x"7e" => k(08) <= key_stroke;  -- 125, ScrollLock: BREAK too, for keyboards that have no Pause or number pad
          when "01"&x"77" =>                       -- 126, Pause: the MiSTer reports a press (extended 77) and never a release,
            if key_stroke = '0' then               --      so BREAK is held for 100ms and let go by the timer below
              k(08) <= '0';
              pause_cnt <= 100000;
            end if;
          when "01"&x"7e" => k(08) <= key_stroke;  -- 126, Ctrl+Pause
          when "00"&x"0e" =>                       --   1, `|not
            -- MUST BE SHIFTED, UNSHIFTED | DOES NOTHING
            if key_stroke = '0' then
              if shift     = '0' then k(35) <= '0';                    end if;
              shifts(0) <= shift;
            else
              if shifts(0) = '0' then k(35) <= '1';                    end if;
           end if;
          when "00"&x"16" => k(00) <= key_stroke;  --   2, 1!
          when "00"&x"1e" => k(11) <= key_stroke;  --   3, 2"  (US keyboard has 2@)
          when "00"&x"26" => k(01) <= key_stroke;  --   4, 3##
          when "00"&x"25" => k(12) <= key_stroke;  --   5, 4$
          when "00"&x"2e" => k(02) <= key_stroke;  --   6, 5%
          when "00"&x"36" =>                       --   7, 6^
            -- MAP ^ TO =
            if key_stroke = '0' then
              if shift     = '0' then k(05) <= '0'; else k(13) <= '0'; end if;
              shifts(1) <= shift;
            else
              if shifts(1) = '0' then k(05) <= '1'; else k(13) <= '1'; end if;
           end if;
          when "00"&x"3d" =>                       --   8, 7&
            if key_stroke = '0' then
              if shift     = '0' then k(13) <= '0'; else k(03) <= '0'; end if;
              shifts(2) <= shift;
            else
              if shifts(2) = '0' then k(13) <= '1'; else k(03) <= '1'; end if;
           end if;
          when "00"&x"3e" =>                       --   9, 8*
            if key_stroke = '0' then
              if shift     = '0' then k(55) <= '0'; else k(14) <= '0'; end if;
              shifts(3) <= shift;
            else
              if shifts(3) = '0' then k(55) <= '1'; else k(14) <= '1'; end if;
           end if;
          when "00"&x"46" =>                       --  10, 9(
            if key_stroke = '0' then
              if shift     = '0' then k(14) <= '0'; else k(04) <= '0'; end if;
              shifts(4) <= shift;
            else
              if shifts(4) = '0' then k(14) <= '1'; else k(04) <= '1'; end if;
           end if;
          when "00"&x"45" =>                       --  11, 0)
            if key_stroke = '0' then
              if shift     = '0' then k(04) <= '0'; else k(15) <= '0'; end if;
              shifts(5) <= shift;
            else
              if shifts(5) = '0' then k(04) <= '1'; else k(15) <= '1'; end if;
           end if;
          when "00"&x"4e" =>                       --  12, -_
            if key_stroke = '0' then
              if shift     = '0' then k(75) <= '0'; else k(05) <= '0'; end if;
              shifts(6) <= shift;
            else
              if shifts(6) = '0' then k(75) <= '1'; else k(05) <= '1'; end if;
           end if;
          when "00"&x"55" =>                       --  13, =+
            -- MAP = TO ^
            if key_stroke = '0' then
              if shift     = '0' then k(45) <= '0'; else k(16) <= '0'; end if;
              shifts(7) <= shift;
            else
              if shifts(7) = '0' then k(45) <= '1'; else k(16) <= '1'; end if;
           end if;
          when "00"&x"66" =>                       --  15, BackSpace
            -- BackSpace = BS then DEL (see the header); Shift+BackSpace = the MTX BS key
            if key_stroke = '0' then
              if shift = '1' and cpm_mode = '0' then bs_go := '1'; else k(18) <= '0'; end if;   -- shift = '0' when a shift key is down
              shifts(11) <= shift and not cpm_mode;
            else
              if shifts(11) = '0' then k(18) <= '1'; end if;
            end if;
          when "01"&x"70" => k(76) <= key_stroke;  --  75, Insert
          when "01"&x"6c" => k(57) <= key_stroke;  --  80, Home
          when "01"&x"7d" => k(07) <= key_stroke;  --  85, PgUp
          when "00"&x"77" => k(07) <= key_stroke;  --  90, NumLock
          when "01"&x"4a" => k(17) <= key_stroke;  --  95, Num/
          when "00"&x"7c" => k(08) <= key_stroke;  -- 100, Num*
          when "00"&x"7b" => xk(6) <= key_stroke;  -- 105, Num-
          when "00"&x"0d" => k(28) <= key_stroke;  --  16, Tab
          when "00"&x"15" => k(30) <= key_stroke;  --  17, Q
          when "00"&x"1d" => k(21) <= key_stroke;  --  18, W
          when "00"&x"24" => k(31) <= key_stroke;  --  19, E
          when "00"&x"2d" => k(22) <= key_stroke;  --  20, R
          when "00"&x"2c" => k(32) <= key_stroke;  --  21, T
          when "00"&x"35" => k(23) <= key_stroke;  --  22, Y
          when "00"&x"3c" => k(33) <= key_stroke;  --  23, U
          when "00"&x"43" => k(24) <= key_stroke;  --  24, I
          when "00"&x"44" => k(34) <= key_stroke;  --  25, O
          when "00"&x"4d" => k(25) <= key_stroke;  --  26, P
          when "00"&x"54" => k(26) <= key_stroke;  --  27, [{
          when "00"&x"5b" => k(46) <= key_stroke;  --  28, ]}
          when "01"&x"71" => k(38) <= key_stroke;  --  76, Del
          when "01"&x"69" => k(17) <= key_stroke;  --  81, End
          when "01"&x"7a" => k(77) <= key_stroke;  --  86, PgDn
          when "00"&x"6c" => k(28) <= key_stroke;  --  91, NumHome
          when "00"&x"75" => k(27) <= key_stroke;  --  96, NumUp
          when "00"&x"7d" => k(38) <= key_stroke;  -- 101, NumPgUp
          when "00"&x"79" => xk(7) <= key_stroke;  -- 106, Num+
          when "00"&x"58" => k(40) <= key_stroke;  --  30, CapsLock
          when "00"&x"1c" => k(50) <= key_stroke;  --  31, A
          when "00"&x"1b" => k(41) <= key_stroke;  --  32, S
          when "00"&x"23" => k(51) <= key_stroke;  --  33, D
          when "00"&x"2b" => k(42) <= key_stroke;  --  34, F
          when "00"&x"34" => k(52) <= key_stroke;  --  35, G
          when "00"&x"33" => k(43) <= key_stroke;  --  36, H
          when "00"&x"3b" => k(53) <= key_stroke;  --  37, J
          when "00"&x"42" => k(44) <= key_stroke;  --  38, K
          when "00"&x"4b" => k(54) <= key_stroke;  --  39, L
          when "00"&x"4c" =>                       --  40, ;:
            -- ; is the MTX ;+ key. Shift+; (the PC colon) is the MTX :* key WITHOUT a shift (colon_sh hides the shift from the CPU
            -- while it is down), so that a colon can be typed, for instance B: in CP/M. (The # key is the colon as well.)
            -- The shift is hidden FIRST and the colon key goes down 20 ms later, and on release the colon key goes up first and the shift
            -- is shown again 20 ms later: a program that scans the rows one after another (the CP/M BIOS does, all the time) must never
            -- see the colon key and the shift on different sides of a change, or it reads Shift + colon = *.
            if key_stroke = '0' then
              if shift     = '0' then colon_sh <= '1'; col_st <= 1; col_cnt <= 0; else k(45) <= '0'; end if;
              shifts(8) <= shift;
            else
              if shifts(8) = '0' then
                k(55) <= '1'; col_st <= 3; col_cnt <= 0;
              else k(45) <= '1'; end if;
           end if;
          when "00"&x"52" =>                       --  41, '@  (US keyboard has '")
            -- MAP @ to ' and , to @
            if key_stroke = '0' then
              if shift     = '0' then k(03) <= '0'; else k(35) <= '0'; end if;
              shifts(9) <= shift;
            else
              if shifts(9) = '0' then k(03) <= '1'; else k(35) <= '1'; end if;
            end if;
          when "00"&x"5d" =>                       --  42, #~  (US keyboard has key 29, \|)
            -- MAP # TO :
            if key_stroke = '0' then
              if shift      = '0' then k(16) <= '0'; else k(55) <= '0'; end if;
              shifts(10) <= shift;
            else
              if shifts(10) = '0' then k(16) <= '1'; else k(55) <= '1'; end if;
           end if;
          when "00"&x"5a" => k(56) <= key_stroke;  --  43, Enter
          when "00"&x"6b" => k(37) <= key_stroke;  --  92, NumLeft
          when "00"&x"73" => k(57) <= key_stroke;  --  97, NumMiddle
          when "00"&x"74" => k(47) <= key_stroke;  -- 102, NumRight
          when "00"&x"12" => k(60) <= key_stroke;  --  44, LeftShift
          when "00"&x"61" => k(06) <= key_stroke;  --  45, \|  (US keyboard does not have this)
          when "00"&x"1a" => k(70) <= key_stroke;  --  46, Z
          when "00"&x"22" => k(61) <= key_stroke;  --  47, X
          when "00"&x"21" => k(71) <= key_stroke;  --  48, C
          when "00"&x"2a" => k(62) <= key_stroke;  --  49, V
          when "00"&x"32" => k(72) <= key_stroke;  --  50, B
          when "00"&x"31" => k(63) <= key_stroke;  --  51, N
          when "00"&x"3a" => k(73) <= key_stroke;  --  52, M
          when "00"&x"41" => k(64) <= key_stroke;  --  53, ,<
          when "00"&x"49" => k(74) <= key_stroke;  --  54, .>
          when "00"&x"4a" => k(65) <= key_stroke;  --  55, /?
          when "00"&x"59" => k(66) <= key_stroke;  --  57, RightShift
          when "01"&x"75" => k(27) <= key_stroke;  --  83, Up
          when "00"&x"69" => k(76) <= key_stroke;  --  93, NumEnd
          when "00"&x"72" => k(67) <= key_stroke;  --  98, NumDown
          when "00"&x"7a" => k(77) <= key_stroke;  -- 103, NumPgDn
          when "01"&x"5a" => xk(8) <= key_stroke;  -- 108, NumEnter
          when "00"&x"14" => k(20) <= key_stroke;  --  58, LeftCtrl
          when "01"&x"1f" => xk(12) <= key_stroke; --  59, LeftWindows
          when "00"&x"11" => k(57) <= key_stroke;  --  60, LeftAlt
          when "00"&x"29" => k(78) <= key_stroke;  --  61, Space
          when "01"&x"11" => k(57) <= key_stroke;  --  62, RightAlt
          when "01"&x"27" => xk(13) <= key_stroke; --  63, RightWindows
          when "01"&x"2f" => xk(9) <= key_stroke;  --  ??, Menu
          when "01"&x"14" => k(20) <= key_stroke;  --  64, RightCtrl
          when "01"&x"6b" => k(37) <= key_stroke;  --  79, Left
          when "01"&x"72" => k(67) <= key_stroke;  --  84, Down
          when "01"&x"74" => k(47) <= key_stroke;  --  89, Right
          when "00"&x"70" => xk(10) <= key_stroke; --  99, NumIns
          when "00"&x"71" => xk(11) <= key_stroke; -- 104, NumDel
          when others     =>                       -- ignore other keys
         end case;
      end if;

      -- the colon sequence (see Shift+; above)
      case col_st is
        when 1 => if col_cnt = COL_HOLD then k(55) <= '0'; col_st <= 2; col_cnt <= 0; else col_cnt <= col_cnt + 1; end if;
        when 3 => if col_cnt = COL_HOLD then colon_sh <= '0'; col_st <= 0; col_cnt <= 0; else col_cnt <= col_cnt + 1; end if;
        when others => null;
      end case;
      -- the Pause key sends no release: let BREAK go after 100ms
      if pause_cnt > 0 then
        pause_cnt <= pause_cnt - 1;
        if pause_cnt = 1 then k(08) <= '1'; end if;
      end if;
      -- BackSpace sequence: BS down, gap, DEL down, gap. A new BackSpace is only taken when idle.
      case bs_ph is
        when 0 =>
          if bs_go = '1' then bs_ph <= 1; bs_cnt <= 0; seqk <= "10"; end if;
        when 1 =>
          if bs_cnt = BS_HOLD then bs_ph <= 2; bs_cnt <= 0; seqk <= "11"; else bs_cnt <= bs_cnt + 1; end if;
        when 2 =>
          if bs_cnt = BS_GAP1 then bs_ph <= 3; bs_cnt <= 0; seqk <= "01"; else bs_cnt <= bs_cnt + 1; end if;
        when 3 =>
          if bs_cnt = BS_HOLD then bs_ph <= 4; bs_cnt <= 0; seqk <= "11"; else bs_cnt <= bs_cnt + 1; end if;
        when 4 =>
          if bs_cnt = BS_GAP2 then bs_ph <= 0; bs_cnt <= 0; else bs_cnt <= bs_cnt + 1; end if;
      end case;
    end if;
  end process;

  -- the keys as the grid has them: the PC shift is hidden while it only makes a colon (LSHIFT is key 60, RSHIFT key 66)
  cmask <= ( 60 => colon_sh, 66 => colon_sh, others => '0' );
  km <= k or cmask;

  -- The CP/M BIOS decides the character from the keys that are down at the moment it looks. If the shift (or control) key is let go
  -- while a letter is still down, the letter becomes a different character (S to s) and the BIOS types it a second time. So in CP/M
  -- mode the state of the shift, control keys is taken when the first other key goes down and kept until all the other keys are up.
  any_key <= '0' when ( km(79 downto 67) = "1111111111111" and km(65 downto 61) = "11111" and km(59 downto 41) = "1111111111111111111" and
                        km(39 downto 21) = "1111111111111111111" and km(19 downto 0) = x"FFFFF" ) else '1';
  process ( clk_1mhz )
  begin
    if rising_edge(clk_1mhz) then
      any_d <= any_key;
      if any_key = '1' and any_d = '0' then          -- the first key goes down: take the shift and control state
        lat60 <= km(60); lat66 <= km(66); lat20 <= km(20);
      end if;
    end if;
  end process;
  kl <= km when cpm_mode = '0' or any_key = '0' else
        ( km(79 downto 67) & lat66 & km(65 downto 61) & lat60 & km(59 downto 21) & lat20 & km(19 downto 0) );

  kx <= ( kl(79 downto 39) & (kl(38) and seqk(1)) & kl(37 downto 19) & (kl(18) and seqk(0)) & kl(17 downto 0) ) and inj;

  -- continuously provide sense data, so the CPU can read it
  -- the program can query multiple drive lines at once
  sense5 <= ( driven8(kx( 7 downto  0), drive(0)) and
              driven8(kx(17 downto 10), drive(1)) and
              driven8(kx(27 downto 20), drive(2)) and
              driven8(kx(37 downto 30), drive(3)) and
              driven8(kx(47 downto 40), drive(4)) and
              driven8(kx(57 downto 50), drive(5)) and
              driven8(kx(67 downto 60), drive(6)) and
              driven8(kx(77 downto 70), drive(7)) );
  -- note that sense6(3 downto 2) implies UK keyboard
  sense6 <= "000000" &
            ( driven2(kx( 9 downto  8), drive(0)) and
              driven2(kx(19 downto 18), drive(1)) and
              driven2(kx(29 downto 28), drive(2)) and
              driven2(kx(39 downto 38), drive(3)) and
              driven2(kx(49 downto 48), drive(4)) and
              driven2(kx(59 downto 58), drive(5)) and
              driven2(kx(69 downto 68), drive(6)) and
              driven2(kx(79 downto 78), drive(7)) );

  -- expose the extra keys
  extra_keys <= xk;

end behavior;
