--------------------------------------------------------------------------------
-- audio_lpf.vhd
-- Audio LPF: 127-tap FIR, fs=50 kHz, no decimation.
-- Wraps Xilinx FIR Compiler v7.2 IP.
--
-- Matches Simulink Discrete FIR Filter block:
--   Taps:        127
--   Coefficients: sfix32_En14 (same word length as input)
--   Accumulator:  fixdt(1,40,14) -- FIR Compiler uses full internal precision
--   Output:       fixdt(1,32,14) = sfix32_En14
--   Rounding:     Floor (truncate)
--   Overflow:     Saturate
--   Sample rate:  50 kHz
--
-- Input/output: sfix32_En14, AXI-S
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_lpf is
    port (
        aclk               : in  std_logic;
        aresetn            : in  std_logic;
        -- Input AXI-S (50 kHz, sfix32_En14)
        s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid : in  std_logic;
        s_axis_data_tready : out std_logic;
        -- Output AXI-S (50 kHz, sfix32_En14)
        m_axis_data_tdata  : out std_logic_vector(31 downto 0);
        m_axis_data_tvalid : out std_logic
    );
end entity audio_lpf;

architecture rtl of audio_lpf is

    component fir_compiler_1
        port (
            aclk               : in  std_logic;
            aresetn            : in  std_logic;
            s_axis_data_tvalid : in  std_logic;
            s_axis_data_tready : out std_logic;
            s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
            m_axis_data_tvalid : out std_logic;
            m_axis_data_tdata  : out std_logic_vector(31 downto 0)
        );
    end component;

begin

    fir_compiler_1_inst : fir_compiler_1
        port map (
            aclk               => aclk,
            aresetn            => aresetn,
            s_axis_data_tvalid => s_axis_data_tvalid,
            s_axis_data_tready => s_axis_data_tready,
            s_axis_data_tdata  => s_axis_data_tdata,
            m_axis_data_tvalid => m_axis_data_tvalid,
            m_axis_data_tdata  => m_axis_data_tdata
        );

end architecture rtl;
