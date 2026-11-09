"""Build xram_roms.hex and tb_mtx_xram.vhd (from tb_mtx_sdx.vhd) for a whole-machine test of the memory map: the RAM pages of
the MTX512 with and without the 256KB expansion, and the sub-pages of ROM 2.

The expected values are worked out here, in Python, from MEMU's table of the memory map (the table follows pages 246 and 247
of the operator's manual), independently of rtl/memory_map.vhd:
  RELCPMH=0:  4000-7FFF  P=0 gamma, else block 2P-1       8000-BFFF  P=0 beta, P=1 delta, else block 2P-2
  RELCPMH=1:  0000-3FFF  P=0 delta, else block 3P-2       4000-7FFF  P=0 gamma, else block 3P-1     8000-BFFF  P=0 beta, else block 3P
  blocks 1..16 (a..p) are the expansion RAM, when it is fitted; any other block does not exist and reads FF.

The program (in the OS ROM, copied to RAM at C000 because RELCPMH=1 takes the OS ROM away) writes a marker into every window of
every RAM page P with RELCPMH=1, then reads back every window of every page in both modes, and the sub-pages of ROM 2.

    python make_xram_test.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
N_ROM2 = 3                                  # sub-pages 0..2 of ROM 2 are loaded, page 3 is not


def blocks_mode1(p):
    return [('delta', 'gamma', 'beta')[w] if p == 0 else 3 * p - 2 + w for w in range(3)]


def blocks_mode0(p):
    w4 = 'gamma' if p == 0 else 2 * p - 1
    w8 = 'beta' if p == 0 else ('delta' if p == 1 else 2 * p - 2)
    return [w4, w8]


def exists(b, exp):
    return b in ('delta', 'gamma', 'beta') or (exp and isinstance(b, int) and 1 <= b <= 16)


ops = []                                    # (kind, value or address, ...)  built into code
code = bytearray()


def paging(iob):
    code.extend([0x3E, iob, 0xD3, 0x00])    # LD A,iob ; OUT (0),A


def write(addr, v):
    code.extend([0x3E, v, 0x32, addr & 255, addr >> 8])         # LD A,v ; LD (addr),A


def read(addr):
    code.extend([0x3A, addr & 255, addr >> 8, 0xD3, 0xE0])      # LD A,(addr) ; OUT (E0),A


OFF = 0x123
# --- writes: RELCPMH=1, every page, the three windows
writes = []
for p in range(16):
    paging(0x80 | p)
    for w in range(3):
        v = 0x10 + 3 * p + w
        write(w * 0x4000 + OFF, v)
        writes.append((p, w, v))
# --- reads, RELCPMH=1
reads = []                                  # (mode, p, window)
for p in range(16):
    paging(0x80 | p)
    for w in range(3):
        read(w * 0x4000 + OFF); reads.append((1, p, w))
# --- reads, RELCPMH=0 (windows 4000-7FFF and 8000-BFFF; ROM slot 0 and RAM page p)
for p in range(16):
    paging(p)
    for w, base in ((0, 0x4000), (1, 0x8000)):
        read(base + OFF); reads.append((0, p, w))
# --- ROM 2 sub-pages: select ROM 2, write the sub-page to 0000, read 2000
paging(0x20)
for sp in range(6):
    code.extend([0x3E, sp, 0x32, 0x00, 0x00])                   # LD A,sp ; LD (0000),A
    read(0x2000)
paging(0x00)
code.extend([0x3E, 0xA5, 0xD3, 0xE0, 0x76])                     # LD A,A5 ; OUT (E0),A ; HALT
assert len(code) < 0x1800, len(code)

# the boot code: copy to C000 and go
CODE_AT = 0x0100
boot = bytes([0x31, 0x00, 0xF0,                                 # LD SP,F000
              0x21, CODE_AT & 255, CODE_AT >> 8,                # LD HL,CODE_AT
              0x11, 0x00, 0xC0,                                 # LD DE,C000
              0x01, len(code) & 255, len(code) >> 8,            # LD BC,len
              0xED, 0xB0,                                       # LDIR
              0xC3, 0x00, 0xC0])                                # JP C000
rom = bytearray(8192)
rom[:len(boot)] = boot
rom[CODE_AT:CODE_AT + len(code)] = code
# ROM 2: pages 12..14 hold C0, C1, C2 in every byte
img = bytes(rom) + bytes(8192) * 3 + b''.join(bytes([0xC0 + i]) * 8192 for i in range(N_ROM2))
open(os.path.join(HERE, 'xram_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('program %d bytes, %d writes, %d reads, image %d bytes' % (len(code), len(writes), len(reads), len(img)))


def expected(exp):
    store = {}
    for p, w, v in writes:
        b = blocks_mode1(p)[w]
        if exists(b, exp): store[b] = v
    out = []
    for mode, p, w in reads:
        b = blocks_mode1(p)[w] if mode == 1 else blocks_mode0(p)[w]
        out.append(store[b] if exists(b, exp) else 0xFF)
    for sp in range(6):
        pg = sp & 3
        out.append(0xC0 + pg if pg < N_ROM2 else 0xFF)
    out.append(0xA5)
    return out


exp0, exp1 = expected(False), expected(True)
n = len(exp0)
print('%d reports expected; the two RAM sizes differ in %d of them' % (n, sum(1 for a, b in zip(exp0, exp1) if a != b)))

tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_xram').replace('sdx_roms.hex', 'xram_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, b, 1)


rep('generic (SLOT5 : integer := 0);', 'generic (SLOT5 : integer := 0; RAM_EXP : integer := 0);')
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  function expv return std_logic is begin if RAM_EXP = 1 then return '1'; else return '0'; end if; end function;
  type exp_t is array (0 to %d) of integer;
  constant EXP0 : exp_t := (%s);
  constant EXP1 : exp_t := (%s);""" % (n - 1, ', '.join(str(x) for x in exp0), ', '.join(str(x) for x in exp1)))
# the expansion RAM is in the SDRAM: the wrapper, the controller and a model of the chip sit next to the machine
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  component mtx_xsdram
    port
      (
      clk, init : in std_logic;
      SDRAM_DQ : inout std_logic_vector(15 downto 0);
      SDRAM_A : out std_logic_vector(12 downto 0);
      SDRAM_DQML, SDRAM_DQMH : out std_logic;
      SDRAM_BA : out std_logic_vector(1 downto 0);
      SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK : out std_logic;
      addr : in std_logic_vector(17 downto 0); din : in std_logic_vector(7 downto 0);
      se, mreq, rd, wr : in std_logic;
      dout : out std_logic_vector(7 downto 0); wait_n : out std_logic
      );
  end component;
  component sdram_model
    port
      (
      clk, cke, cs_n, ras_n, cas_n, we_n : in std_logic;
      ba : in std_logic_vector(1 downto 0); a : in std_logic_vector(12 downto 0);
      dqml, dqmh : in std_logic;
      dq : inout std_logic_vector(15 downto 0)
      );
  end component;
  signal x_se, x_mreq_n, x_rd_n, x_wr_n, x_wait_n : std_logic;
  signal x_addr : std_logic_vector(17 downto 0);
  signal x_do, x_q : std_logic_vector(7 downto 0);
  signal sd_dq : std_logic_vector(15 downto 0);
  signal sd_a : std_logic_vector(12 downto 0);
  signal sd_ba : std_logic_vector(1 downto 0);
  signal sd_dqml, sd_dqmh, sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_cke, sd_clk : std_logic;
  signal init_cnt : integer := 0;
  signal sd_init : std_logic := '1';""")
rep("  fdc : sdx_fdc\n", """  process (CLOCK_50)
  begin
    if rising_edge(CLOCK_50) then
      if init_cnt < 15 then init_cnt <= init_cnt + 1; else sd_init <= '0'; end if;
    end if;
  end process;

  xs : mtx_xsdram
    port map (
      clk => CLOCK_50, init => sd_init,
      SDRAM_DQ => sd_dq, SDRAM_A => sd_a, SDRAM_DQML => sd_dqml, SDRAM_DQMH => sd_dqmh, SDRAM_BA => sd_ba,
      SDRAM_nCS => sd_ncs, SDRAM_nWE => sd_nwe, SDRAM_nRAS => sd_nras, SDRAM_nCAS => sd_ncas, SDRAM_CKE => sd_cke, SDRAM_CLK => sd_clk,
      addr => x_addr, din => x_do, se => x_se, mreq => not x_mreq_n, rd => not x_rd_n, wr => not x_wr_n, dout => x_q, wait_n => x_wait_n);

  chip : sdram_model
    port map (clk => sd_clk, cke => sd_cke, cs_n => sd_ncs, ras_n => sd_nras, cas_n => sd_ncas, we_n => sd_nwe,
              ba => sd_ba, a => sd_a, dqml => sd_dqml, dqmh => sd_dqmh, dq => sd_dq);

  fdc : sdx_fdc
""")
rep("fdc_di => fdc_di);", "fdc_di => fdc_di,\n      xram_se => x_se, xram_addr => x_addr, xram_do => x_do, xram_mreq_n => x_mreq_n, xram_rd_n => x_rd_n, xram_wr_n => x_wr_n,\n      xram_q => x_q, xram_wait_n => x_wait_n);")
rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '0', sdx_slot5 => slot5_s, ram_exp => expv, rom2_ok => \"%s\"," % format((1 << N_ROM2) - 1, '04b'))
a = tb.index("    pos := 0;\n    if SLOT5 = 0 then")
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
checks = '''    chk(nrep = %d, "number of reports: " & integer'image(nrep));
    for k in 0 to %d loop
      if RAM_EXP = 1 then
        chk(to_integer(unsigned(rep(k))) = EXP1(k), "report " & integer'image(k) & ": got " & integer'image(to_integer(unsigned(rep(k)))) & ", want " & integer'image(EXP1(k)));
      else
        chk(to_integer(unsigned(rep(k))) = EXP0(k), "report " & integer'image(k) & ": got " & integer'image(to_integer(unsigned(rep(k)))) & ", want " & integer'image(EXP0(k)));
      end if;
    end loop;
''' % (n, n - 1)
tb = tb[:a] + checks + tb[z:]
tb = tb.replace('SDX MACHINE TEST PASSED', 'MEMORY MAP TEST PASSED').replace('SDX MACHINE TEST FAILED', 'MEMORY MAP TEST FAILED')
open(os.path.join(HERE, 'tb_mtx_xram.vhd'), 'w').write(tb)
print('tb_mtx_xram.vhd written')
