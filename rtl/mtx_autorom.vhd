--
-- mtx_autorom.vhd - types  ROM 3  RET  on the MTX keyboard after an SDX disc has been changed
--
-- The SDX disc system keeps the disc's directory in RAM and notices a changed disc only when it next reads the directory,
-- after which the disc is read only until the system is started again, which is what the BASIC command ROM 3 does (the
-- manual says to type ROM 3 after changing discs). Changing a disc in the MiSTer menu is the same act, so the core can type
-- the command itself: after a trigger (a disc was mounted, or the menu button) it waits until BASIC is sitting at its
-- prompt and then presses R O M space 3 RET on the keyboard matrix, like a person would.
--
-- "At its prompt" is judged by where the Z80 fetches its instructions: the BASIC ROM waits for a key in one small loop
-- (36A0..3730 of the tested BASIC ROM), where it spends two thirds of its time; a BASIC program that is running never
-- does. A window of 2^20 clocks of 50MHz (21 ms) counts the instruction fetches and those inside the loop; two windows in a
-- row with at least half of the fetches inside it mean idle. If BASIC does not become idle within about ten seconds the
-- request is dropped (the keys are never typed into a running program).
--
-- The keys are held for 60 ms with 40 ms between them, as the BackSpace sequence of mtx_kbd.vhd is, so that the 50Hz keyboard
-- scan of the OS sees each one.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx_autorom is
  generic
    (
    IDLE_LO : integer := 16#36A0#;
    IDLE_HI : integer := 16#3730#;
    HOLD    : integer := 3000000;            -- 60 ms at 50MHz
    GAP     : integer := 2000000;            -- 40 ms
    WINDOW  : integer := 1048576;            -- 21 ms
    TIMEOUT : integer := 536870911           -- about 10.7 s
    );
  port
    (
    clk50  : in  std_logic;
    reset  : in  std_logic;
    trig   : in  std_logic;                  -- one clock pulse: type ROM 3 when BASIC is idle
    a      : in  std_logic_vector(15 downto 0);
    m1_n   : in  std_logic;
    mreq_n : in  std_logic;
    inj    : out std_logic_vector(79 downto 0);   -- keys pressed (0), in the numbering of mtx_kbd
    busy   : out std_logic
    );
end mtx_autorom;

architecture behavior of mtx_autorom is

  type keys_t is array (0 to 5) of integer range 0 to 79;
  -- R 22, O 34, M 73, space 78, 3 01, RET 56   (key number = row * 10 + column)
  constant keys : keys_t := (22, 34, 73, 78, 1, 56);

  signal fetch_d   : std_logic := '0';
  signal win_cnt   : integer range 0 to WINDOW := 0;
  signal tot, idl  : integer range 0 to 1048576 := 0;
  signal idle_wins : integer range 0 to 3 := 0;

  type state_t is (S_IDLE, S_WAIT, S_PRESS, S_GAP);
  signal st      : state_t := S_IDLE;
  signal tmo     : integer range 0 to TIMEOUT := 0;
  signal tcnt    : integer range 0 to HOLD := 0;
  signal kidx    : integer range 0 to 5 := 0;
  signal pressed : std_logic := '0';

begin

  process (clk50)
    variable fetch : std_logic;
    variable ai    : integer;
  begin
    if rising_edge(clk50) then
      ----- how much of the time the CPU is in the keyboard wait loop
      if m1_n = '0' and mreq_n = '0' then fetch := '1'; else fetch := '0'; end if;
      fetch_d <= fetch;
      if fetch = '1' and fetch_d = '0' then            -- the start of an instruction fetch
        ai := to_integer(unsigned(a));
        tot <= tot + 1;
        if ai >= IDLE_LO and ai <= IDLE_HI then idl <= idl + 1; end if;
      end if;
      if win_cnt = WINDOW - 1 then
        win_cnt <= 0;
        tot <= 0;
        idl <= 0;
        if tot > 0 and idl * 2 >= tot then
          if idle_wins /= 3 then idle_wins <= idle_wins + 1; end if;
        else
          idle_wins <= 0;
        end if;
      else
        win_cnt <= win_cnt + 1;
      end if;

      ----- the request and the typing
      case st is
        when S_IDLE =>
          pressed <= '0';
          if trig = '1' then st <= S_WAIT; tmo <= 0; end if;
        when S_WAIT =>
          if trig = '1' then tmo <= 0; end if;
          if idle_wins >= 2 then
            st <= S_PRESS; kidx <= 0; tcnt <= 0; pressed <= '1';
          elsif tmo = TIMEOUT then
            st <= S_IDLE;
          else
            tmo <= tmo + 1;
          end if;
        when S_PRESS =>
          if tcnt = HOLD - 1 then st <= S_GAP; tcnt <= 0; pressed <= '0'; else tcnt <= tcnt + 1; end if;
        when S_GAP =>
          if tcnt = GAP - 1 then
            if kidx = 5 then st <= S_IDLE;
            else kidx <= kidx + 1; st <= S_PRESS; tcnt <= 0; pressed <= '1'; end if;
          else
            tcnt <= tcnt + 1;
          end if;
      end case;

      if reset = '1' then st <= S_IDLE; pressed <= '0'; idle_wins <= 0; end if;
    end if;
  end process;

  busy <= '0' when st = S_IDLE else '1';

  process (pressed, kidx)
    variable v : std_logic_vector(79 downto 0);
  begin
    v := (others => '1');
    if pressed = '1' then v(keys(kidx)) := '0'; end if;
    inj <= v;
  end process;

end behavior;
