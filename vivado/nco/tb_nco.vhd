-- tb_nco.vhd
-- Testbench for nco_wrapper entity.
-- Tests the two separate AXI4-Stream outputs M_AXIS_COS and M_AXIS_SIN.
--
-- nco_wrapper ports under test:
--   aclk                 : in  std_logic
--   aresetn              : in  std_logic
--   s_axis_config_tvalid : in  std_logic  (tied '0' = fixed frequency)
--   m_axis_cos_tdata     : out std_logic_vector(15 downto 0)
--   m_axis_cos_tvalid    : out std_logic
--   m_axis_cos_tready    : in  std_logic  (tied '1' = always accept)
--   m_axis_sin_tdata     : out std_logic_vector(15 downto 0)
--   m_axis_sin_tvalid    : out std_logic
--   m_axis_sin_tready    : in  std_logic  (tied '1' = always accept)
--
-- Golden vectors (from run_and_extract.m):
--   input_nco_cos_stimulus.txt : signed 16-bit integers, one per line
--   input_nco_sin_stimulus.txt : signed 16-bit integers, one per line
--
-- Marco Aiello, 2024

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_nco is
end entity tb_nco;

architecture sim of tb_nco is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 10 ns;   -- 100 MHz
    constant TOLERANCE    : integer := 4;        -- LSBs
    constant N_SAMPLES    : integer := 10000;    -- samples to compare
    constant SKIP_SAMPLES : integer := 8;        -- DDS pipeline latency

    constant COS_GOLD_FILE : string := "input_nco_cos_stimulus.txt";
    constant SIN_GOLD_FILE : string := "input_nco_sin_stimulus.txt";
    constant COS_DUT_FILE  : string := "nco_cos_dut_output.txt";
    constant SIN_DUT_FILE  : string := "nco_sin_dut_output.txt";

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal aclk                 : std_logic := '0';
    signal aresetn              : std_logic := '0';

    signal m_axis_cos_tdata     : std_logic_vector(15 downto 0);
    signal m_axis_cos_tvalid    : std_logic;

    signal m_axis_sin_tdata     : std_logic_vector(15 downto 0);
    signal m_axis_sin_tvalid    : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Clock
    ---------------------------------------------------------------------------
    aclk <= not aclk after CLK_PERIOD / 2;

    ---------------------------------------------------------------------------
    -- Reset
    ---------------------------------------------------------------------------
    rst_proc : process
    begin
        aresetn <= '0';
        wait for 16 * CLK_PERIOD;
        aresetn <= '1';
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- DUT: nco_wrapper
    ---------------------------------------------------------------------------
    dut : entity work.nco_wrapper
        port map (
            aclk                 => aclk,
            aresetn              => aresetn,
            m_axis_cos_tdata     => m_axis_cos_tdata,
            m_axis_cos_tvalid    => m_axis_cos_tvalid,
            m_axis_sin_tdata     => m_axis_sin_tdata,
            m_axis_sin_tvalid    => m_axis_sin_tvalid
        );

    ---------------------------------------------------------------------------
    -- Cosine checker process
    ---------------------------------------------------------------------------
    cos_check_proc : process
        file     f_gold : text;
        file     f_dut  : text;
        variable ln     : line;
        variable gold   : integer;
        variable dut    : integer;
        variable err    : integer;
        variable n_err  : integer := 0;
        variable n_chk  : integer := 0;
        variable max_e  : integer := 0;
    begin
        file_open(f_gold, COS_GOLD_FILE, read_mode);
        file_open(f_dut,  COS_DUT_FILE,  write_mode);

        wait until aresetn = '1';
        wait until rising_edge(aclk);

        -- Skip pipeline latency
        for s in 1 to SKIP_SAMPLES loop
            wait until m_axis_cos_tvalid = '1' and rising_edge(aclk);
            wait until m_axis_cos_tvalid = '0' and rising_edge(aclk);
        end loop;

        for i in 0 to N_SAMPLES - 1 loop
            wait until m_axis_cos_tvalid = '1' and rising_edge(aclk);

            dut  := to_integer(signed(m_axis_cos_tdata));
            readline(f_gold, ln); read(ln, gold);

            write(ln, dut); writeline(f_dut, ln);

            err := abs(dut - gold);
            if err > max_e then max_e := err; end if;

            if err > TOLERANCE then
                report "COS MISMATCH sample " & integer'image(i) &
                       ": DUT=" & integer'image(dut) &
                       " GOLD=" & integer'image(gold) &
                       " ERR=" & integer'image(err) & " LSB"
                severity warning;
                n_err := n_err + 1;
            end if;
            n_chk := n_chk + 1;

            wait until m_axis_cos_tvalid = '0' and rising_edge(aclk);
        end loop;

        file_close(f_gold);
        file_close(f_dut);

        report "========================================" severity note;
        report "COSINE results" severity note;
        report "  Samples  : " & integer'image(n_chk) severity note;
        report "  Max err  : " & integer'image(max_e) & " LSB" severity note;
        report "  Errors   : " & integer'image(n_err) severity note;
        if n_err = 0 then
            report "  COS: PASS" severity note;
        else
            report "  COS: FAIL" severity failure;
        end if;
        report "========================================" severity note;
        wait;
    end process cos_check_proc;

    ---------------------------------------------------------------------------
    -- Sine checker process
    ---------------------------------------------------------------------------
    sin_check_proc : process
        file     f_gold : text;
        file     f_dut  : text;
        variable ln     : line;
        variable gold   : integer;
        variable dut    : integer;
        variable err    : integer;
        variable n_err  : integer := 0;
        variable n_chk  : integer := 0;
        variable max_e  : integer := 0;
    begin
        file_open(f_gold, SIN_GOLD_FILE, read_mode);
        file_open(f_dut,  SIN_DUT_FILE,  write_mode);

        wait until aresetn = '1';
        wait until rising_edge(aclk);

        for s in 1 to SKIP_SAMPLES loop
            wait until m_axis_sin_tvalid = '1' and rising_edge(aclk);
            wait until m_axis_sin_tvalid = '0' and rising_edge(aclk);
        end loop;

        for i in 0 to N_SAMPLES - 1 loop
            wait until m_axis_sin_tvalid = '1' and rising_edge(aclk);

            dut  := to_integer(signed(m_axis_sin_tdata));
            readline(f_gold, ln); read(ln, gold);

            write(ln, dut); writeline(f_dut, ln);

            err := abs(dut - gold);
            if err > max_e then max_e := err; end if;

            if err > TOLERANCE then
                report "SIN MISMATCH sample " & integer'image(i) &
                       ": DUT=" & integer'image(dut) &
                       " GOLD=" & integer'image(gold) &
                       " ERR=" & integer'image(err) & " LSB"
                severity warning;
                n_err := n_err + 1;
            end if;
            n_chk := n_chk + 1;

            wait until m_axis_sin_tvalid = '0' and rising_edge(aclk);
        end loop;

        file_close(f_gold);
        file_close(f_dut);

        report "========================================" severity note;
        report "SINE results" severity note;
        report "  Samples  : " & integer'image(n_chk) severity note;
        report "  Max err  : " & integer'image(max_e) & " LSB" severity note;
        report "  Errors   : " & integer'image(n_err) severity note;
        if n_err = 0 then
            report "  SIN: PASS" severity note;
        else
            report "  SIN: FAIL" severity failure;
        end if;
        report "========================================" severity note;

        std.env.stop;
        wait;
    end process sin_check_proc;

end architecture sim;
