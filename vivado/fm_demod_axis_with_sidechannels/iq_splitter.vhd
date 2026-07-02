--------------------------------------------------------------------------------
-- iq_splitter.vhd
-- Splits a packed 32-bit AXI-Stream (I/Q interleaved from DMA/memory) into
-- two separate 16-bit AXI-Stream outputs for freq_corr_0.
--
-- Memory packing convention (must match the PS-side driver):
--   tdata[15:0]  = I sample (sfix16_En15)
--   tdata[31:16] = Q sample (sfix16_En15)
--
-- Both output streams fire simultaneously from the same input beat.
-- freq_corr_0 requires all inputs valid at the same clock edge, which is
-- guaranteed here since m_i_tvalid and m_q_tvalid are both driven from
-- s_tvalid -- no skew possible.
--
-- tready: the input is stalled until BOTH freq_corr_0 outputs are ready.
-- Since freq_corr_0's s_axis_i_tready and s_axis_q_tready track together
-- (they are gated by the same in_valid logic inside freq_corr), in practice
-- both will always be asserted simultaneously. The AND is a safety measure.
--
-- tlast is passed through from the DMA to both outputs (both see the same
-- frame boundary -- freq_corr ignores tlast but it costs nothing to pass).
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity iq_splitter is
    port (
        -- Input: 32-bit packed I/Q from AXI DMA
        s_tdata  : in  std_logic_vector(31 downto 0);  -- {Q[15:0], I[15:0]}
        s_tvalid : in  std_logic;
        s_tready : out std_logic;
        s_tlast  : in  std_logic;

        -- Output I channel: to freq_corr_0/s_axis_i (16-bit)
        m_i_tdata  : out std_logic_vector(15 downto 0);
        m_i_tvalid : out std_logic;
        m_i_tready : in  std_logic;
        m_i_tlast  : out std_logic;

        -- Output Q channel: to freq_corr_0/s_axis_q (16-bit)
        m_q_tdata  : out std_logic_vector(15 downto 0);
        m_q_tvalid : out std_logic;
        m_q_tready : in  std_logic;
        m_q_tlast  : out std_logic
    );
end entity iq_splitter;

architecture rtl of iq_splitter is
begin

    -- Unpack: I in low 16 bits, Q in high 16 bits
    m_i_tdata <= s_tdata(15 downto 0);
    m_q_tdata <= s_tdata(31 downto 16);

    -- Both outputs valid when input is valid
    m_i_tvalid <= s_tvalid;
    m_q_tvalid <= s_tvalid;

    -- Stall input until both downstream consumers are ready
    s_tready <= m_i_tready and m_q_tready;

    -- Pass tlast to both outputs
    m_i_tlast <= s_tlast;
    m_q_tlast <= s_tlast;

end architecture rtl;
