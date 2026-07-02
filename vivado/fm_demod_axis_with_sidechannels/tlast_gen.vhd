--------------------------------------------------------------------------------
-- tlast_gen.vhd
-- AXI-Stream tlast generator for a source with no tready/tlast.
--
-- de_emph_0 produces a free-running stream: tdata and tvalid only, no
-- tready (it cannot be back-pressured) and no tlast. This module inserts
-- a periodic tlast every FRAME_SIZE valid samples so the downstream AXI
-- DMA MM2S channel receives properly framed transfers.
--
-- Interface:
--   Input  : tdata + tvalid only (matches de_emph_0 output exactly)
--   Output : tdata + tvalid + tlast (connects to m_axis_data_0 / AXI DMA)
--   No tready on the input side (de_emph_0 cannot be back-pressured).
--   tready on the output side is accepted but ignored -- the upstream
--   source is free-running so there is nothing to stall. If the DMA is
--   not ready, samples will be lost; size FRAME_SIZE and the DMA buffer
--   appropriately to avoid this in practice.
--
-- Parameters:
--   FRAME_SIZE : samples per DMA frame (e.g. 4096 = 81.92 ms at 50 kHz).
--                Must match the byte count in the DMA driver call
--                (bytes = FRAME_SIZE * 4 for 32-bit samples).
--   DATA_WIDTH : tdata width (32 for sfix32_En13 de_emph output).
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tlast_gen is
    generic (
        FRAME_SIZE : positive := 4096;
        DATA_WIDTH : positive := 32
    );
    port (
        aclk     : in  std_logic;
        aresetn  : in  std_logic;

        -- Input: from de_emph_0 (tdata + tvalid only, no tready)
        s_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_tvalid : in  std_logic;

        -- Output: to AXI DMA (tdata + tvalid + tlast)
        m_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_tvalid : out std_logic;
        m_tlast  : out std_logic;
        m_tready : in  std_logic   -- accepted but not used to stall source
    );
end entity tlast_gen;

architecture rtl of tlast_gen is

    signal count : integer range 1 to FRAME_SIZE := 1;

begin

    -- Pass tdata and tvalid straight through
    m_tdata  <= s_tdata;
    m_tvalid <= s_tvalid;

    -- Assert tlast on the FRAME_SIZE-th valid sample
    m_tlast  <= '1' when (s_tvalid = '1' and count = FRAME_SIZE) else '0';

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                count <= 1;
            elsif s_tvalid = '1' then
                if count = FRAME_SIZE then
                    count <= 1;
                else
                    count <= count + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
