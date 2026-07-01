--------------------------------------------------------------------------------
-- audio_lpf_tb.vhd
-- Impulse response testbench for Audio LPF.
-- Reads stimulus from audio_lpf_stimulus.txt (stored integers, sfix32_En14).
-- Reads golden from audio_lpf_golden.txt (real values).
-- Compares output against golden with configurable tolerance.
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity audio_lpf_tb is
end entity audio_lpf_tb;

architecture tb of audio_lpf_tb is

    constant CLK_PERIOD : time    := 10 ns;   -- 100 MHz
    constant TOL        : real    := 100.0;    -- wide open initially; tighten after latency found
    constant SKIP       : integer := 0;        -- set after measuring IP latency

    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_tvalid : std_logic;
    signal m_tdata  : std_logic_vector(31 downto 0);

    function to_real(slv : std_logic_vector(31 downto 0)) return real is
    begin
        return real(to_integer(signed(slv))) / 16384.0;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.audio_lpf
        port map (
            aclk               => clk,
            aresetn            => resetn,
            s_axis_data_tdata  => s_tdata,
            s_axis_data_tvalid => s_tvalid,
            s_axis_data_tready => s_tready,
            m_axis_data_tdata  => m_tdata,
            m_axis_data_tvalid => m_tvalid
        );

    -- Stimulus
    stim_proc : process
        file     f    : text;
        variable ln   : line;
        variable si   : integer;
    begin
        resetn   <= '0';
        s_tvalid <= '0';
        wait for CLK_PERIOD * 4;
        resetn <= '1';
        wait for CLK_PERIOD * 2;

        file_open(f, "audio_lpf_stimulus.txt", read_mode);
        while not endfile(f) loop
            readline(f, ln);
            read(ln, si);
            s_tdata  <= std_logic_vector(to_signed(si, 32));
            s_tvalid <= '1';
            wait until rising_edge(clk) and s_tready = '1';
        end loop;
        file_close(f);
        s_tvalid <= '0';
        wait for CLK_PERIOD * 200;
        wait;
    end process;

    -- Check
    check_proc : process
        file     f        : text;
        variable ln       : line;
        variable gold_val : real;
        variable hls_val  : real;
        variable err      : real;
        variable skip_cnt : integer := 0;
        variable chk_cnt  : integer := 0;
        variable fail_cnt : integer := 0;
        variable status   : string(1 to 4);
    begin
        wait until resetn = '1';
        wait for CLK_PERIOD * 2;

        file_open(f, "audio_lpf_golden.txt", read_mode);
        while not endfile(f) loop
            wait until rising_edge(clk) and m_tvalid = '1';
            readline(f, ln);
            read(ln, gold_val);

            if skip_cnt < SKIP then
                skip_cnt := skip_cnt + 1;
            else
                hls_val := to_real(m_tdata);
                err     := abs(hls_val - gold_val);
                if err <= TOL then status := "PASS"; else status := "FAIL"; fail_cnt := fail_cnt + 1; end if;

                if chk_cnt < 30 or err > TOL then
                    report "Idx=" & integer'image(chk_cnt) &
                           " RTL=" & real'image(hls_val) &
                           " RAW=" & integer'image(to_integer(signed(m_tdata))) &
                           " GOLD=" & real'image(gold_val) &
                           " ERR=" & real'image(err) &
                           " " & status severity note;
                end if;
                chk_cnt := chk_cnt + 1;
            end if;
        end loop;
        file_close(f);

        report "=== Checked: " & integer'image(chk_cnt) &
               "  Failures: " & integer'image(fail_cnt) & " ===" severity note;
        if fail_cnt = 0 then
            report "=== TESTBENCH PASSED ===" severity failure;
        else
            report "=== TESTBENCH FAILED ===" severity failure;
        end if;
        wait;
    end process;

end architecture tb;
