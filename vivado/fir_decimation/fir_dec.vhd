--------------------------------------------------------------------------------
-- fir_dec.vhd
-- FIR Decimation Filter R=5, fir1(40,1/5)
-- Wraps Xilinx FIR Compiler v7.2 IP.
--
-- Input:  s_axis_data  (sfix32_En14, AXI-S, 250 kHz)
-- Output: m_axis_data  (sfix32_En14, AXI-S, 50 kHz)
--
-- The FIR Compiler is configured as:
--   Filter type:        Decimation
--   Decimation rate:    5
--   Coefficients:       fir_dec.coe (fir1(40,1/5), sfix32_En14)
--   Coefficient width:  32
--   Data width:         32
--   Output width:       32
--   Rounding mode:      Round (convergent)
--   Overflow:           Wrap
--   Clock frequency:    100 MHz
--   Sample frequency:   250 kHz (input rate)
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fir_dec is
    port (
        aclk              : in  std_logic;
        aresetn           : in  std_logic;
        -- Input AXI-S (250 kHz input samples, sfix32_En14)
        s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid : in  std_logic;
        s_axis_data_tready : out std_logic;
        -- Output AXI-S (50 kHz decimated samples, sfix32_En14)
        m_axis_data_tdata  : out std_logic_vector(31 downto 0);
        m_axis_data_tvalid : out std_logic
    );
end entity fir_dec;

architecture rtl of fir_dec is

    -- FIR Compiler v7.2 component declaration
    component fir_compiler_0
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

    -- FIR Compiler output: configured Output_Width=32, so tdata=32 bits.
    signal fir_out_tdata  : std_logic_vector(31 downto 0);
    signal fir_out_tvalid : std_logic;

begin

    -- FIR Compiler IP instance
    fir_compiler_0_inst : fir_compiler_0
        port map (
            aclk               => aclk,
            aresetn            => aresetn,
            s_axis_data_tvalid => s_axis_data_tvalid,
            s_axis_data_tready => s_axis_data_tready,
            s_axis_data_tdata  => s_axis_data_tdata,
            m_axis_data_tvalid => fir_out_tvalid,
            m_axis_data_tdata  => fir_out_tdata
        );

    -- Direct connection: Output_Width=32 so tdata is exactly 32 bits
    m_axis_data_tdata  <= fir_out_tdata;
    m_axis_data_tvalid <= fir_out_tvalid;

end architecture rtl;
