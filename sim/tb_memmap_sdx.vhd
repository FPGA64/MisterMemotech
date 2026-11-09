-- tb_memmap_sdx.vhd - which page answers at 2000-3FFF for each ROM number, with and without the SDX card, in ROM 3 or ROM 5
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_memmap_sdx is end tb_memmap_sdx;

architecture sim of tb_memmap_sdx is
  signal iobyte    : std_logic_vector(7 downto 0) := (others => '0');
  signal addr      : std_logic_vector(15 downto 13) := "001";
  signal sdx_en    : std_logic := '0';
  signal sdx_slot5 : std_logic := '0';
  signal cpm_sel   : std_logic := '0';
  signal se, we    : std_logic;
  signal phys      : std_logic_vector(21 downto 13);
begin
  dut : entity work.memory_map port map (iobyte => iobyte, sdx_en => sdx_en, sdx_slot5 => sdx_slot5, cpm_sel => cpm_sel, addr => addr,
                                         se => se, we => we, phys_addr => phys);
  process
    variable errors : integer := 0;
    procedure expect(rom : integer; en, s5 : std_logic; present : boolean; page : integer; what : string) is
    begin
      iobyte <= '0' & std_logic_vector(to_unsigned(rom, 3)) & "0000";
      sdx_en <= en; sdx_slot5 <= s5;
      wait for 10 ns;
      if present then
        if se /= '1' or we /= '0' or to_integer(unsigned(phys)) /= page then
          report "FAIL: " & what & ": se=" & std_logic'image(se) & " page=" & integer'image(to_integer(unsigned(phys))) severity error;
          errors := errors + 1;
        end if;
      else
        if se /= '0' then report "FAIL: " & what & ": answers but should be open bus" severity error; errors := errors + 1; end if;
      end if;
    end procedure;
  begin
    -- no SDX card: ROM 0 BASIC (page 9), ROM 1 ASSEM (page 10), everything else open bus, as a stock MTX
    expect(0, '0', '0', true, 9, "ROM 0, no SDX");
    expect(1, '0', '0', true, 10, "ROM 1, no SDX");
    for r in 2 to 7 loop expect(r, '0', '0', false, 0, "ROM " & integer'image(r) & ", no SDX, slot 3"); end loop;
    for r in 2 to 7 loop expect(r, '0', '1', false, 0, "ROM " & integer'image(r) & ", no SDX, slot 5"); end loop;
    -- SDX in ROM 3
    expect(0, '1', '0', true, 9, "ROM 0, SDX in 3");
    expect(1, '1', '0', true, 10, "ROM 1, SDX in 3");
    expect(3, '1', '0', true, 11, "ROM 3, SDX in 3");
    for r in 2 to 7 loop if r /= 3 then expect(r, '1', '0', false, 0, "ROM " & integer'image(r) & ", SDX in 3"); end if; end loop;
    -- SDX in ROM 5
    expect(5, '1', '1', true, 11, "ROM 5, SDX in 5");
    for r in 2 to 7 loop if r /= 5 then expect(r, '1', '1', false, 0, "ROM " & integer'image(r) & ", SDX in 5"); end if; end loop;
    -- the CP/M PROM selected (page 16) in ROM 3 or ROM 5, in the place of the SDX ROM; the other ROMs are as before
    cpm_sel <= '1';
    expect(3, '1', '0', true, 16, "ROM 3, CP/M PROM in 3");
    expect(5, '1', '0', false, 0, "ROM 5, CP/M PROM in 3");
    expect(0, '1', '0', true, 9, "ROM 0, CP/M selected");
    expect(1, '1', '0', true, 10, "ROM 1, CP/M selected");
    expect(5, '1', '1', true, 16, "ROM 5, CP/M PROM in 5");
    expect(3, '1', '1', false, 0, "ROM 3, CP/M PROM in 5");
    expect(3, '0', '0', false, 0, "ROM 3, CP/M selected but not loaded");
    cpm_sel <= '0';
    expect(3, '1', '0', true, 11, "ROM 3, SDX again");
    -- the OS ROM at 0000-1FFF and RAM above are untouched
    addr <= "000"; iobyte <= x"00"; sdx_en <= '1'; wait for 10 ns;
    if to_integer(unsigned(phys)) /= 8 then report "FAIL: OS ROM page" severity error; errors := errors + 1; end if;
    addr <= "110"; wait for 10 ns;
    if se /= '1' or we /= '1' then report "FAIL: top RAM" severity error; errors := errors + 1; end if;
    if errors = 0 then report "MEMORY MAP TEST PASSED"; else report "MEMORY MAP TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
