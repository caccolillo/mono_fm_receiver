-- nco_wrapper.vhd
-- AXI4-Stream wrapper around Xilinx DDS Compiler v6.0.
-- Fixed frequency: 10 kHz at 250 kHz sample rate (PINC set at synthesis).
-- Splits the packed tdata[31:0] output into two separate AXI4-Stream ports.
--
-- DDS Compiler tdata packing (PG141):
--   tdata[15:0]  = cosine   fixdt(1,16,15)
--   tdata[31:16] = sine     fixdt(1,16,15)
--
-- Interface:
--   aclk           : 100 MHz system clock
--   aresetn        : active-low synchronous reset
--   M_AXIS_COS     : cosine output, 16-bit signed, 250 kHz rate
--   M_AXIS_SIN     : sine   output, 16-bit signed, 250 kHz rate
--
-- Both outputs share the same tvalid — one pulse every 400 clock cycles.
-- tready is AND-ed: DDS holds until both consumers have accepted.
-- For downstream blocks that always accept (tready='1'), this adds no
-- latency and no logic beyond the register.
--
-- Marco Aiello, 2024

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nco_wrapper is
    generic (
        OUTPUT_WIDTH : integer := 16    -- fixdt(1,16,15)
    );
    port (
        aclk             : in  std_logic;
        aresetn          : in  std_logic;

        -- M_AXIS_COS
        m_axis_cos_tdata  : out std_logic_vector(OUTPUT_WIDTH-1 downto 0);
        m_axis_cos_tvalid : out std_logic;

        -- M_AXIS_SIN
        m_axis_sin_tdata  : out std_logic_vector(OUTPUT_WIDTH-1 downto 0);
        m_axis_sin_tvalid : out std_logic
    );
end entity nco_wrapper;

architecture rtl of nco_wrapper is

    -- DDS runs freely — one valid output every SAMPLE_RATE clock cycles.
    -- No tready port on DDS (Has_TREADY=false in IP config).
    -- Downstream blocks (FreqCorr multipliers) must always be ready to accept.
    -- Since multipliers are purely combinatorial/registered with no stall,
    -- this is always the case.
    signal dds_tvalid : std_logic;
    signal dds_tdata  : std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);

begin

    dds_inst : entity work.dds_compiler_0
        port map (
            aclk               => aclk,
            aresetn            => aresetn,
            m_axis_data_tvalid => dds_tvalid,
            m_axis_data_tdata  => dds_tdata
        );

    -- Unpack tdata directly to output ports.
    -- DDS packing (PG141): tdata[15:0]=cosine, tdata[31:16]=sine
    -- tvalid is asserted for one clock cycle every 400 cycles (250 kHz).
    -- Both outputs present the same sample simultaneously.
    m_axis_cos_tdata  <= dds_tdata(OUTPUT_WIDTH-1 downto 0);
    m_axis_sin_tdata  <= dds_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH);
    m_axis_cos_tvalid <= dds_tvalid;
    m_axis_sin_tvalid <= dds_tvalid;

end architecture rtl;
