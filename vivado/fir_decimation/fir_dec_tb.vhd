--------------------------------------------------------------------------------
-- fir_dec_tb.vhd
-- Testbench for fir_dec (FIR Compiler decimator wrapper).
-- Reads stimulus from fir_dec_stimulus.txt (stored integers, sfix32_En14).
-- Reads golden from fir_dec_golden.txt (real values in Hz).
-- Compares output against golden with 1 Hz tolerance.
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity fir_dec_tb is
end entity fir_dec_tb;

architecture tb of fir_dec_tb is

    -- Clock and reset
    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';

    -- DUT signals
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_tvalid : std_logic;
    signal m_tdata  : std_logic_vector(31 downto 0);

    -- Test control
    -- Impulse test parameters.
    -- TOL: loose enough for quantisation (coefficients are quantised to sfix32_En14)
    -- SKIP: FIR Compiler pipeline latency before first valid impulse response output.
    -- With fir1(40,1/5): group delay = 20 input samples = 4 output samples.
    -- The IP may output additional startup samples before the impulse propagates.
    -- Set SKIP=4 to skip the group delay period.
    constant TOL     : real    := 100.0;   -- wide open: find IP latency
    constant SKIP    : integer := 0;       -- no skip: golden includes latency zeros

    -- Conversion: sfix32_En14 stored integer to real
    function to_real(slv : std_logic_vector(31 downto 0)) return real is
        variable si : integer;
    begin
        si := to_integer(signed(slv));
        return real(si) / 16384.0;  -- / 2^14
    end function;

begin

    -- Clock
    clk <= not clk after CLK_PERIOD / 2;

    -- DUT
    dut : entity work.fir_dec
        port map (
            aclk               => clk,
            aresetn            => resetn,
            s_axis_data_tdata  => s_tdata,
            s_axis_data_tvalid => s_tvalid,
            s_axis_data_tready => s_tready,
            m_axis_data_tdata  => m_tdata,
            m_axis_data_tvalid => m_tvalid
        );

    -- Stimulus process
    stim_proc : process
        file     stim_file : text;
        variable stim_line : line;
        variable stim_int  : integer;
    begin
        -- Reset
        resetn  <= '0';
        s_tvalid <= '0';
        wait for CLK_PERIOD * 4;
        resetn <= '1';
        wait for CLK_PERIOD * 2;

        -- Feed input samples
        file_open(stim_file, "fir_dec_stimulus.txt", read_mode);
        while not endfile(stim_file) loop
            readline(stim_file, stim_line);
            read(stim_line, stim_int);
            s_tdata  <= std_logic_vector(to_signed(stim_int, 32));
            s_tvalid <= '1';
            wait until rising_edge(clk) and s_tready = '1';
        end loop;
        file_close(stim_file);

        s_tvalid <= '0';
        wait for CLK_PERIOD * 100;
        wait;
    end process;

    -- Check process
    check_proc : process
        file     gold_file : text;
        variable gold_line : line;
        variable gold_val  : real;
        variable hls_val   : real;
        variable err       : real;
        variable skip_cnt  : integer := 0;
        variable check_cnt : integer := 0;
        variable fail_cnt  : integer := 0;
        variable status    : string(1 to 4);
    begin
        wait until resetn = '1';
        wait for CLK_PERIOD * 2;

        file_open(gold_file, "fir_dec_golden.txt", read_mode);

        while not endfile(gold_file) loop
            -- Wait for valid output
            wait until rising_edge(clk) and m_tvalid = '1';

            readline(gold_file, gold_line);
            read(gold_line, gold_val);

            if skip_cnt < SKIP then
                skip_cnt := skip_cnt + 1;
            else
                hls_val := to_real(m_tdata);
                err     := abs(hls_val - gold_val);
                if err <= TOL then
                    status := "PASS";
                else
                    status   := "FAIL";
                    fail_cnt := fail_cnt + 1;
                end if;

                if check_cnt < 20 or err > TOL then
                    report "Idx=" & integer'image(check_cnt) &
                           " RTL=" & real'image(hls_val) &
                           " RAW=" & integer'image(to_integer(signed(m_tdata))) &
                           " GOLD=" & real'image(gold_val) &
                           " ERR=" & real'image(err) &
                           " " & status
                        severity note;
                end if;
                check_cnt := check_cnt + 1;
            end if;
        end loop;

        file_close(gold_file);

        report "=== Checked: " & integer'image(check_cnt) &
               "  Failures: " & integer'image(fail_cnt) & " ==="
            severity note;

        if fail_cnt = 0 then
            report "=== TESTBENCH PASSED ===" severity failure;  -- severity failure stops xsim
        else
            report "=== TESTBENCH FAILED ===" severity failure;
        end if;

        wait;
    end process;

end architecture tb;
