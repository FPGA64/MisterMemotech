-- tb_spec.vhd - unit tests for the Speculator board (mtx_speculator), against Speculator_Schematic.pdf
-- Compile with -2008, after mtx_speculator.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_spec is
end tb_spec;

architecture sim of tb_spec is
  signal clk, clk50 : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal en      : std_logic := '1';
  signal a       : std_logic_vector(15 downto 0) := (others => '1');
  signal iorq_n  : std_logic := '1';
  signal m1_n    : std_logic := '1';
  signal rd_n    : std_logic := '1';
  signal wr_n    : std_logic := '1';
  signal d_in    : std_logic_vector(7 downto 0) := (others => '0');
  signal int_n   : std_logic := '1';
  signal d_out   : std_logic_vector(7 downto 0);
  signal hit     : std_logic;
  signal nmi_n   : std_logic;
  signal nmi_cnt : integer := 0;
  signal nmi_t   : time := 0 ns;                  -- when the last NMI started
begin
  process (nmi_n) begin
    if falling_edge(nmi_n) then nmi_cnt <= nmi_cnt + 1; nmi_t <= now; end if;
  end process;

  clk   <= not clk   after 125 ns;     -- 4MHz
  clk50 <= not clk50 after 10 ns;      -- 50MHz (the 20ns period is 10 ns per half)

  dut : entity work.mtx_speculator
    port map (clk => clk, clk50 => clk50, reset_n => reset_n, en => en, a => a, iorq_n => iorq_n, m1_n => m1_n,
              rd_n => rd_n, wr_n => wr_n, d_in => d_in, int_n => int_n, d_out => d_out, hit => hit, nmi_n => nmi_n);

  main : process
    variable errors : integer := 0;
    variable t0, t1, t2 : time;
    variable v : std_logic_vector(7 downto 0);
    variable got_hit : std_logic;
    variable c0 : integer;

    procedure fail (msg : string) is
    begin
      errors := errors + 1;
      report "FAIL: " & msg severity error;
    end procedure;

    procedure io_write (addr : std_logic_vector(15 downto 0); data : std_logic_vector(7 downto 0)) is
    begin
      wait until falling_edge(clk);
      a <= addr; iorq_n <= '0'; m1_n <= '1'; rd_n <= '1'; d_in <= data;
      wait until falling_edge(clk);
      wr_n <= '0';
      wait until falling_edge(clk);
      wait until falling_edge(clk);
      wr_n <= '1';
      wait until falling_edge(clk);
      iorq_n <= '1';
    end procedure;

    procedure io_read (addr : std_logic_vector(15 downto 0); data : out std_logic_vector(7 downto 0); h : out std_logic) is
    begin
      wait until falling_edge(clk);
      a <= addr; iorq_n <= '0'; m1_n <= '1'; wr_n <= '1';
      wait until falling_edge(clk);
      rd_n <= '0';
      wait until falling_edge(clk);
      wait until falling_edge(clk);
      data := d_out; h := hit;
      rd_n <= '1';
      wait until falling_edge(clk);
      iorq_n <= '1';
    end procedure;

    -- one row select: A15..A8 all 1 except line (8 + k)
    function rowsel (k : integer; low : std_logic_vector(7 downto 0) := x"00") return std_logic_vector is
      variable r : std_logic_vector(7 downto 0) := x"FF";
    begin
      r(k) := '0';
      return r;
    end function;

    procedure expect (what : string; addr : std_logic_vector(15 downto 0); want : std_logic_vector(7 downto 0)) is
      variable d : std_logic_vector(7 downto 0);
      variable h : std_logic;
    begin
      io_read(addr, d, h);
      if h /= '1' then fail(what & ": board did not answer"); end if;
      if d /= want then fail(what & ": got " & to_hstring(d) & " want " & to_hstring(want)); end if;
    end procedure;
  begin
    wait for 1 us;
    reset_n <= '1';
    wait for 1 us;

    -- 1. plain registers: write, read back
    io_write(x"001F", x"A5");  expect("1F read back", x"001F", x"A5");
    io_write(x"007F", x"77");  expect("7F read back", x"007F", x"77");
    io_write(x"00FB", x"40");  expect("FB read back", x"00FB", x"40");
    -- A7 separates odd ports with A6..A0 the same: 7F and FF are different cells (FF is also the NMI port)
    io_write(x"00FF", x"FC");  expect("FF read back", x"00FF", x"FC");
    expect("7F still 77 after FF write", x"007F", x"77");
    -- ports outside the decode are not answered
    io_read(x"0042", v, got_hit);
    if got_hit /= '0' then fail("port 42 should not be answered"); end if;
    io_read(x"0001", v, got_hit);
    if got_hit /= '0' then fail("port 01 should not be answered"); end if;
    io_read(x"0010", v, got_hit);
    if got_hit /= '0' then fail("port 10 (SDX) should not be answered"); end if;
    io_read(x"008F", v, got_hit);
    if got_hit /= '0' then fail("port 8F (tape overlay) should not be answered"); end if;

    -- 2. A15..A8 are ignored by the plain ports
    io_write(x"1234", x"00");     -- port 34: not decoded
    io_write(x"AB60", x"5A");     -- port 60 (A6=A5=1)
    expect("port 60 with another high byte", x"CD60", x"5A");

    -- 3. the border: the Spectrum side OUT FE and the Speculator side IN 7E are one cell
    io_write(x"00FE", x"1D");     -- Spectrum OUT (0FEH),A  (A15..A8 whatever the code leaves; the write is not a key cycle)
    expect("border via 7E", x"007E", x"1D");
    io_write(x"7FFE", x"12");     -- OUT (C),r style with B = 7F
    expect("border via 7E again", x"007E", x"12");

    -- 4. the keyboard: the Speculator code writes a row with OUT 7E (one of A15..A8 low), the Spectrum code reads it
    --    with IN FE and the same row select
    for k in 0 to 7 loop
      io_write(rowsel(k) & x"7E", std_logic_vector(to_unsigned(16#E0# + k, 8)));
    end loop;
    for k in 0 to 7 loop
      expect("row " & integer'image(k), rowsel(k) & x"FE", std_logic_vector(to_unsigned(16#E0# + k, 8)));
    end loop;
    expect("border cell not disturbed by the key rows", x"007E", x"12");
    -- per the IC4 equations: with two lines low the higher one wins, with none low it is row 7
    expect("rows 0 and 1 low gives row 1", x"FCFE", x"E1");
    expect("no row selected gives row 7", x"FFFE", x"E7");

    -- 5. NMI: disabled after reset
    c0 := nmi_cnt;
    int_n <= '0';
    wait for 4 us;
    int_n <= '1';
    wait for 1 us;
    if nmi_cnt /= c0 then fail("NMI with NMIEN clear"); end if;

    -- NMIEN=1, NMISEL=1: NMI right at the interrupt, 1.5us long
    io_write(x"00FF", x"03");
    wait for 8 us;                                   -- (setting NMIEN gives an NMI by itself: see the tests below)
    c0 := nmi_cnt;
    int_n <= '0';
    t0 := now;
    wait until nmi_n = '0' for 2 us;
    t1 := now;
    if nmi_n /= '0' then fail("no immediate NMI");
    elsif t1 - t0 > 500 ns then fail("immediate NMI late: " & time'image(t1 - t0)); end if;
    t0 := now;
    wait until nmi_n = '1' for 5 us;
    t1 := now;
    if t1 - t0 < 1300 ns or t1 - t0 > 1700 ns then fail("immediate NMI width " & time'image(t1 - t0)); end if;
    wait for 4 us;
    if nmi_cnt /= c0 + 1 then fail("expected exactly one NMI for one /INT edge, got " & integer'image(nmi_cnt - c0)); end if;
    int_n <= '1';
    wait for 2 us;

    -- NMIEN=1, NMISEL=0: the NMI comes 1.5us after the interrupt
    io_write(x"00FF", x"01");
    wait for 8 us;
    int_n <= '0';
    t0 := now;
    wait until nmi_n = '0' for 5 us;
    t1 := now;
    if nmi_n /= '0' then fail("no delayed NMI");
    elsif t1 - t0 < 1300 ns or t1 - t0 > 1900 ns then fail("delayed NMI delay " & time'image(t1 - t0)); end if;
    t0 := now;
    wait until nmi_n = '1' for 5 us;
    t1 := now;
    if t1 - t0 < 1300 ns or t1 - t0 > 1700 ns then fail("delayed NMI width " & time'image(t1 - t0)); end if;
    int_n <= '1';
    wait for 2 us;

    -- NMIEN cleared again: no NMI
    io_write(x"00FF", x"02");
    wait for 2 us;
    c0 := nmi_cnt;
    int_n <= '0';
    wait for 4 us;
    if nmi_cnt /= c0 then fail("NMI with NMIEN written 0"); end if;
    int_n <= '1';
    wait for 2 us;

    -- Setting NMIEN (0 to 1) starts the NMI sequence by itself, whatever /INT is doing: an NMI at once with NMISEL = 1 and
    -- 1.5us later with NMISEL = 0, once. The Speculator program depends on this to get its first NMI (MEMU: "fake NMI soon").
    -- Writing 1 again while NMIEN is already 1 does nothing more.
    for lvl in 0 to 1 loop
      if lvl = 0 then int_n <= '1'; else int_n <= '0'; end if;
      io_write(x"00FF", x"00");
      wait for 4 us;
      c0 := nmi_cnt;
      t0 := now;
      io_write(x"00FF", x"03");
      wait for 8 us;
      if nmi_cnt /= c0 + 1 then fail("expected exactly one NMI on setting NMIEN (NMISEL 1), got " & integer'image(nmi_cnt - c0));
      elsif nmi_t - t0 > 1200 ns then fail("NMI on setting NMIEN late: " & time'image(nmi_t - t0)); end if;
      t2 := nmi_t - t0;                                        -- the write cycle itself plus the trigger
      c0 := nmi_cnt;
      io_write(x"00FF", x"03");                                -- again, already set: nothing
      wait for 8 us;
      if nmi_cnt /= c0 then fail("NMI from writing NMIEN = 1 again"); end if;
      io_write(x"00FF", x"00");
      wait for 4 us;
      c0 := nmi_cnt;
      t0 := now;
      io_write(x"00FF", x"01");
      wait for 10 us;
      if nmi_cnt /= c0 + 1 then fail("expected exactly one NMI on setting NMIEN (NMISEL 0), got " & integer'image(nmi_cnt - c0));
      elsif (nmi_t - t0) - t2 < 1300 ns or (nmi_t - t0) - t2 > 1700 ns then
        fail("NMI on setting NMIEN with NMISEL 0: " & time'image((nmi_t - t0) - t2) & " later than with NMISEL 1"); end if;
      io_write(x"00FF", x"00");
    end loop;
    int_n <= '1';
    wait for 2 us;

    -- reset clears NMIEN
    io_write(x"00FF", x"03");
    wait for 1 us;
    reset_n <= '0';
    wait for 1 us;
    reset_n <= '1';
    wait for 2 us;
    c0 := nmi_cnt;
    int_n <= '0';
    wait for 4 us;
    if nmi_cnt /= c0 then fail("NMI after reset"); end if;
    int_n <= '1';
    wait for 2 us;

    -- 6. a write to port FF during an interrupt acknowledge (M1 low) must not count
    io_write(x"00FF", x"00");
    wait until falling_edge(clk);
    a <= x"00FF"; iorq_n <= '0'; m1_n <= '0'; rd_n <= '1'; d_in <= x"03";
    wait until falling_edge(clk);
    wr_n <= '0';
    wait until falling_edge(clk);
    wait until falling_edge(clk);
    wr_n <= '1'; iorq_n <= '1'; m1_n <= '1';
    wait for 2 us;
    c0 := nmi_cnt;
    int_n <= '0';
    wait for 4 us;
    if nmi_cnt /= c0 then fail("a cycle with M1 low changed NMIEN"); end if;
    int_n <= '1';
    wait for 2 us;

    -- 7. not fitted: nothing answers, nothing raises NMI
    io_write(x"00FF", x"03");
    en <= '0';
    wait for 1 us;
    io_read(x"001F", v, got_hit);
    if got_hit /= '0' then fail("answered while not fitted"); end if;
    c0 := nmi_cnt;
    int_n <= '0';
    wait for 4 us;
    if nmi_cnt /= c0 then fail("NMI while not fitted"); end if;
    int_n <= '1';

    if errors = 0 then
      report "tb_spec: all checks passed" severity note;
    else
      report "tb_spec: " & integer'image(errors) & " check(s) FAILED" severity failure;
    end if;
    finish;
  end process;
end sim;
