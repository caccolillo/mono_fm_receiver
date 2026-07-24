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
-- BACKPRESSURE FIX (Ultra96-V2 bring-up): this file previously had NO
-- tready ports at all -- despite this same header already describing the
-- intended design ("tready is AND-ed: DDS holds until both consumers have
-- accepted") one line below, that was never actually implemented; the DDS
-- Compiler was configured with Has_TREADY=false (see create_nco_sim.tcl)
-- and this wrapper correspondingly had no tready to wire up. That was a
-- silent, valid assumption only as long as freq_corr_0 (the sole
-- consumer) also ignored backpressure -- which it did, until its own
-- separate bug was found and fixed (see freq_corr.vhd). Once freq_corr_0
-- started correctly stalling under real backpressure, this NCO kept
-- advancing its phase regardless, causing cos/sin to drift out of
-- correspondence with the I/Q sample they're meant to pair with --
-- confirmed on real hardware as a strong spurious tone even after both
-- other bugs in this chain were independently fixed and verified
-- lossless. Now genuinely implements what the comment always said:
-- Has_TREADY enabled on the DDS Compiler itself (create_nco_sim.tcl), and
-- m_axis_cos_tready/m_axis_sin_tready exposed here and AND-ed together
-- before reaching dds_inst, so the DDS core only advances its phase
-- accumulator when BOTH downstream consumers have genuinely accepted the
-- current sample.
--
-- Both outputs share the same tvalid — one pulse every 400 clock cycles
-- when not stalled. tready is AND-ed: DDS holds until both consumers have
-- accepted.
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
        m_axis_cos_tready : in  std_logic;

        -- M_AXIS_SIN
        m_axis_sin_tdata  : out std_logic_vector(OUTPUT_WIDTH-1 downto 0);
        m_axis_sin_tvalid : out std_logic;
        m_axis_sin_tready : in  std_logic
    );
end entity nco_wrapper;

architecture rtl of nco_wrapper is

    -- DDS now genuinely respects backpressure (Has_TREADY=true, see
    -- create_nco_sim.tcl) -- phase accumulator only advances when
    -- m_axis_data_tvalid AND m_axis_data_tready are both asserted.
    -- Both downstream consumers must accept together, same pairing
    -- requirement as before (Ic/Qc share freq_corr_0's single valid).
    signal dds_tvalid : std_logic;
    signal dds_tdata  : std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
    signal dds_tready : std_logic;

begin

    -- Both consumers must be ready before the DDS core is told to advance.
    dds_tready <= m_axis_cos_tready and m_axis_sin_tready;

    dds_inst : entity work.dds_compiler_0
        port map (
            aclk               => aclk,
            aresetn            => aresetn,
            m_axis_data_tvalid => dds_tvalid,
            m_axis_data_tready => dds_tready,
            m_axis_data_tdata  => dds_tdata
        );

    -- Unpack tdata directly to output ports.
    -- DDS packing (PG141): tdata[15:0]=cosine, tdata[31:16]=sine
    -- tvalid is asserted for one clock cycle every 400 cycles (250 kHz)
    -- when not stalled by backpressure.
    -- Both outputs present the same sample simultaneously.
    m_axis_cos_tdata  <= dds_tdata(OUTPUT_WIDTH-1 downto 0);
    m_axis_sin_tdata  <= dds_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH);
    m_axis_cos_tvalid <= dds_tvalid;
    m_axis_sin_tvalid <= dds_tvalid;

end architecture rtl;
