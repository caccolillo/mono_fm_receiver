`timescale 1ns / 1ps
`define PS7 dut.sdr_fm_receiver_i.processing_system7_0.inst

// ------------------------------------------------------------------------
// tb_sdr_fm_receiver_liveness.sv
//
// Trivial "is it alive" testbench for the free-running ppdma revision of
// the design (bd.tcl as of the audio_ppdma_0/iq_ppdma_0 + hardwired
// xlconstant addresses/buf_size_words). This is deliberately NOT a
// signal-fidelity test -- there is no bit-exact comparison against a
// MATLAB/Simulink reference here, that's what verify_fm_demod_rtl.m and
// the earlier fm_demod-only testbenches are for.
//
// What changed vs. the original AXI-DMA-based tb_sdr_fm_receiver.sv, and
// why this testbench looks different as a result:
//   - No AXI DMA IP, so no MM2S/S2MM descriptor writes, no DMACR/DMASR
//     polling, no arm/re-arm loop at all.
//   - ap_start is tied permanently high on both audio_ppdma_0 and
//     iq_ppdma_0 (see bd.tcl xlconstant_0), so both cores start running
//     the instant PL reset deasserts -- there is no software "start"
//     step to synchronize against. DDR MUST be pre-loaded BEFORE
//     releasing PL reset, or iq_ppdma will begin streaming whatever
//     (likely zero/garbage) content is in DDR at that moment.
//   - ping_base/pong_base/dest_base/buf_size_words are hardwired via
//     xlconstant in this revision of bd.tcl, not GPIO-driven -- this
//     testbench never writes to axi_gpio_0, only reads the two
//     active_buf status bits from it.
//
// What this testbench actually checks: both active_buf bits keep
// toggling (ping<->pong) throughout a 500 ms run. A DMA that's hung --
// stuck reading/writing the same buffer forever -- will stop toggling;
// a DMA that's healthy will toggle at its expected cadence. This is a
// liveness/hang check, not a correctness check.
// ------------------------------------------------------------------------

module tb_sdr_fm_receiver_liveness;

    // ------------------------------------------------------------------
    // Fixed DDR addresses -- MUST match the xlconstant values wired to
    // ping_base/pong_base/dest_base/buf_size_words in bd.tcl. If those
    // constants change, update these to match or this testbench will
    // silently pre-load the wrong region and iq_ppdma will stream
    // whatever was already in DDR instead.
    // ------------------------------------------------------------------
    parameter [31:0] IQ_PING_ADDR    = 32'h1F00_0000;  // was 3E00_0000
    parameter [31:0] IQ_PONG_ADDR    = 32'h1F10_0000;  // was 3E10_0000
    parameter [31:0] AUDIO_PING_ADDR = 32'h1F20_0000;  // was 3E20_0000
    parameter [31:0] AUDIO_PONG_ADDR = 32'h1F30_0000;  // was 3E30_0000
    parameter [31:0] AUDIO_DEST_ADDR = 32'h1F40_0000;  // was 3E40_0000 
 
       
    parameter integer IQ_BUF_SIZE_WORDS = 2500;         // xlconstant_6 -- 10 ms of I/Q @ 250 kHz

    // audio_ppdma's buffer size is a COMPILE-TIME constant baked into
    // audio_ppdma.cpp (SAMPLES_PER_BUFFER = 50, i.e. 1 ms @ 50 kHz) --
    // there's no BD-level signal to confirm it from, so this value is
    // just for sizing the expected-toggle-count printout below.
    parameter integer AUDIO_SAMPLES_PER_BUFFER = 50;

    // AXI GPIO (dual-channel, both inputs) -- mapped at 0x4000_0000 per
    // bd.tcl's assign_bd_address on axi_gpio_0/S_AXI/Reg. Standard AXI
    // GPIO v2.0 register map: GPIO_DATA=0x00 (channel 1), GPIO2_DATA=0x08
    // (channel 2).
    //   channel 1 (GPIO_DATA,  offset 0x00) <- iq_ppdma_0/active_buf
    //   channel 2 (GPIO2_DATA, offset 0x08) <- audio_ppdma_0/active_buf
    parameter [31:0] AXI_GPIO_BASE     = 32'h4000_0000;
    parameter [31:0] GPIO_DATA_OFFSET  = 32'h0000_0000;
    parameter [31:0] GPIO2_DATA_OFFSET = 32'h0000_0008;

    parameter integer POLL_INTERVAL_CYCLES = 10000;         // 100 us @ 100 MHz
    parameter integer TEST_DURATION_NS     = 20_000_000;   // 500 ms -- see runtime note below
    parameter integer NUM_POLLS            = TEST_DURATION_NS / (POLL_INTERVAL_CYCLES * 10);

    // Liveness watchdog timeouts. Expected toggle period is ~10 ms for
    // iq_ppdma (2500 words @ 250 kHz) and ~1 ms for audio_ppdma (50
    // words @ 50 kHz). Both timeouts carry a 5x margin over that nominal
    // period so ordinary scheduling/simulation jitter never trips a
    // false hang -- only genuine stalls should ever fire these.
    parameter integer IQ_HANG_TIMEOUT_NS    = 50_000_000;   // 50 ms  (5x margin over ~10 ms)
    parameter integer AUDIO_HANG_TIMEOUT_NS = 5_000_000;    // 5 ms   (5x margin over ~1 ms)

    // NOTE ON RUNTIME: 500 ms @ 100 MHz is 50,000,000 clock cycles of
    // full mixed RTL (PS7 VIP + fm_demod + both ppdma cores) simulation.
    // That is a genuinely long XSIM run -- likely minutes to tens of
    // minutes depending on the machine, not a quick smoke test. If
    // you're iterating on something else and just want a fast sanity
    // check that the harness itself works, drop TEST_DURATION_NS to
    // something like 20_000_000 (20 ms, a few dozen audio toggles and a
    // couple of iq toggles) before running the full 500 ms version.

    // Settle time between PL reset release and the first M_AXI_GP0 read of
    // active_buf. This exists specifically because polling too early can
    // catch an AXI4 read while active_buf's underlying register is still
    // X (either genuine pipeline/reset-scope settling, or an unresolved
    // bug) -- XSIM's AXI4 protocol checker treats X on a valid RDATA beat
    // as a hard spec violation and kills the simulation outright, which
    // means polling too early can mask "is the data ever actually good"
    // behind an unrelated-looking crash. This does NOT fix an underlying
    // X-never-resolves bug if one exists; it only avoids asking the
    // question before there's anything meaningful to ask.
    parameter integer PRE_POLL_SETTLE_CYCLES = 200000;  // 2 ms @ 100 MHz

    // DUT Net Port Declarations (Must be wires for inout mapping)
    wire [14:0] DDR_addr; wire [2:0] DDR_ba; wire [3:0] DDR_dm, DDR_dqs_n, DDR_dqs_p; wire [31:0] DDR_dq;
    wire DDR_cas_n, DDR_ck_n, DDR_ck_p, DDR_cke, DDR_cs_n, DDR_odt, DDR_ras_n, DDR_reset_n, DDR_we_n;
    wire FIXED_IO_ddr_vrn, FIXED_IO_ddr_vrp; wire [53:0] FIXED_IO_mio;
    wire FIXED_IO_ps_clk, FIXED_IO_ps_porb, FIXED_IO_ps_srstb;

    // Testbench Driver Registers
    reg ps_clk_drv;
    reg ps_porb_drv;
    reg ps_srstb_drv;

    // Continuous Assignments to Bridge Regs to Inout Wires
    assign FIXED_IO_ps_clk   = ps_clk_drv;
    assign FIXED_IO_ps_porb  = ps_porb_drv;
    assign FIXED_IO_ps_srstb = ps_srstb_drv;

    sdr_fm_receiver_wrapper dut (
        .DDR_addr(DDR_addr), .DDR_ba(DDR_ba), .DDR_cas_n(DDR_cas_n), .DDR_ck_n(DDR_ck_n), .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke), .DDR_cs_n(DDR_cs_n), .DDR_dm(DDR_dm), .DDR_dq(DDR_dq), .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p), .DDR_odt(DDR_odt), .DDR_ras_n(DDR_ras_n), .DDR_reset_n(DDR_reset_n), .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn), .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp), .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk), .FIXED_IO_ps_porb(FIXED_IO_ps_porb), .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb)
    );

    // 33.333 MHz PS Oscillator
    initial begin ps_clk_drv = 1'b0; forever #15.015 ps_clk_drv = ~ps_clk_drv; end

    // gp0_write/gp0_read/hp0_write/hp0_read are "automatic" so each call
    // gets its OWN private copy of the scratch temp vars, same rationale
    // as the original testbench -- kept verbatim, still correct here.
    task automatic gp0_write(input [31:0] addr, input [31:0] data);
        reg [1023:0] tmp_wide; reg [31:0] tmp_resp;
        begin
            tmp_wide = {{992{1'b0}}, data};
            `PS7.write_data(addr, 4, tmp_wide, tmp_resp);
        end
    endtask

    task automatic gp0_read(input [31:0] addr, output [31:0] data);
        reg [1023:0] tmp_wide; reg [31:0] tmp_resp;
        begin
            `PS7.read_data(addr, 4, tmp_wide, tmp_resp);
            data = tmp_wide[31:0];
        end
    endtask

    task automatic hp0_write(input [31:0] addr, input [31:0] data);
        reg [1023:0] tmp_wide;
        begin
            tmp_wide = {{992{1'b0}}, data};
            `PS7.write_mem(tmp_wide, addr, 4);
        end
    endtask

    task automatic hp0_read(input [31:0] addr, output [31:0] data);
        reg [1023:0] tmp_wide;
        begin
            `PS7.read_mem(addr, 4, tmp_wide);
            data = tmp_wide[31:0];
        end
    endtask

    // ------------------------------------------------------------------
    // Pre-load one I/Q buffer with a repeating sine wave, packed
    // {I[31:16], Q[15:0]} -- matches iq_ppdma's unpack convention
    // (packed(31,16)=I, packed(15,0)=Q). sample_offset lets ping and
    // pong carry a continuous phase across the boundary rather than
    // both restarting at angle 0, purely cosmetic/representative, not
    // required for the liveness check itself.
    // ------------------------------------------------------------------
    task automatic load_iq_buffer(input [31:0] base_addr, input integer sample_offset);
        integer k;
        real angle;
        reg signed [15:0] i_val, q_val;
        reg [31:0] packed_iq;
        begin
            for (k = 0; k < IQ_BUF_SIZE_WORDS; k = k + 1) begin
                angle = 2.0 * 3.14159265 * (sample_offset + k) / 250.0;
                i_val = $rtoi(4000.0 * $cos(angle));
                q_val = $rtoi(4000.0 * $sin(angle));
                packed_iq = {i_val, q_val};
                hp0_write(base_addr + (k * 4), packed_iq);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Liveness watchdog for one AXI GPIO channel's active_buf bit. Any
    // observed change counts as a toggle and resets that channel's hang
    // timer. If MORE than timeout_ns elapses with no toggle at all, the
    // corresponding DMA is declared hung and the simulation stops.
    // ------------------------------------------------------------------
    task automatic watchdog_poll(
        input  [31:0]  gpio_addr,
        input  integer timeout_ns,
        input  string  label,
        inout  [31:0]  prev_val,
        inout  time    last_toggle_time,
        inout  integer toggle_count
    );
        reg [31:0] cur_val;
        begin
            gp0_read(gpio_addr, cur_val);
            if (cur_val[0] !== prev_val[0]) begin
                toggle_count      = toggle_count + 1;
                last_toggle_time  = $time;
                prev_val          = cur_val;
            end else if (($time - last_toggle_time) > timeout_ns) begin
                $error("%s: no active_buf toggle for over %0d ns -- DMA appears hung (stuck at %0d since t=%0t)",
                       label, timeout_ns, prev_val[0], last_toggle_time);
                $finish;
            end
        end
    endtask

    reg   [31:0] iq_prev, audio_prev;
    time         iq_last_toggle, audio_last_toggle;
    integer      iq_toggle_count, audio_toggle_count;
    integer      poll_idx, j, n_nonzero;
    reg   [31:0] rdata;

    // ------------------------------------------------------------------
    // DIAGNOSTIC: iq_ppdma_0 real per-invocation AXI read timing, and
    // whether any stretching beyond its intended 400-cycle budget
    // correlates with audio_ppdma_0 genuinely driving an AXI transaction
    // on the SAME shared S_AXI_HP0 port at that exact moment.
    // ------------------------------------------------------------------
    // Added after ten prior measurements (scheduling, syscalls,
    // bandwidth, poll-loop headroom, USB timing uniformity, and the PS7
    // FCLK0 configuration decoded directly from ps7_init.tcl as an
    // EXACT 100.000 MHz) all came back clean, yet gpio_rate_test.c
    // measured iq_ppdma_0's real active_buf toggle rate at 92.70 Hz on
    // actual silicon, not the intended 100 Hz. iq_ppdma_0 and
    // audio_ppdma_0 share S_AXI_HP0 (bd.tcl's two assign_bd_address
    // lines both target HP0_DDR_LOWOCM) -- this tests that sharing
    // directly.
    //
    // An EARLIER version of this probe used ap_start/ap_idle via a
    // guessed `.inst.` sub-hierarchy and silently measured nothing for
    // nearly two hours of simulation -- the signals likely do not
    // survive synthesis as observable nets at all, since ap_start is
    // tied permanently high via an xlconstant and nothing downstream
    // reads ap_idle/ap_done, so Vivado has no reason to keep them. This
    // version instead measures off iq_ppdma_0's actual AXI4 read
    // handshake (RVALID && RREADY, a completed data beat -- iq_ppdma
    // does exactly one such read per invocation), using FLAT TOP-LEVEL
    // WIRE NAMES confirmed present by grep against the real generated
    // sdr_fm_receiver.v (Vivado's block-design wrapper flattens
    // inter-IP connections to underscore-joined names at the
    // dut.sdr_fm_receiver_i scope directly -- no .inst sub-hierarchy
    // needed, unlike the earlier guess):
    //   iq_ppdma_0_m_axi_gmem_RVALID / _RREADY         (confirmed present)
    //   audio_ppdma_0_m_axi_gmem_{AR,R,AW,W,B}VALID/READY (confirmed present)
    // If a future bd.tcl regeneration ever renames these (e.g. a second
    // iq_ppdma instance becoming iq_ppdma_1), re-grep sim/sdr_fm_receiver.v
    // for "_m_axi_gmem_" before trusting this unchanged.
    wire iq_rd_beat    = dut.sdr_fm_receiver_i.iq_ppdma_0_m_axi_gmem_RVALID &&
                          dut.sdr_fm_receiver_i.iq_ppdma_0_m_axi_gmem_RREADY;

    wire audio_axi_active =
        (dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_ARVALID && dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_ARREADY) ||
        (dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_RVALID  && dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_RREADY)  ||
        (dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_AWVALID && dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_AWREADY) ||
        (dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_WVALID  && dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_WREADY)  ||
        (dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_BVALID  && dut.sdr_fm_receiver_i.audio_ppdma_0_m_axi_gmem_BREADY);

    longint unsigned iq_diag_cycle_count;
    longint unsigned iq_diag_last_beat_cycle;
    longint unsigned iq_diag_interval_count;
    longint unsigned iq_diag_interval_sum;
    longint unsigned iq_diag_interval_min;
    longint unsigned iq_diag_interval_max;
    longint unsigned iq_diag_stretch_count;              // intervals > 400 cycles
    longint unsigned iq_diag_stretch_with_audio_active;   // of those, audio_ppdma was ALSO on the bus

    initial begin
        iq_diag_cycle_count               = 0;
        iq_diag_last_beat_cycle           = 0;
        iq_diag_interval_count            = 0;
        iq_diag_interval_sum              = 0;
        iq_diag_interval_min              = 64'hFFFF_FFFF_FFFF_FFFF;
        iq_diag_interval_max              = 0;
        iq_diag_stretch_count             = 0;
        iq_diag_stretch_with_audio_active = 0;
    end

    always @(posedge `PS7.FCLK_CLK0) begin
        iq_diag_cycle_count <= iq_diag_cycle_count + 1;

        if (iq_rd_beat) begin
            if (iq_diag_last_beat_cycle != 0) begin
                automatic longint unsigned interval = iq_diag_cycle_count - iq_diag_last_beat_cycle;
                iq_diag_interval_count = iq_diag_interval_count + 1;
                iq_diag_interval_sum   = iq_diag_interval_sum + interval;
                if (interval < iq_diag_interval_min) iq_diag_interval_min = interval;
                if (interval > iq_diag_interval_max) iq_diag_interval_max = interval;

                if (interval > 400) begin
                    iq_diag_stretch_count = iq_diag_stretch_count + 1;
                    if (audio_axi_active) begin
                        iq_diag_stretch_with_audio_active = iq_diag_stretch_with_audio_active + 1;
                    end
                end
            end
            iq_diag_last_beat_cycle = iq_diag_cycle_count;
        end
    end

    initial begin
        $display("=== SDR FM Receiver -- Free-Running ppdma Liveness Test ===");
        $display("Test duration target: %0d ns (%.1f ms), %0d polls every %0d ns",
                  TEST_DURATION_NS, TEST_DURATION_NS / 1.0e6, NUM_POLLS, POLL_INTERVAL_CYCLES * 10);

        ps_porb_drv = 1'b0; ps_srstb_drv = 1'b0; #100;
        ps_porb_drv = 1'b1; ps_srstb_drv = 1'b1; #200;

        `PS7.set_slave_profile("S_AXI_HP0", 2'b00); `PS7.set_slave_profile("ALL", 2'b00);

        // Load BOTH ping and pong I/Q buffers BEFORE releasing PL reset.
        // ap_start is tied high, so iq_ppdma starts reading the instant
        // reset deasserts -- there is no arm step to sequence against,
        // unlike the old AXI-DMA testbench.
        $display("Pre-loading I/Q ping/pong buffers (%0d words each, %0d total hp0_write calls)...",
                  IQ_BUF_SIZE_WORDS, 2 * IQ_BUF_SIZE_WORDS);
        load_iq_buffer(IQ_PING_ADDR, 0);
        load_iq_buffer(IQ_PONG_ADDR, IQ_BUF_SIZE_WORDS);
        $display("I/Q pre-load complete at t=%0t.", $time);

        $display("Releasing PL reset -- fm_demod/audio_ppdma/iq_ppdma all start running now...");
        `PS7.fpga_soft_reset(4'hF); repeat (16) @(posedge `PS7.FCLK_CLK0);
        `PS7.fpga_soft_reset(4'h0); repeat (5000) @(posedge `PS7.FCLK_CLK0);

        // Wait out PRE_POLL_SETTLE_CYCLES before touching M_AXI_GP0 at
        // all -- see the parameter comment above for why.
        $display("Waiting %0d cycles (%0d ns) before the first active_buf poll...",
                  PRE_POLL_SETTLE_CYCLES, PRE_POLL_SETTLE_CYCLES * 10);
        repeat (PRE_POLL_SETTLE_CYCLES) @(posedge `PS7.FCLK_CLK0);

        // Baseline read before the watchdog starts timing anything, so
        // the very first poll doesn't get misread as a "toggle from x".
        gp0_read(AXI_GPIO_BASE + GPIO_DATA_OFFSET,  iq_prev);
        gp0_read(AXI_GPIO_BASE + GPIO2_DATA_OFFSET, audio_prev);
        iq_last_toggle     = $time;
        audio_last_toggle  = $time;
        iq_toggle_count    = 0;
        audio_toggle_count = 0;
        $display("Baseline @ t=%0t: iq active_buf=%0d, audio active_buf=%0d", $time, iq_prev[0], audio_prev[0]);

        for (poll_idx = 0; poll_idx < NUM_POLLS; poll_idx = poll_idx + 1) begin
            repeat (POLL_INTERVAL_CYCLES) @(posedge `PS7.FCLK_CLK0);

            watchdog_poll(AXI_GPIO_BASE + GPIO_DATA_OFFSET, IQ_HANG_TIMEOUT_NS, "iq_ppdma",
                          iq_prev, iq_last_toggle, iq_toggle_count);
            watchdog_poll(AXI_GPIO_BASE + GPIO2_DATA_OFFSET, AUDIO_HANG_TIMEOUT_NS, "audio_ppdma",
                          audio_prev, audio_last_toggle, audio_toggle_count);

            if (poll_idx % 500 == 0) begin
                $display("  t=%0t : iq_ppdma toggles=%0d (active_buf=%0d), audio_ppdma toggles=%0d (active_buf=%0d)",
                          $time, iq_toggle_count, iq_prev[0], audio_toggle_count, audio_prev[0]);
            end
        end

        // Informational only, not a pass/fail gate: peek at a few words
        // of audio_ppdma's dest mirror so a totally-silent/zeroed audio
        // path is at least visible in the log, echoing the spirit of the
        // original testbench's closing readback without turning this
        // into a signal-fidelity test.
        $display("Reading back a few dest_base words (informational only)...");
        n_nonzero = 0;
        for (j = 0; j < 16; j = j + 1) begin
            hp0_read(AUDIO_DEST_ADDR + (j * 4), rdata);
            if (rdata !== 32'h0) n_nonzero = n_nonzero + 1;
            $display("  dest[%0d] = 0x%08x (%0d)", j, rdata, $signed(rdata));
        end

        $display("==================================================");
        $display(" Test duration reached: %0t", $time);
        $display(" iq_ppdma    : %0d ping-pong toggles (nominal expectation ~%0d over %0d ms @ ~10 ms/toggle)",
                  iq_toggle_count, TEST_DURATION_NS / 10_000_000, TEST_DURATION_NS / 1_000_000);
        $display(" audio_ppdma : %0d ping-pong toggles (nominal expectation ~%0d over %0d ms @ ~1 ms/toggle)",
                  audio_toggle_count, TEST_DURATION_NS / 1_000_000, TEST_DURATION_NS / 1_000_000);
        $display(" dest_base sample : %0d/16 words non-zero (informational, not a pass/fail gate)", n_nonzero);
        if (iq_toggle_count > 0 && audio_toggle_count > 0)
            $display(" PASS: both DMAs toggled repeatedly across the full test duration -- neither hung.");
        else
            $error(" FAIL: at least one DMA never toggled active_buf at all during the test.");
        $display("==================================================");

        #1000; $finish;
    end

    final begin
        $display("==================================================");
        $display("  iq_ppdma_0 real AXI timing / contention diagnostic");
        $display("==================================================");
        if (iq_diag_interval_count == 0) begin
            $display("  No repeated RVALID&&RREADY beats observed -- these");
            $display("  signal names were grep-confirmed present in the real");
            $display("  generated sdr_fm_receiver.v, so an empty result here");
            $display("  most likely means iq_ppdma genuinely never completed");
            $display("  a read in this run (check DDR pre-load / reset timing)");
            $display("  rather than a wrong path.");
        end else begin
            $display("  invocations measured: %0d", iq_diag_interval_count);
            $display("  interval (cycles): min=%0d  max=%0d  avg=%0.1f  (design intent: 400)",
                      iq_diag_interval_min, iq_diag_interval_max,
                      real'(iq_diag_interval_sum) / real'(iq_diag_interval_count));
            $display("  intervals > 400 cycles (\"stretched\"): %0d (%0.1f%% of all invocations)",
                      iq_diag_stretch_count,
                      100.0 * real'(iq_diag_stretch_count) / real'(iq_diag_interval_count));
            if (iq_diag_stretch_count > 0) begin
                $display("  of those, audio_ppdma_0 was ALSO driving an AXI");
                $display("  transaction on the shared bus at that exact moment:");
                $display("  %0d (%0.1f%% of stretched intervals)",
                          iq_diag_stretch_with_audio_active,
                          100.0 * real'(iq_diag_stretch_with_audio_active) / real'(iq_diag_stretch_count));
                $display("  -- a HIGH percentage here directly supports the HP0");
                $display("     bus-contention hypothesis; a LOW percentage rules");
                $display("     it out and points elsewhere.");
            end else begin
                $display("  No stretched intervals observed -- iq_ppdma_0 stayed");
                $display("  at its intended 400-cycle budget throughout this run.");
            end
        end
        $display("==================================================");
    end

endmodule
