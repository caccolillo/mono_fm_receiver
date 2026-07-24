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
-- BACKPRESSURE FIX (Ultra96-V2 bring-up): m_axis_ic_tready / m_axis_qc_tready
-- were declared as entity ports but NEVER referenced anywhere in the
-- architecture body -- confirmed by direct grep, both hits are the port
-- declarations themselves. The pipeline advanced and overwrote ic_reg/
-- qc_reg on every clock cycle it had valid stage-1 data, with zero regard
-- for whether the downstream consumer (aa_lpf) was ready. Empirically
-- confirmed on real RTL simulation with a dedicated protocol probe: for
-- 5000 input samples, freq_corr_0 presented 5000 different m_axis_ic
-- beats, of which aa_lpf's tready only accepted 21 -- the other 4979 were
-- silently overwritten before aa_lpf ever got a chance to see them,
-- changing tdata on every single cycle regardless of tready, including
-- while tready was held low across consecutive cycles (a direct AXI-
-- Stream protocol violation -- a master must hold tdata/tvalid steady
-- across any cycle where tready is low).
--
-- This was found only AFTER fixing a separate, unrelated bug in aa_lpf
-- (ap_ctrl_none -> ap_ctrl_hs, see aa_lpf.cpp) that turned out to be
-- necessary but not sufficient -- aa_lpf's own tready now correctly
-- reflects its ~129-cycle-per-sample busy state, but that fix alone
-- changed nothing end-to-end, because the real loss was happening one
-- stage further upstream, in this file, the whole time.
--
-- Fix: added an out_ready signal (downstream ready to accept, OR the
-- stage-2 output register currently holds no valid unconsumed data) that
-- gates BOTH pipeline stages together -- when out_ready='0', stage 1's
-- latched inputs, stage 2's ic_reg/qc_reg/v2_reg, and the input-side
-- tready all freeze in place exactly as they were, rather than being
-- silently overwritten. This is a "stall the whole 2-stage pipeline
-- together" fix, not a skid-buffer/extra-depth fix -- simpler and lower
-- risk than adding real elastic buffering, at the cost of not absorbing
-- one extra input sample while genuinely stalled. Given the system as a
-- whole runs with generous throughput margin (confirmed via the same RTL
-- testbench), correctness was prioritised over that small amount of
-- extra headroom.
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

    -- BACKPRESSURE FIX: true when the stage-2 output register is safe to
    -- overwrite this cycle -- either downstream actually accepts what's
    -- there right now (both tready high), or there's nothing valid held
    -- there to lose in the first place (v2_reg = '0'). Gates both
    -- pipeline stages AND the input-side tready together; see the fix
    -- writeup at the top of this file.
    signal out_ready : std_logic;

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

    -- BACKPRESSURE FIX: stage-2 register may only be overwritten when it's
    -- either empty (v2_reg='0', nothing valid held there) or downstream is
    -- genuinely consuming what's there THIS cycle (both tready high). Both
    -- output streams share one valid (v2_reg) and must be paired -- if
    -- either consumer isn't ready, the whole pipeline must stall, or Ic/Qc
    -- would desync from each other.
    out_ready <= (m_axis_ic_tready and m_axis_qc_tready) or (not v2_reg);

    -- All four input streams accepted together (no independent backpressure
    -- per stream -- they must be synchronised by the upstream producer,
    -- matching Simulink's frame-synchronous port semantics). ALSO now
    -- gated on out_ready: if the pipeline can't advance downstream this
    -- cycle, it must not accept new input either, or stage 1's currently-
    -- held data would be overwritten before stage 2 ever consumes it.
    in_valid <= s_axis_i_tvalid and s_axis_q_tvalid and
                s_axis_cos_tvalid and s_axis_sin_tvalid and
                out_ready;

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
                -- BACKPRESSURE FIX: wrapped in "if out_ready" -- when the
                -- downstream consumer isn't ready AND we're already
                -- holding valid unconsumed output (out_ready='0'), this
                -- entire branch is skipped, so ic_reg/qc_reg/v2_reg all
                -- implicitly HOLD their current values (no assignment =
                -- hold, standard VHDL synchronous-process semantics)
                -- instead of being silently overwritten.
                if out_ready = '1' then
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

                    -- ── Stage 1: latch inputs ─────────────────────────────
                    -- Also gated on out_ready, for the same reason -- if
                    -- stage 2 can't advance this cycle, stage 1 must HOLD
                    -- its currently-latched data (not accept/overwrite with
                    -- new input) so it's still correct once out_ready
                    -- returns to '1'. in_valid already factors out_ready
                    -- into its own definition above, so this inner check is
                    -- effectively redundant with the outer one -- kept for
                    -- readability/defence-in-depth rather than relying
                    -- purely on that composed signal.
                    if in_valid = '1' then
                        i_reg <= signed(s_axis_i_tdata);
                        q_reg <= signed(s_axis_q_tdata);
                        c_reg <= signed(s_axis_cos_tdata);
                        s_reg <= signed(s_axis_sin_tdata);
                    end if;
                    v1_reg <= in_valid;
                end if;
                -- else (out_ready='0'): i_reg, q_reg, c_reg, s_reg, v1_reg,
                -- ic_reg, qc_reg, v2_reg all implicitly hold -- the entire
                -- pipeline freezes together until downstream is ready.
            end if;
        end if;
    end process;

    m_axis_ic_tdata  <= std_logic_vector(ic_reg);
    m_axis_qc_tdata  <= std_logic_vector(qc_reg);
    m_axis_ic_tvalid <= v2_reg;
    m_axis_qc_tvalid <= v2_reg;

end architecture rtl;
