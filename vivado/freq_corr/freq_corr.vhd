-- freq_corr.vhd
-- Frequency correction: Ic = I*cos - Q*sin,  Qc = I*sin + Q*cos
--
-- Uses ieee.numeric_std signed arithmetic only (no ieee.fixed_pkg).
-- Four SEPARATE AXI-Stream slave interfaces (one scalar per stream) and
-- two separate AXI-Stream master interfaces, matching the Simulink
-- FreqCorr block's four independent inputs / two independent outputs.
--
-- Fixed-point formats:
--   Inputs  : sfix16_En15  signed(15:0)  scale 2^-15
--   Outputs : sfix18_En17  signed(17:0)  scale 2^-17
--   Products: signed(31:0) scale 2^-30  (16b * 16b)
--   Sums    : signed(32:0) scale 2^-30
--   Resize  : sum >> 13 -> sfix18_En17, saturate
--
-- Pipeline: 2 clock cycles
--   Cycle 1: latch inputs (requires all four input streams valid together)
--   Cycle 2: multiply, add, resize
--
-- Marco Aiello, 2024

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity freq_corr is
    port (
        aclk     : in  std_logic;
        aresetn  : in  std_logic;

        -- Four separate AXI-S slave interfaces (sfix16_En15 each)
        s_axis_i_tdata     : in  std_logic_vector(15 downto 0);
        s_axis_i_tvalid    : in  std_logic;
        s_axis_i_tready    : out std_logic;

        s_axis_q_tdata     : in  std_logic_vector(15 downto 0);
        s_axis_q_tvalid    : in  std_logic;
        s_axis_q_tready    : out std_logic;

        s_axis_cos_tdata   : in  std_logic_vector(15 downto 0);
        s_axis_cos_tvalid  : in  std_logic;
        s_axis_cos_tready  : out std_logic;

        s_axis_sin_tdata   : in  std_logic_vector(15 downto 0);
        s_axis_sin_tvalid  : in  std_logic;
        s_axis_sin_tready  : out std_logic;

        -- Two separate AXI-S master interfaces (sfix18_En17 each)
        m_axis_ic_tdata    : out std_logic_vector(17 downto 0);
        m_axis_ic_tvalid   : out std_logic;
        m_axis_ic_tready   : in  std_logic;

        m_axis_qc_tdata    : out std_logic_vector(17 downto 0);
        m_axis_qc_tvalid   : out std_logic;
        m_axis_qc_tready   : in  std_logic
    );
end entity freq_corr;

architecture rtl of freq_corr is

    -- All four input streams must be valid together to advance the pipeline
    signal in_valid : std_logic;

    -- Stage 1 registers: raw 16-bit signed inputs
    signal i_reg  : signed(15 downto 0) := (others => '0');
    signal q_reg  : signed(15 downto 0) := (others => '0');
    signal c_reg  : signed(15 downto 0) := (others => '0');
    signal s_reg  : signed(15 downto 0) := (others => '0');
    signal v1_reg : std_logic := '0';

    -- Stage 2 output registers
    signal ic_reg : signed(17 downto 0) := (others => '0');
    signal qc_reg : signed(17 downto 0) := (others => '0');
    signal v2_reg : std_logic := '0';

    constant MAX18 : integer := 131071;   -- 2^17 - 1
    constant MIN18 : integer := -131072;  -- -2^17

    function saturate18(x : signed(32 downto 0)) return signed is
        variable result : signed(17 downto 0);
    begin
        if x > to_signed(MAX18, 33) then
            result := to_signed(MAX18, 18);
        elsif x < to_signed(MIN18, 33) then
            result := to_signed(MIN18, 18);
        else
            result := x(17 downto 0);
        end if;
        return result;
    end function;

begin

    -- All four input streams accepted together (no independent backpressure
    -- per stream -- they must be synchronised by the upstream producer,
    -- matching Simulink's frame-synchronous port semantics).
    in_valid <= s_axis_i_tvalid and s_axis_q_tvalid and
                s_axis_cos_tvalid and s_axis_sin_tvalid;

    s_axis_i_tready   <= in_valid;
    s_axis_q_tready   <= in_valid;
    s_axis_cos_tready <= in_valid;
    s_axis_sin_tready <= in_valid;

    process(aclk)
        variable ixc    : signed(31 downto 0);
        variable qxs    : signed(31 downto 0);
        variable ixs    : signed(31 downto 0);
        variable qxc    : signed(31 downto 0);
        variable ic_sum : signed(32 downto 0);
        variable qc_sum : signed(32 downto 0);
        variable ic_shr : signed(32 downto 0);
        variable qc_shr : signed(32 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                i_reg  <= (others => '0');
                q_reg  <= (others => '0');
                c_reg  <= (others => '0');
                s_reg  <= (others => '0');
                v1_reg <= '0';
                ic_reg <= (others => '0');
                qc_reg <= (others => '0');
                v2_reg <= '0';
            else
                -- ── Stage 2: multiply-accumulate from latched inputs ──────
                if v1_reg = '1' then
                    ixc := i_reg * c_reg;
                    qxs := q_reg * s_reg;
                    ixs := i_reg * s_reg;
                    qxc := q_reg * c_reg;

                    -- Round each product to sfix18_En17 before summing
                    -- (matches Simulink FreqCorr fixdt(1,18,17) products).
                    ic_sum := resize(shift_right(resize(ixc,33) + 4096, 13), 33) -
                              resize(shift_right(resize(qxs,33) + 4096, 13), 33);
                    qc_sum := resize(shift_right(resize(ixs,33) + 4096, 13), 33) +
                              resize(shift_right(resize(qxc,33) + 4096, 13), 33);

                    ic_shr := ic_sum;
                    qc_shr := qc_sum;

                    ic_reg <= saturate18(ic_shr);
                    qc_reg <= saturate18(qc_shr);
                end if;
                v2_reg <= v1_reg;

                -- ── Stage 1: latch inputs ─────────────────────────────────
                if in_valid = '1' then
                    i_reg <= signed(s_axis_i_tdata);
                    q_reg <= signed(s_axis_q_tdata);
                    c_reg <= signed(s_axis_cos_tdata);
                    s_reg <= signed(s_axis_sin_tdata);
                end if;
                v1_reg <= in_valid;
            end if;
        end if;
    end process;

    m_axis_ic_tdata  <= std_logic_vector(ic_reg);
    m_axis_qc_tdata  <= std_logic_vector(qc_reg);
    m_axis_ic_tvalid <= v2_reg;
    m_axis_qc_tvalid <= v2_reg;

end architecture rtl;
