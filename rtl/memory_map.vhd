--
-- memory_map.vhd - the MTX memory map
--
-- Maps the Z80 address and the IOBYTE (port 0) to a physical page in the on-chip memory (see Roms.mif), or to the
-- expansion RAM. A stock MTX512 has 64KB RAM, an 8KB OS ROM, and BASIC and ASSEM in the paged ROM sockets. Anything
-- that does not exist reads as open bus and ignores writes, which is what the OS RAM-size probe relies on.
--
-- IOBYTE (port 0):
--   bit 7     RELCPMH: 0 = OS ROM at 0000-1FFF, paged ROM at 2000-3FFF; 1 = all RAM
--   bits 6:4  paged ROM number (0 = BASIC, 1 = ASSEM, 2 = ROM 2, and the SDX ROM in 3 or 5 when one is loaded)
--   bits 3:0  RAM page P (see below)
--
-- Physical memory, in 8KB pages (phys_addr is the page number, 9 bits):
--   page 0..7   RAM: alpha 0-1, beta 2-3, gamma 4-5, delta 6-7  (64KB)
--   page 8      OS (fixed ROM)        } loaded at start-up: boot.rom = OS,
--   page 9      BASIC (ROM 0)         } boot1.rom = BASIC, boot2.rom = ASSEM
--   page 10     ASSEM (ROM 1)         } (or one 24KB boot.rom holding all three)
--   page 11     SDX ROM               boot3.rom (or a 32KB boot.rom). The SDX FDC 05 card enables its ROM in ROM
--                                     page 3 (the card's own schematic); a later card used ROM 5. sdx_slot5 picks.
--   page 16     the CP/M bootstrap PROM (cpm_sel = 1 puts it in the SDX ROM's place, in ROM 3 or 5)
--   page 12..15 ROM 2, sub-pages 0..3 (a boot.rom longer than 32KB: the bytes after the SDX ROM). Writing to
--                                     0000-1FFF with RELCPMH = 0 sets the sub-page (the original ROM card did that;
--                                     HiSoft Pascal is two ROMs in sub-pages 0 and 1). Only pages that were loaded answer.
--
-- The expansion RAM (ram_exp = 1) is 16 blocks of 16KB, a to p (256KB, which with the base 64KB is the 320KB of an
-- MTX512 with two expansion boards). The blocks of the RAM page P, as MEMU's documentation gives them (they follow pages
-- 246 and 247 of the operator's manual; letters a, b, c ... are blocks 1, 2, 3 ...):
--   RELCPMH = 0:  4000-7FFF   P = 0 gamma, else block 2P-1         8000-BFFF   P = 0 beta, P = 1 delta, else block 2P-2
--   RELCPMH = 1:  0000-3FFF   P = 0 delta, else block 3P-2         4000-7FFF   P = 0 gamma, else block 3P-1
--                 8000-BFFF   P = 0 beta, else block 3P
-- A block above 16 does not exist (open bus). C000-FFFF is always RAM page alpha.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity memory_map is
  port
    (
    iobyte    : in  std_logic_vector(7 downto 0);   -- IOBYTE
    sdx_en    : in  std_logic;                      -- an SDX ROM has been loaded
    sdx_slot5 : in  std_logic;                      -- the SDX ROM answers as ROM 5 (else as ROM 3)
    cpm_sel   : in  std_logic := '0';               -- the disc ROM is the CP/M bootstrap PROM (page 16), not the SDX ROM (page 11)
    ram_exp   : in  std_logic := '0';               -- the 256KB expansion RAM is fitted
    rom2_ok   : in  std_logic_vector(3 downto 0) := "0000";   -- which of the ROM 2 sub-pages were loaded
    subpage   : in  std_logic_vector(1 downto 0) := "00";     -- the ROM 2 sub-page
    addr      : in  std_logic_vector(15 downto 13); -- Top bits of Z80 address
    se        : out std_logic;                      -- on-chip memory present (enable)
    we        : out std_logic;                      -- memory is writeable
    phys_addr : out std_logic_vector(21 downto 13); -- 8KB page number
    xse       : out std_logic;                      -- expansion RAM selected (se is then 0)
    xblk      : out std_logic_vector(3 downto 0)    -- its 16KB block, 0 = a ... 15 = p
    );
end memory_map;

architecture behavior of memory_map is
begin
  process (iobyte, addr, sdx_en, sdx_slot5, cpm_sel, ram_exp, rom2_ok, subpage)
    variable p     : integer range 0 to 15;
    variable letter: integer range 0 to 47;
    variable use_x : boolean;
  begin
    p := to_integer(unsigned(iobyte(3 downto 0)));
    letter := 0;
    use_x  := false;
    xse  <= '0';
    xblk <= "0000";
    -- most likely outcome is writeable RAM
    se <= '1';
    we <= '1';
    phys_addr <= ( others => '0' );
    if addr(15 downto 14) = "11" then
      -- Top RAM page
      phys_addr <= "00000000" & addr(13); -- RAM page alpha
    elsif iobyte(7) = '0' then
      if addr = "000" then
        -- Fixed ROM page: OS
        we <= '0';
        phys_addr <= "000001000";
      elsif addr = "001" then
        -- Paged ROM
        we <= '0';
        if iobyte(6 downto 4) = "000" then
          phys_addr <= "000001001";                       -- ROM 0: BASIC
        elsif iobyte(6 downto 4) = "001" then
          phys_addr <= "000001010";                       -- ROM 1: ASSEM
        elsif iobyte(6 downto 4) = "010" and rom2_ok(to_integer(unsigned(subpage))) = '1' then
          phys_addr <= "0000011" & subpage;               -- ROM 2, the sub-page
        elsif sdx_en = '1' and ((sdx_slot5 = '0' and iobyte(6 downto 4) = "011") or
                                (sdx_slot5 = '1' and iobyte(6 downto 4) = "101")) then
          if cpm_sel = '1' then
            phys_addr <= "000010000";                     -- the CP/M bootstrap PROM
          else
            phys_addr <= "000001011";                     -- the SDX ROM
          end if;
        else
          se <= '0';                                    -- no ROM fitted
          phys_addr <= ( others => 'X' );
        end if;
      else
        -- RAM pages, RELCPMH = 0: 4000-7FFF and 8000-BFFF
        if addr(14) = '1' and addr(15) = '0' then          -- 4000-7FFF
          if p = 0 then phys_addr <= "00000010" & addr(13);        -- gamma
          else letter := 2 * p - 1; use_x := true; end if;
        else                                               -- 8000-BFFF
          if p = 0 then phys_addr <= "00000001" & addr(13);        -- beta
          elsif p = 1 then phys_addr <= "00000011" & addr(13);     -- delta
          else letter := 2 * p - 2; use_x := true; end if;
        end if;
      end if;
    else
      -- RAM pages, RELCPMH = 1: 0000-3FFF, 4000-7FFF and 8000-BFFF
      if addr(15 downto 14) = "00" then
        if p = 0 then phys_addr <= "00000011" & addr(13);          -- delta
        else letter := 3 * p - 2; use_x := true; end if;
      elsif addr(15 downto 14) = "01" then
        if p = 0 then phys_addr <= "00000010" & addr(13);          -- gamma
        else letter := 3 * p - 1; use_x := true; end if;
      else
        if p = 0 then phys_addr <= "00000001" & addr(13);          -- beta
        else letter := 3 * p; use_x := true; end if;
      end if;
    end if;

    if use_x then
      -- a block of the expansion RAM, if it is fitted and the block exists
      se <= '0';
      phys_addr <= ( others => 'X' );
      if ram_exp = '1' and letter >= 1 and letter <= 16 then
        xse  <= '1';
        xblk <= std_logic_vector(to_unsigned(letter - 1, 4));
      else
        we <= '0';
      end if;
    end if;
  end process;
end behavior;
