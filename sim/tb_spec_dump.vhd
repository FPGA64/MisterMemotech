-- tb_spec_dump.vhd - writes ramcs, keyio and the RAM address of mtx_speculator for every 16 bit I/O address, read and
-- write cycles, to spec_dump.txt. check_spec_dump.py compares that with the Python board model in try_speculator.py.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use STD.ENV.ALL;

entity tb_spec_dump is
end tb_spec_dump;

architecture sim of tb_spec_dump is
  signal clk, clk50 : std_logic := '0';
  signal a : std_logic_vector(15 downto 0) := (others => '0');
  signal iorq_n, m1_n, rd_n, wr_n : std_logic := '1';
  signal d_out : std_logic_vector(7 downto 0);
  signal hit, nmi_n : std_logic;
begin
  dut : entity work.mtx_speculator
    port map (clk => clk, clk50 => clk50, reset_n => '1', en => '1', a => a, iorq_n => iorq_n, m1_n => m1_n,
              rd_n => rd_n, wr_n => wr_n, d_in => x"00", int_n => '1', d_out => d_out, hit => hit, nmi_n => nmi_n);

  process
    alias ramcs_s is << signal .tb_spec_dump.dut.ramcs : std_logic >>;
    alias keyio_s is << signal .tb_spec_dump.dut.keyio : std_logic >>;
    alias addr_s  is << signal .tb_spec_dump.dut.addr  : std_logic_vector(10 downto 0) >>;
    file f : text open write_mode is "spec_dump.txt";
    variable l : line;
  begin
    iorq_n <= '0'; m1_n <= '1';
    for cyc in 0 to 1 loop              -- 0 = read, 1 = write
      for i in 0 to 65535 loop
        a <= std_logic_vector(to_unsigned(i, 16));
        if cyc = 0 then rd_n <= '0'; wr_n <= '1'; else rd_n <= '1'; wr_n <= '0'; end if;
        wait for 1 ns;
        write(l, integer'image(cyc) & " " & integer'image(i) & " " & std_logic'image(ramcs_s)(2) & " " &
                 std_logic'image(keyio_s)(2) & " " & integer'image(to_integer(unsigned(addr_s))));
        writeline(f, l);
      end loop;
    end loop;
    finish;
  end process;
end sim;
