--------------------------------------------------------------------------------
-- de_emph.vhd
-- FM De-emphasis filter: 1st-order IIR, Direct Form I.
-- y[n] = b0*x[n] + a1*y[n-1]
--
-- Simulink block parameters:
--   Numerator:   0.234071661635351   (b0)
--   Denominator: [1 -0.765928338364649]  (a1 = +0.765928...)
--   Input:       sfix32_En14
--   Output:      sfix32_En13
--   Accumulators: fixdt(1,40,13) = sfix40_En13
--   Rounding:    Round (convergent)
--   Overflow:    Saturate
--   Sample rate: 50 kHz, tau = 75 us
--
-- Coefficients quantised to sfix32_En14:
--   b0 stored int = 3835,  a1 stored int = 12549
--
-- Marco Aiello, 2024
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity de_emph is
    port (
        aclk               : in  std_logic;
        aresetn            : in  std_logic;
        s_axis_data_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_data_tvalid : in  std_logic;
        s_axis_data_tready : out std_logic;
        m_axis_data_tdata  : out std_logic_vector(31 downto 0);
        m_axis_data_tvalid : out std_logic
    );
end entity de_emph;

architecture rtl of de_emph is

    -- Coefficient stored integers (sfix32_En14)
    constant B0 : signed(31 downto 0) := to_signed(3835,  32);
    constant A1 : signed(31 downto 0) := to_signed(12549, 32);

    -- State register: previous output in sfix32_En13
    signal y_prev      : signed(31 downto 0) := (others => '0');
    signal m_tdata_r   : signed(31 downto 0) := (others => '0');
    signal m_tvalid_r  : std_logic := '0';

    -- Saturate a 64-bit intermediate to 40 bits (sfix40_En13)
    -- Checks sign bit and overflow bits [63:39] for saturation.
    -- Uses sized signed constants (not hand-counted bit-string literals)
    -- to avoid width-mismatch errors: max/min of a 40-bit signed value.
    constant SAT40_MAX : signed(39 downto 0) := ('0', others => '1');
    constant SAT40_MIN : signed(39 downto 0) := ('1', others => '0');

    function sat40(v : signed(63 downto 0)) return signed is
        variable r : signed(39 downto 0);
    begin
        -- Positive overflow: sign=0 but upper bits non-zero
        if v(63) = '0' and v(63 downto 39) /= "0000000000000000000000000" then
            r := SAT40_MAX;  -- max positive
        -- Negative overflow: sign=1 but upper bits not all-ones
        elsif v(63) = '1' and v(63 downto 39) /= "1111111111111111111111111" then
            r := SAT40_MIN;  -- min negative
        else
            r := v(39 downto 0);
        end if;
        return r;
    end function;

    -- Saturate a 40-bit accumulator to 32 bits (sfix32_En13)
    function sat32(v : signed(39 downto 0)) return signed is
        variable r : signed(31 downto 0);
    begin
        if v(39) = '0' and v(39 downto 31) /= "000000000" then
            r := x"7FFFFFFF";   -- max positive
        elsif v(39) = '1' and v(39 downto 31) /= "111111111" then
            r := x"80000000";   -- min negative
        else
            r := v(31 downto 0);
        end if;
        return r;
    end function;

begin

    s_axis_data_tready <= '1';

    process(aclk)
        variable x_in     : signed(31 downto 0);
        variable num_prod : signed(63 downto 0);
        variable den_prod : signed(63 downto 0);
        variable num_acc  : signed(39 downto 0);
        variable den_acc  : signed(39 downto 0);
        variable acc      : signed(39 downto 0);
        variable sum64    : signed(63 downto 0);
        variable y_out    : signed(31 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                y_prev     <= (others => '0');
                m_tdata_r  <= (others => '0');
                m_tvalid_r <= '0';
            elsif s_axis_data_tvalid = '1' then

                x_in := signed(s_axis_data_tdata);

                -- Numerator: b0 * x[n]
                -- x is En14, b0 is En14 -> product is En28
                -- Target En13: shift right by 15, add 2^14 for rounding
                num_prod := x_in * B0;
                num_acc  := sat40(shift_right(num_prod + to_signed(16384, 64), 15));

                -- Denominator: a1 * y[n-1]
                -- y_prev is En13, a1 is En14 -> product is En27
                -- Target En13: shift right by 14, add 2^13 for rounding
                den_prod := y_prev * A1;
                den_acc  := sat40(shift_right(den_prod + to_signed(8192, 64), 14));

                -- Sum with saturation to sfix40_En13
                sum64 := resize(num_acc, 64) + resize(den_acc, 64);
                acc   := sat40(sum64);

                -- Truncate to sfix32_En13 with saturation
                y_out := sat32(acc);

                y_prev     <= y_out;
                m_tdata_r  <= y_out;
                m_tvalid_r <= '1';
            else
                m_tvalid_r <= '0';
            end if;
        end if;
    end process;

    m_axis_data_tdata  <= std_logic_vector(m_tdata_r);
    m_axis_data_tvalid <= m_tvalid_r;

end architecture rtl;
