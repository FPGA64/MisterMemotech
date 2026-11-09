-- tb_overlay.vhd - the INOUT overlay on a real Z80 (T80) with the stock OS ROM.
-- A small program calls INOUT (0AAE) for the 18 byte header chunk, a second chunk, a zero length
-- chunk and a VERIFY; the overlay must copy the right stream bytes into RAM and leave through
-- the OS's own RESint each time.  Compile with -2008.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.ENV.ALL;

entity tb_overlay is
end tb_overlay;

architecture sim of tb_overlay is
  type mem_t is array (0 to 65535) of std_logic_vector(7 downto 0);
  type stream_t is array (0 to 4095) of std_logic_vector(7 downto 0);
  type prog_t is array (natural range <>) of std_logic_vector(7 downto 0);

  constant program : prog_t := (
    x"FB",                                -- EI: interrupts are on, as they are in BASIC
    x"31", x"00", x"F0",                  -- LD SP,F000
    x"3E", x"01", x"32", x"68", x"FD",    -- LD A,1 ; LD (FD68),A     LOAD
    x"AF", x"32", x"67", x"FD",           -- XOR A ; LD (FD67),A      not VERIFY
    x"21", x"11", x"C0", x"11", x"12", x"00", x"CD", x"AE", x"0A",   -- header: HL=C011 DE=0012
    x"21", x"00", x"90", x"11", x"20", x"00", x"CD", x"AE", x"0A",   -- chunk 2: HL=9000 DE=0020
    x"21", x"00", x"A0", x"11", x"00", x"00", x"CD", x"AE", x"0A",   -- zero length: returns at once
    x"3E", x"01", x"32", x"67", x"FD",    -- VERIFY on
    x"21", x"00", x"B0", x"11", x"08", x"00", x"CD", x"AE", x"0A",   -- verify 8: must not store
    x"AF", x"32", x"67", x"FD",           -- VERIFY off
    x"21", x"00", x"D0", x"11", x"0C", x"00", x"CD", x"AE", x"0A",   -- last 12 bytes: stream now at its end
    x"AF", x"32", x"11", x"C0",           -- LD (C011),A with A=0: clear the first header byte
    x"21", x"11", x"C0", x"11", x"12", x"00", x"CD", x"AE", x"0A",   -- header at end of stream: rewinds
    x"21", x"00", x"E0", x"11", x"00", x"01", x"CD", x"AE", x"0A",   -- 256 bytes, only 52 left: the rest is FF
    x"AF", x"32", x"68", x"FD",           -- XOR A ; LD (FD68),A      SAVE
    x"21", x"01", x"C0", x"11", x"14", x"00", x"CD", x"AE", x"0A",   -- header: HL=C001 DE=0014 (20 bytes, 18 are tape)
    x"21", x"00", x"91", x"11", x"05", x"00", x"CD", x"AE", x"0A",   -- data: HL=9100 DE=0005
    x"76");                               -- HALT

  impure function load_mem return mem_t is
    file fo : text open read_mode is "os.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable m : mem_t := (others => x"00");
    variable i : integer := 0;
  begin
    while not endfile(fo) loop
      readline(fo, l); hread(l, b); m(i) := b; i := i + 1;
    end loop;
    for k in program'range loop m(16#8000# + k) := program(k); end loop;
    for k in 0 to 19 loop m(16#C001# + k) := std_logic_vector(to_unsigned(k + 1, 8)); end loop;       -- SAVE header 01..14
    for k in 0 to 4 loop m(16#9100# + k) := std_logic_vector(to_unsigned(16#A1# + k, 8)); end loop;   -- SAVE data A1..A5
    m(0) := x"C3"; m(1) := x"00"; m(2) := x"80";       -- reset vector -> the test program
    -- VERIFY now compares: the 8 bytes it reads (stream bytes 50..57) are 00 in this stream, as is memory at B000,
    -- so the compare passes (a mismatch would end the program in the Mismatch error instead)
    return m;
  end function;

  impure function load_stream return stream_t is
    file fs : text open read_mode is "stream.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable s : stream_t := (others => x"00");
    variable i : integer := 0;
  begin
    while not endfile(fs) loop
      readline(fs, l); hread(l, b); s(i) := b; i := i + 1;
    end loop;
    return s;
  end function;

  impure function stream_count return integer is
    file fs : text open read_mode is "stream.hex";
    variable l : line;
    variable i : integer := 0;
  begin
    while not endfile(fs) loop readline(fs, l); i := i + 1; end loop;
    return i;
  end function;

  constant stream     : stream_t := load_stream;
  constant stream_len : integer  := stream_count;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal M1_n, MREQ_n, IORQ_n, RD_n, WR_n, HALT_n : std_logic;
  signal A  : std_logic_vector(15 downto 0);
  signal DI : std_logic_vector(7 downto 0);
  signal DO : std_logic_vector(7 downto 0);
  signal ovl_hit : std_logic;
  signal ovl_q   : std_logic_vector(7 downto 0);

  signal mem    : mem_t := load_mem;
  signal sidx   : integer := 0;
  signal tick   : integer := 0;
  signal ready  : std_logic;
  signal eof    : std_logic;
  signal io_q   : std_logic_vector(7 downto 0);
  signal port_reads : integer := 0;
  signal rewinds    : integer := 0;
  signal motor_off  : integer := 0;
  signal rd8e_d     : std_logic := '0';
  signal lfsr       : std_logic_vector(15 downto 0) := x"ACE1";
  signal brk_key    : std_logic := '0';
  signal in_ovl     : std_logic := '0';
  signal int_n      : std_logic := '1';
  signal int_acks   : integer := 0;
  signal last_pc    : std_logic_vector(15 downto 0) := x"0000";
  signal prev_pc    : std_logic_vector(15 downto 0) := x"0000";
  signal rst28_seen : std_logic := '0';
  signal eof_since  : integer := 0;
  type pcs_t is array (0 to 63) of std_logic_vector(15 downto 0);
  signal pcs : pcs_t := (others => x"0000");
  signal pci : integer range 0 to 63 := 0;
  signal m1_d : std_logic := '1';
  type saved_t is array (0 to 63) of std_logic_vector(7 downto 0);
  signal saved  : saved_t := (others => x"00");
  signal nsaved : integer := 0;
  signal nstart : integer := 0;
  signal nflush : integer := 0;
begin
  clk <= not clk after 125 ns;            -- 4MHz
  int_n <= '1';                           -- the overlay calls the OS SETint and leaves interrupts on, so ticks are taken while it copies; not tested here

  dut : entity work.T80se
    generic map (Mode => 1, T2Write => 0, IOWait => 1)
    port map (RESET_n => reset_n, CLK_n => clk, CLKEN => '1', WAIT_n => '1', INT_n => int_n, NMI_n => '1',
              BUSRQ_n => '1', M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n, WR_n => WR_n,
              RFSH_n => open, HALT_n => HALT_n, BUSAK_n => open, A => A, DI => DI, DO => DO);

  ovl : entity work.mtx_overlay port map (addr => A, hit => ovl_hit, q => ovl_q);

  -- the stream ports, as mtx_tape.sv: ready flickers so the polling loop is exercised; past the end of the
  -- file the stream stays ready and answers FF
  ready <= '1' when (sidx >= stream_len or lfsr(3) = '1' or lfsr(7) = '1') else '0';
  eof   <= '1' when sidx >= stream_len else '0';
  io_q  <= (7 downto 2 => '0') & eof & ready when A(7 downto 0) = x"8F" else
           x"00" when A(7 downto 0) = x"8D" else
           stream(sidx) when (A(7 downto 0) = x"8E" and sidx < stream_len and sidx < 4096) else
           x"FE" when (A(7 downto 0) = x"06" and brk_key = '1') else x"FF";

  DI <= ovl_q when (MREQ_n = '0' and RD_n = '0' and ovl_hit = '1' and A(15 downto 13) = "000") else
        mem(to_integer(unsigned(A))) when (MREQ_n = '0' and RD_n = '0') else
        io_q when (IORQ_n = '0' and RD_n = '0') else x"FF";

  process (clk)
    variable rd8e : std_logic;
  begin
    if rising_edge(clk) then
      tick <= tick + 1;
      if M1_n = '0' and MREQ_n = '0' and RD_n = '0' then
        -- everything after the DI, except the BREAK exit (0ABD..0AC0), which comes back from RESint with interrupts on
        if (unsigned(A) >= 16#0AB2# and unsigned(A) <= 16#0ABC#) or (unsigned(A) >= 16#0AC1# and unsigned(A) <= 16#0B05#) then in_ovl <= '1'; else in_ovl <= '0'; end if;
      end if;
      if M1_n = '0' and MREQ_n = '0' and RD_n = '0' then prev_pc <= last_pc; last_pc <= A; end if;
      if M1_n = '0' and IORQ_n = '0' then
        int_acks <= int_acks + 1;
        if int_acks < 4 then report "interrupt accepted after fetching " & to_hstring(last_pc) & " (before that " & to_hstring(prev_pc) & ") at " & time'image(now); end if;
      end if;
      if M1_n = '0' and MREQ_n = '0' and A = x"0028" then rst28_seen <= '1'; end if;
      if sidx >= stream_len then eof_since <= eof_since + 1; else eof_since <= 0; end if;
      -- (the BREAK key is never pressed: past the end of the stream the overlay does not wait)
      lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      if M1_n = '0' and MREQ_n = '0' and RD_n = '0' then m1_d <= '0'; else m1_d <= '1'; end if;
      if M1_n = '0' and MREQ_n = '0' and RD_n = '0' and m1_d = '1' then
        pcs(pci) <= A; pci <= (pci + 1) mod 64;
      end if;
      if MREQ_n = '0' and WR_n = '0' and unsigned(A) >= 16#2000# then
        mem(to_integer(unsigned(A))) <= DO;
      end if;
      if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = x"8F" and DO(0) = '1' then
        sidx <= 0;
        rewinds <= rewinds + 1;
      end if;
      if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = x"8E" then
        if nsaved < 64 then saved(nsaved) <= DO; end if;
        nsaved <= nsaved + 1;
      end if;
      if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = x"8F" and DO(1) = '1' then nstart <= nstart + 1; end if;
      if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = x"8F" and DO(2) = '1' then nflush <= nflush + 1; end if;
      if IORQ_n = '0' and WR_n = '0' and A(7 downto 0) = x"1F" and DO = x"55" then
        motor_off <= motor_off + 1;           -- RESint switches the cassette motor off
      end if;
      -- the stream advances when a read of port 8E has FINISHED, so the data is stable throughout it
      if IORQ_n = '0' and RD_n = '0' and A(7 downto 0) = x"8E" then rd8e := '1'; else rd8e := '0'; end if;
      rd8e_d <= rd8e;
      if rd8e_d = '1' and rd8e = '0' then
        sidx <= sidx + 1;
        port_reads <= port_reads + 1;
      end if;
    end if;
  end process;

  main : process
    variable errors : integer := 0;
  begin
    wait for 2 us;
    reset_n <= '1';
    wait until port_reads > 100 for 20 ms;            -- the program is running (HALT_n is also low in reset)
    wait until HALT_n = '0' for 40 ms;
    wait for 50 us;
    if HALT_n /= '0' then
      report "FAIL: the program never got through the read that runs past the end of the stream (port reads " & integer'image(port_reads) & ", last pc " & to_hstring(last_pc) & ")" severity error;
      errors := errors + 1;
    end if;
    for k in 0 to 17 loop
      if mem(16#C011# + k) /= stream(k) then
        report "FAIL: header byte " & integer'image(k) & " (after the rewind)" severity error; errors := errors + 1;
      end if;
    end loop;
    for k in 0 to 31 loop
      if mem(16#9000# + k) /= stream(18 + k) then
        report "FAIL: chunk 2 byte " & integer'image(k) severity error; errors := errors + 1;
      end if;
    end loop;
    if mem(16#A000#) /= x"00" then report "FAIL: zero length chunk wrote memory" severity error; errors := errors + 1; end if;
    for k in 0 to 7 loop
      if mem(16#B000# + k) /= x"00" then report "FAIL: VERIFY stored a byte" severity error; errors := errors + 1; end if;
    end loop;
    for k in 0 to 11 loop
      if mem(16#D000# + k) /= stream(58 + k) then
        report "FAIL: last 12 bytes, byte " & integer'image(k) severity error; errors := errors + 1;
      end if;
    end loop;
    for k in 0 to 51 loop
      if mem(16#E000# + k) /= stream(18 + k) then
        report "FAIL: bytes after the rewind, byte " & integer'image(k) severity error; errors := errors + 1;
      end if;
    end loop;
    for k in 52 to 255 loop
      if mem(16#E000# + k) /= x"FF" then
        report "FAIL: byte " & integer'image(k) & " past the end of the stream is not FF" severity error; errors := errors + 1;
      end if;
    end loop;
    if nstart /= 1 then report "FAIL: SAVE should start one tape, saw " & integer'image(nstart) severity error; errors := errors + 1; end if;
    if nflush /= 2 then report "FAIL: SAVE should flush twice, saw " & integer'image(nflush) severity error; errors := errors + 1; end if;
    if nsaved /= 23 then report "FAIL: SAVE should send 18 + 5 bytes, saw " & integer'image(nsaved) severity error; errors := errors + 1; end if;
    for k in 0 to 15 loop
      if saved(k) /= std_logic_vector(to_unsigned(k + 1, 8)) then report "FAIL: SAVE header byte " & integer'image(k) severity error; errors := errors + 1; end if;
    end loop;
    -- bytes 16 and 17 are at C011 and C012, which the LOAD header read before has filled with the first stream bytes
    for k in 16 to 17 loop
      if saved(k) /= stream(k - 16) then report "FAIL: SAVE header byte " & integer'image(k) severity error; errors := errors + 1; end if;
    end loop;
    for k in 0 to 4 loop
      if saved(18 + k) /= std_logic_vector(to_unsigned(16#A1# + k, 8)) then report "FAIL: SAVE data byte " & integer'image(k) severity error; errors := errors + 1; end if;
    end loop;
    report "stream bytes read " & integer'image(port_reads) & ", rewinds " & integer'image(rewinds) &
           ", RESint motor-off writes " & integer'image(motor_off);
    if port_reads /= 18 + 32 + 8 + 12 + 18 + 256 then report "FAIL: unexpected number of stream bytes" severity error; errors := errors + 1; end if;
    if rewinds /= 1 then report "FAIL: expected exactly one rewind (a header requested at the end)" severity error; errors := errors + 1; end if;
    if motor_off /= 8 then report "FAIL: RESint count (6 chunks that return + 2 SAVE chunks)" severity error; errors := errors + 1; end if;
    if errors = 0 then report "OVERLAY TEST PASSED"; else report "OVERLAY TEST FAILED" severity failure; end if;
    finish;
  end process;
end sim;
