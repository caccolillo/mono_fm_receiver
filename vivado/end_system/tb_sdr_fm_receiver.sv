`timescale 1ns / 1ps
`define PS dut.sdr_fm_receiver_i.zynq_ultra_ps_e_0.inst
`define PS_CLK dut.sdr_fm_receiver_i.zynq_ultra_ps_e_0.pl_clk0

// ------------------------------------------------------------------------
// tb_sdr_fm_receiver_liveness.sv -- Ultra96-V2 (Zynq UltraScale+) port
//
// Ported from the Zybo Z7-10 (PS7) version. The liveness/hang-detection
// LOGIC below is unchanged and device-agnostic -- watchdog_poll() still
// just watches active_buf toggle over AXI-GPIO and declares a hang if it
// stalls for more than 5x its nominal period. That's the actual "is the
// DMA stalling the PS" check, and it doesn't care what PS silicon is
// underneath. What changed is everything PS7-VIP-specific:
//   - `PS7 hierarchy macro -> `PS, now pointing at zynq_ultra_ps_e_0.inst
//     instead of processing_system7_0.inst (matches the cell name chosen
//     in the ported bd.tcl).
//   - FCLK_CLK0 -> pl_clk0, but NOT reached through `PS (.inst) --
//     elaboration confirmed pl_clk0 isn't visible under .inst (that
//     scope has the VIP's BFM tasks like write_data/read_data, which DID
//     resolve fine, but apparently not the clock pin itself). pl_clk0 is
//     referenced instead via a second macro, `PS_CLK, pointing one level
//     up at the zynq_ultra_ps_e_0 cell boundary directly -- the same pin
//     bd.tcl already wires with connect_bd_net, so it's known-good
//     rather than another guess about VIP internals.
//   - set_slave_profile's port-name argument: "S_AXI_HP0" -> "SAXIGP2".
//     ZU+'s S_AXI_HP0_FPD is internally numbered SAXIGP2 in the PS-PL
//     interface (GP0/1 = the two M_AXI_HPM master ports, GP2-5 = the four
//     S_AXI_HP slave ports) -- this matches the CONFIG.PSU__SAXIGP2__*
//     property already used in bd.tcl for the same port. UNVERIFIED
//     against a live 2022.2 elaboration; if set_slave_profile errors,
//     check the actual port-name strings the ZU+ VIP model accepts.
//   - PS reference clock / reset ports: turned out not to exist at all.
//     A live elaboration confirmed sdr_fm_receiver_wrapper has an EMPTY
//     port list once the Ultra96-V2 board preset is applied -- DDR and
//     PS clock/reset are all tied internally to the module's fixed
//     LPDDR4/oscillator/reset circuitry. See the comment above the DUT
//     instantiation for the detail; the practical effect is there's
//     nothing left to drive from this testbench at all.
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
    // ping_base/pong_base/dest_base/buf_size_words in bd.tcl.
    //
    // UPDATE: bd.tcl's build log confirms HP0_DDR_LOW spans 0x0000_0000-
    // 0x7FFF_FFFF (2 GB) on the ZU+ port, and 0x3Exx_xxxx sits well
    // inside that range -- so these five values are very likely still
    // valid as-is and probably do NOT need to change, unlike the GPIO
    // base below. Still worth a sanity check in the Address Editor
    // before trusting it (confirm nothing else got auto-assigned into
    // the same region), but this is no longer a blind guess.
    //
    // Separately: AMD's DS941 (VIP datasheet) documents the VIP's own
    // simulated DDR range as 0x0000_0000-0x3FFF_FFFF (1 GB) -- narrower
    // than the real 2 GB HP0_DDR_LOW hardware decode above. 0x3Exx_xxxx
    // fits inside both, so this doesn't change anything here, but it's
    // the ceiling to remember if these addresses ever get pushed higher.
    // ------------------------------------------------------------------
    parameter [31:0] IQ_PING_ADDR    = 32'h3E00_0000;  // xlconstant_1
    parameter [31:0] IQ_PONG_ADDR    = 32'h3E10_0000;  // xlconstant_2
    parameter [31:0] AUDIO_PING_ADDR = 32'h3E20_0000;  // xlconstant_3 (informational only, not read here)
    parameter [31:0] AUDIO_PONG_ADDR = 32'h3E30_0000;  // xlconstant_4 (informational only, not read here)
    parameter [31:0] AUDIO_DEST_ADDR = 32'h3E40_0000;  // xlconstant_5 -- read back a few words at the end
    parameter integer IQ_BUF_SIZE_WORDS = 2500;         // xlconstant_6 -- 10 ms of I/Q @ 250 kHz

    // audio_ppdma's buffer size is a COMPILE-TIME constant baked into
    // audio_ppdma.cpp (SAMPLES_PER_BUFFER = 50, i.e. 1 ms @ 50 kHz) --
    // there's no BD-level signal to confirm it from, so this value is
    // just for sizing the expected-toggle-count printout below.
    parameter integer AUDIO_SAMPLES_PER_BUFFER = 50;

    // AXI GPIO (dual-channel, both inputs). CONFIRMED from an actual
    // ZU+ build log: axi_gpio_0 lands at 0xA000_0000 on this port, not
    // PS7's 0x4000_0000 -- GP0's default PL-peripheral window moved.
    // Update the matching C #define in main.c/fmdemod-linux.c to match
    // if software ever addresses this GPIO directly (this testbench
    // already reflects the new value below). Standard AXI GPIO v2.0
    // register map itself is unaffected by the PS change:
    //   channel 1 (GPIO_DATA,  offset 0x00) <- iq_ppdma_0/active_buf
    //   channel 2 (GPIO2_DATA, offset 0x08) <- audio_ppdma_0/active_buf
    parameter [31:0] AXI_GPIO_BASE     = 32'hA000_0000;
    parameter [31:0] GPIO_DATA_OFFSET  = 32'h0000_0000;
    parameter [31:0] GPIO2_DATA_OFFSET = 32'h0000_0008;

    parameter integer POLL_INTERVAL_CYCLES = 10000;         // 100 us @ 100 MHz
    parameter integer TEST_DURATION_NS     = 50_000_000;    // 50 ms -- see runtime note below
    parameter integer NUM_POLLS            = TEST_DURATION_NS / (POLL_INTERVAL_CYCLES * 10);

    // Liveness watchdog timeouts.
    //
    // REVISED, substantially: the original 5x-margin timeouts (50ms/5ms)
    // were sized against NOMINAL rates (~10ms/iq refill, ~1ms/audio
    // block) -- but those nominal figures describe the OLD free-running,
    // unpaced system. With aa_lpf/freq_corr/nco all now genuinely
    // respecting backpressure, confirmed correct AND confirmed alive via
    // direct probing (audio_ppdma really did complete a sample transfer
    // at t=7173085ns, sample_tvalid=1/tready=1/ap_done -- not a hang),
    // the real achievable rate through the full chain, driven by real
    // iq_ppdma AXI4 read latency (~300ns/transaction observed via the PS
    // VIP) plus multiple real per-sample HLS processing costs, may
    // genuinely be far slower than the old nominal figures assumed. The
    // old 5ms audio timeout was firing on a system that was working
    // correctly, just slower than expected -- not evidence of a bug.
    // Bumped generously to actually find out the real rate rather than
    // keep guessing.
    parameter integer IQ_HANG_TIMEOUT_NS    = 500_000_000;  // 500 ms
    parameter integer AUDIO_HANG_TIMEOUT_NS = 150_000_000;  // 150 ms

    // NOTE ON RUNTIME: bumped from 20ms back up toward the original
    // 500ms range, though not all the way -- 200ms should be enough to
    // either see a real active_buf toggle (confirming the system works,
    // just slowly) or hit the new, much more generous hang timeout with
    // higher confidence that's a REAL problem rather than an
    // underestimated nominal rate. Expect a long wall-clock run given
    // the earlier ~60-100x real-time slowdown data point -- this could
    // be multiple hours. Worth letting it run in the background rather
    // than waiting on it interactively.

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

    // ------------------------------------------------------------------
    // CONFIRMED from the actual generated wrapper (grep of
    // sdr_fm_receiver_wrapper.v): the top-level module has an EMPTY port
    // list --
    //   module sdr_fm_receiver_wrapper (); ... endmodule
    // So the original suspicion in this comment (kept below for the
    // history, since it turned out to be the right call) was correct:
    // once the Ultra96-V2 board preset is applied, DDR is tied straight
    // to the on-module LPDDR4 pins internally, and the PS reference
    // clock / power-on-reset / system-reset are likewise tied to the
    // board's fixed oscillator and reset circuitry -- none of it is
    // exposed as a top-level port. There is nothing for this testbench
    // to drive externally. No wires, no driver regs, no port map --
    // just an empty instantiation.
    //
    // This also explains the earlier elaboration error at DDR_we_n /
    // DDR_dqs_n / DDR_ck_p: those weren't renamed for LPDDR4 signaling,
    // they simply don't exist on this wrapper at all.
    //
    // CORRECTION (superseding what this comment originally said): the
    // PS's TOP-LEVEL PINS aren't externally driven anymore -- that part
    // is right, and the port-list evidence above proves it. But the VIP
    // does NOT skip reset entirely; it just moved from pin-driven to
    // task-driven. AMD's DS941 confirms por_srstb_reset is a *mandatory*
    // task call before any other VIP API, including the backdoor
    // write_mem calls this file uses to preload DDR. See the
    // por_srstb_reset sequence right before set_slave_profile below --
    // omitting it produced exactly the failure this comment originally
    // predicted wouldn't happen (a forward-progress timeout on
    // S_AXI_HP0_FPD reads, because the VIP's memory model stayed in
    // reset). Left the wrong reasoning visible here rather than quietly
    // deleting it, since the correction is more useful with the mistake
    // still attached to it.
    // ------------------------------------------------------------------

    sdr_fm_receiver_wrapper dut ();

    // gp0_write/gp0_read/hp0_write/hp0_read are "automatic" so each call
    // gets its OWN private copy of the scratch temp vars, same rationale
    // as the original testbench -- kept verbatim, still correct here.
    task automatic gp0_write(input [31:0] addr, input [31:0] data);
        reg [1023:0] tmp_wide; reg [31:0] tmp_resp;
        begin
            tmp_wide = {{992{1'b0}}, data};
            `PS.write_data(addr, 4, tmp_wide, tmp_resp);
        end
    endtask

    task automatic gp0_read(input [31:0] addr, output [31:0] data);
        reg [1023:0] tmp_wide; reg [31:0] tmp_resp;
        begin
            `PS.read_data(addr, 4, tmp_wide, tmp_resp);
            data = tmp_wide[31:0];
        end
    endtask

    task automatic hp0_write(input [31:0] addr, input [31:0] data);
        reg [1023:0] tmp_wide;
        begin
            tmp_wide = {{992{1'b0}}, data};
            `PS.write_mem(tmp_wide, addr, 4);
        end
    endtask

    task automatic hp0_read(input [31:0] addr, output [31:0] data);
        reg [1023:0] tmp_wide;
        begin
            `PS.read_mem(addr, 4, tmp_wide);
            data = tmp_wide[31:0];
        end
    endtask

    // ------------------------------------------------------------------
    // REAL-CONTENT UPGRADE: this task used to synthesize a fake sine/
    // cosine test tone in-line. Reusing it to test whether the *actual*
    // audio content is correct doesn't work -- a synthetic tone can't
    // reveal a content bug regardless of whether one exists, since
    // there's no "correct" audio a tone could be compared against.
    //
    // Now reads REAL samples from the same s_axis_i_stimulus.txt /
    // s_axis_q_stimulus.txt already generated by gen_fm_demod_stimulus.m
    // for the fm_demod-only chain test -- no new MATLAB step needed,
    // same real rds.wav-derived content. File handles are opened once,
    // inline near the top of the main initial block below (fd_i_stim/
    // fd_q_stim), and read sequentially; SystemVerilog $fscanf naturally continues from wherever the file cursor left
    // off across repeated calls, so ping then pong then (if ever
    // refilled) ping again reads forward through the file correctly
    // with no extra bookkeeping needed here.
    //
    // Deliberately NOT wired up for continuous refilling as ping/pong
    // empty (unlike main.c's real refill loop) -- IQ_BUF_SIZE_WORDS is a
    // synthesis-time xlconstant in bd.tcl, not something this testbench
    // can resize, so the two one-time preload calls below are hard-
    // bounded to 2*IQ_BUF_SIZE_WORDS = 5000 real samples (~20ms nominal
    // @ 250 kHz) regardless. That's a deliberate scope choice, not an
    // oversight: 5000 real I/Q samples decimated 5:1 is ~1000 real audio
    // samples, which is already enough for a solid envelope/spectrum
    // check (confirmed -- that's roughly what worked well in the
    // fm_demod-only chain test earlier). Continuous refilling would add
    // real risk of reintroducing the exact "software too slow, silently
    // stale/repeated data" class of bug this whole session has been
    // chasing on the real hardware side, for no benefit this specific
    // check actually needs. TEST_DURATION_NS's 20ms default was chosen
    // to line up with this.
    task automatic load_iq_buffer(input [31:0] base_addr, input integer sample_offset);
        integer k;
        integer code_i, code_q;
        integer i_val_int, q_val_int;
        reg signed [15:0] i_val, q_val;
        reg [31:0] packed_iq;
        begin
            for (k = 0; k < IQ_BUF_SIZE_WORDS; k = k + 1) begin
                if (!stim_eof) begin
                    code_i = $fscanf(fd_i_stim, "%d\n", i_val_int);
                    code_q = $fscanf(fd_q_stim, "%d\n", q_val_int);
                    if (code_i != 1 || code_q != 1) begin
                        $display("Real stimulus exhausted after %0d samples (this is expected once the loaded window runs out, not an error) -- remaining words zero-padded.",
                                  sample_offset + k);
                        stim_eof = 1'b1;
                    end
                end

                if (stim_eof) begin
                    i_val = 16'sd0;
                    q_val = 16'sd0;
                end else begin
                    i_val = i_val_int[15:0];
                    q_val = q_val_int[15:0];
                end

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

    // Real-content stimulus file handles -- see load_iq_buffer's header
    // comment above for the full reasoning. Opened once, read
    // sequentially across both preload calls.
    integer fd_i_stim, fd_q_stim;
    bit     stim_eof = 1'b0;

    // Real audio-content capture: appended to on every detected
    // audio_ppdma toggle (reusing the SAME watchdog_poll-driven GPIO
    // toggle detection already proven working in this file, rather than
    // guessing at fm_demod_0's internal hierarchy under its packaging
    // wrapper -- unlike aa_lpf_I/iq_ppdma_0 elsewhere in this session,
    // there's no prior confirmation of what that nested path even looks
    // like here, so reusing the already-proven hp0_read/GPIO path is the
    // lower-risk choice). Bound by the same POLL_INTERVAL_CYCLES polling
    // rate as the existing liveness watchdog -- some audio toggles may
    // be missed if the real post-fix toggle rate is faster than one poll
    // interval, same class of risk as the earlier bare-metal C polling
    // bug, but for this qualitative envelope/spectrum check (not a
    // lossless capture) a sparser real sample set is still sufficient to
    // tell a genuine dynamic signal apart from a flat spurious tone.
    integer fd_audio_capture;
    integer audio_capture_count;

    initial begin
        $display("=== SDR FM Receiver (Ultra96-V2 / ZU+ port) -- Free-Running ppdma Liveness Test ===");
        $display("Test duration target: %0d ns (%.1f ms), %0d polls every %0d ns",
                  TEST_DURATION_NS, TEST_DURATION_NS / 1.0e6, NUM_POLLS, POLL_INTERVAL_CYCLES * 10);

        fd_i_stim = $fopen("s_axis_i_stimulus.txt", "r");
        fd_q_stim = $fopen("s_axis_q_stimulus.txt", "r");
        if (fd_i_stim == 0 || fd_q_stim == 0) begin
            $error("Could not open s_axis_i_stimulus.txt / s_axis_q_stimulus.txt -- copy them from the fm_demod-only chain test's directory (generated by gen_fm_demod_stimulus.m) into this project's xsim working directory first.");
            $finish;
        end

        fd_audio_capture = $fopen("audio_dest_dut_output.txt", "w");
        if (fd_audio_capture == 0) begin
            $error("Could not open audio_dest_dut_output.txt for writing");
            $finish;
        end
        audio_capture_count = 0;

        // REVISED again: waveform evidence ruled out a reset-release race
        // (aresetn_0 was stable ~150-200 ns before ARVALID ever pulsed),
        // but the symptom persisted -- AR accepted, RVALID never comes.
        // The remaining gap vs. DS941's own example: their sequence
        // RE-ASSERTS por_srstb_reset a second time, interleaved between
        // the two fpga_soft_reset calls, which an earlier revision of
        // this file dropped (it resolved por_srstb_reset once, in
        // isolation, well before ever touching fpga_soft_reset). If that
        // second pulse is what actually arms the HP slave's read-response
        // state machine -- as opposed to being a cosmetic repeat -- that
        // would explain exactly this: the interconnect-level handshake
        // (AR/AREADY) doesn't depend on it and looks fine, but the sparse
        // DDR responder behind it never gets armed.
        //
        // IMPORTANT ORDERING CONSTRAINT this revision adds: if
        // por_srstb_reset really is a POR-equivalent for the whole VIP,
        // it may clear the sparse DDR model along with everything else --
        // in which case preloading BEFORE the second pulse would silently
        // wipe the data (swapping "read never completes" for the much
        // harder to notice "read completes but returns zeros"). So the
        // preload now happens AFTER both por_srstb_reset pulses resolve,
        // while fpga_soft_reset still holds the PL fabric in reset -- that
        // also means ap_start being tied high can't race the preload,
        // since the PL logic reading it is itself held in reset the whole
        // time until fpga_soft_reset(4'h0) at the very end.
        `PS.por_srstb_reset(1'b1);
        #200;
        `PS.por_srstb_reset(1'b0);
        #200;

        `PS.set_slave_profile("SAXIGP2", 2'b00); `PS.set_slave_profile("ALL", 2'b00);

        $display("Asserting PL fabric reset, then re-asserting por_srstb_reset per DS941's interleaved sequence...");
        `PS.fpga_soft_reset(4'hF);
        repeat (16) @(posedge `PS_CLK);
        `PS.por_srstb_reset(1'b1);   // second pulse, matching DS941 -- PL fabric still held in reset here

        // Load BOTH ping and pong I/Q buffers now: both resets have
        // resolved, and PL fabric reset is still asserted so ap_start
        // (tied permanently high) can't act on anything yet.
        $display("Pre-loading I/Q ping/pong buffers (%0d words each, %0d total hp0_write calls)...",
                  IQ_BUF_SIZE_WORDS, 2 * IQ_BUF_SIZE_WORDS);
        load_iq_buffer(IQ_PING_ADDR, 0);
        load_iq_buffer(IQ_PONG_ADDR, IQ_BUF_SIZE_WORDS);
        $display("I/Q pre-load complete at t=%0t.", $time);

        $display("Releasing PL reset -- fm_demod/audio_ppdma/iq_ppdma all start running now...");
        `PS.fpga_soft_reset(4'h0);
        repeat (5000) @(posedge `PS_CLK);

        // Wait out PRE_POLL_SETTLE_CYCLES before touching M_AXI_GP0 at
        // all -- see the parameter comment above for why.
        $display("Waiting %0d cycles (%0d ns) before the first active_buf poll...",
                  PRE_POLL_SETTLE_CYCLES, PRE_POLL_SETTLE_CYCLES * 10);
        repeat (PRE_POLL_SETTLE_CYCLES) @(posedge `PS_CLK);

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
            reg [31:0] audio_prev_before_poll;
            repeat (POLL_INTERVAL_CYCLES) @(posedge `PS_CLK);

            watchdog_poll(AXI_GPIO_BASE + GPIO_DATA_OFFSET, IQ_HANG_TIMEOUT_NS, "iq_ppdma",
                          iq_prev, iq_last_toggle, iq_toggle_count);

            audio_prev_before_poll = audio_prev;
            watchdog_poll(AXI_GPIO_BASE + GPIO2_DATA_OFFSET, AUDIO_HANG_TIMEOUT_NS, "audio_ppdma",
                          audio_prev, audio_last_toggle, audio_toggle_count);

            // Real audio-content capture: a detected toggle means
            // audio_ppdma just finished writing a fresh 50-word block to
            // AUDIO_DEST_ADDR -- read it back and log every word, same
            // AUDIO_DEST_ADDR constant already proven working by the
            // original informational readback further below.
            if (audio_prev[0] !== audio_prev_before_poll[0]) begin
                for (j = 0; j < AUDIO_SAMPLES_PER_BUFFER; j = j + 1) begin
                    hp0_read(AUDIO_DEST_ADDR + (j * 4), rdata);
                    $fdisplay(fd_audio_capture, "%0d", $signed(rdata));
                end
                audio_capture_count = audio_capture_count + AUDIO_SAMPLES_PER_BUFFER;
            end

            if (poll_idx % 500 == 0) begin
                $display("  t=%0t : iq_ppdma toggles=%0d (active_buf=%0d), audio_ppdma toggles=%0d (active_buf=%0d), audio samples captured=%0d",
                          $time, iq_toggle_count, iq_prev[0], audio_toggle_count, audio_prev[0], audio_capture_count);
            end
        end

        $fclose(fd_audio_capture);
        $fclose(fd_i_stim);
        $fclose(fd_q_stim);
        $display("Real audio content capture complete: %0d samples written to audio_dest_dut_output.txt", audio_capture_count);

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

    //--------------------------------------------------------------------------
    // iq_ppdma i_out/q_out synchronization check -- added to test, under
    // REAL system-level backpressure timing (driven by the actual aa_lpf/
    // freq_corr stall pattern, not synthetic stimulus), whether i_out and
    // q_out always transfer on the same cycle. iq_ppdma.cpp's own header
    // comment flags this as never actually confirmed ("worth confirming
    // in cosim that both words really arrive on the same beat"), and nothing
    // else in this project's verification exercises it: csim can't (no
    // tready in the C-level signature), there's no evidence cosim's default
    // stimulus drives i_out_tready/q_out_tready independently, and
    // tb_fm_demod_chain.sv bypasses iq_ppdma entirely. This closes that gap
    // using the SAME PS-VIP-driven simulation already confirmed working
    // for everything else in this file, rather than a separate synthetic
    // testbench with artificial stalling.
    //
    // VERIFY: hierarchical signal names below follow the same _TVALID/
    // _TREADY (uppercase, no .inst) convention already empirically
    // confirmed working for aa_lpf_I/aa_lpf_Q elsewhere in this file --
    // but that was confirmed for aa_lpf specifically, not iq_ppdma. If
    // elaboration can't find these signals, check the actual hierarchy
    // in the waveform viewer's scope browser and adjust.
    //--------------------------------------------------------------------------
    int unsigned iq_n_i_transfers    = 0;
    int unsigned iq_n_q_transfers    = 0;
    int unsigned iq_n_desync_events  = 0;
    int unsigned iq_n_matched_pairs  = 0;

    always_ff @(posedge `PS_CLK) begin
        automatic bit i_xfer = dut.sdr_fm_receiver_i.iq_ppdma_0.i_out_TVALID &&
                                dut.sdr_fm_receiver_i.iq_ppdma_0.i_out_TREADY;
        automatic bit q_xfer = dut.sdr_fm_receiver_i.iq_ppdma_0.q_out_TVALID &&
                                dut.sdr_fm_receiver_i.iq_ppdma_0.q_out_TREADY;

        // No explicit reset gate needed here (unlike tb_fm_demod_chain.sv,
        // this file's DUT has an empty top-level port list -- no
        // aresetn_0 wire exists to gate on). i_xfer/q_xfer are 2-state
        // `bit`, so any X on the underlying signals before iq_ppdma_0 is
        // genuinely out of reset just collapses to 0 automatically --
        // safe to count unconditionally from the start.
        if (i_xfer) iq_n_i_transfers++;
        if (q_xfer) iq_n_q_transfers++;

        if (i_xfer ^ q_xfer) begin
            iq_n_desync_events++;
            $display("*** IQ DESYNC at t=%0t: i_xfer=%0d q_xfer=%0d -- ONE transferred without the other ***",
                      $time, i_xfer, q_xfer);
        end

        if (i_xfer && q_xfer) begin
            iq_n_matched_pairs++;
        end
    end

    //--------------------------------------------------------------------------
    // audio_ppdma freeze diagnostic -- added because audio_ppdma's active_buf
    // was found stuck from essentially the very first baseline reading
    // (t=2051025 ns), never toggling again, while iq_ppdma made real partial
    // progress (2673 i_out/q_out transfers -- more than one full
    // IQ_BUF_SIZE_WORDS buffer) before also going quiet. The isolated
    // fm_demod-only chain test (no iq_ppdma, no audio_ppdma) ran clean with
    // real dynamic audio and no hangs using the SAME internal aa_lpf/
    // freq_corr/nco fixes -- so whatever's freezing is specific to
    // audio_ppdma itself, or to real PS/DDR arbitration timing its own
    // header comment explicitly flagged as never confirmed:
    //   "worst case is on the order of a few hundred AXI beats --
    //    comfortably inside the 2000-cycle inter-sample budget ON PAPER,
    //    but confirm with cosim/timing closure under real DDR/PS
    //    arbitration before relying on it in silicon."
    //
    // Logs every CHANGE (not every cycle -- would be far too verbose) of:
    //   - sample_TVALID/sample_TREADY: is fm_demod still producing
    //     (tvalid pulsing) while audio_ppdma just isn't accepting (tready
    //     stuck low)? Or has tvalid itself gone quiet -- meaning the real
    //     stall is upstream in fm_demod, contradicting the isolated test?
    //   - ap_idle/ap_done: stuck mid-invocation (never reaching ap_done,
    //     consistent with hanging inside the burst-copy read_loop/
    //     write_loop) vs. stuck idle (odd, given ap_start is tied
    //     permanently high and should immediately re-trigger from idle).
    //   - cur_buf/widx: frozen partway through a burst copy would show
    //     widx stuck at some value between 1 and 49, not 0.
    //
    // VERIFY: signal names follow the same conventions already confirmed
    // elsewhere in this session -- axis ports get _TVALID/_TREADY
    // (confirmed for aa_lpf_I/Q, iq_ppdma_0's i_out/q_out), ap_ctrl_hs
    // control signals keep their standard bare names (confirmed via
    // bd.tcl's ap_start wiring). cur_buf/widx are a genuine guess at this
    // point -- HLS-generated internal register names for plain `static`
    // variables aren't something this session has confirmed yet; if
    // elaboration can't find dut.sdr_fm_receiver_i.audio_ppdma_0.cur_buf
    // or .widx specifically, check the actual hierarchy in the waveform
    // scope browser (everything else in this block should still compile
    // and run even if those two specific lines need adjusting).
    //--------------------------------------------------------------------------
    // cur_buf/widx dropped -- confirmed at elaboration they don't exist
    // under those literal names (Vitis HLS commonly renames/merges
    // internal static-variable registers during synthesis in ways that
    // don't preserve the C-level name). The four remaining signals
    // already answer the core question on their own: is fm_demod still
    // producing (tvalid pulsing) while audio_ppdma refuses to accept, or
    // has tvalid itself gone quiet, or is audio_ppdma stuck mid-
    // invocation (ap_idle never returning)?
    bit    ap_prev_sample_tvalid, ap_prev_sample_tready, ap_prev_idle, ap_prev_done;
    bit    ap_prev_active_buf;
    bit    ap_probe_first = 1'b1;
    integer ap_active_buf_toggle_count = 0;

    // active_buf tracked hierarchically, bypassing GPIO/software entirely --
    // added because 744 real, cleanly-handshaked sample transfers were
    // confirmed accepted by audio_ppdma (matching every de_emph_0 tvalid
    // pulse exactly), yet the GPIO-visible active_buf never showed a
    // toggle across the whole run. This settles whether that's a genuine
    // bug in audio_ppdma's own widx/cur_buf counting logic (this
    // hierarchical read would ALSO never toggle), or an artifact
    // specific to the GPIO/software monitoring path (this read WOULD
    // toggle even though the GPIO-based watchdog never caught it).
    always_ff @(posedge `PS_CLK) begin
        automatic bit cur_tvalid    = dut.sdr_fm_receiver_i.audio_ppdma_0.sample_TVALID;
        automatic bit cur_tready    = dut.sdr_fm_receiver_i.audio_ppdma_0.sample_TREADY;
        automatic bit cur_idle      = dut.sdr_fm_receiver_i.audio_ppdma_0.ap_idle;
        automatic bit cur_done      = dut.sdr_fm_receiver_i.audio_ppdma_0.ap_done;
        automatic bit cur_activebuf = dut.sdr_fm_receiver_i.audio_ppdma_0.active_buf;

        if (cur_activebuf != ap_prev_active_buf && !ap_probe_first) begin
            ap_active_buf_toggle_count++;
            $display("*** [audio_ppdma@%0t] HIERARCHICAL active_buf TOGGLED: %0d -> %0d (toggle #%0d) -- compare against GPIO-visible audio_prev in the watchdog log around this same timestamp ***",
                      $time, ap_prev_active_buf, cur_activebuf, ap_active_buf_toggle_count);
        end

        if (ap_probe_first ||
            cur_tvalid != ap_prev_sample_tvalid || cur_tready != ap_prev_sample_tready ||
            cur_idle   != ap_prev_idle           || cur_done   != ap_prev_done) begin

            $display("[audio_ppdma@%0t] sample_tvalid=%0d sample_tready=%0d ap_idle=%0d ap_done=%0d active_buf=%0d",
                      $time, cur_tvalid, cur_tready, cur_idle, cur_done, cur_activebuf);

            ap_prev_sample_tvalid = cur_tvalid;
            ap_prev_sample_tready = cur_tready;
            ap_prev_idle          = cur_idle;
            ap_prev_done          = cur_done;
            ap_probe_first        = 1'b0;
        end
        ap_prev_active_buf = cur_activebuf;
    end


    //--------------------------------------------------------------------------
    // iq_ppdma freeze diagnostic -- added because the desync-check total
    // (2673 matched pairs) stopped increasing well before the run ended,
    // meaning iq_ppdma itself went quiet too -- not just audio_ppdma. The
    // audio_ppdma probe above already showed audio_ppdma correctly idle
    // and ready (sample_tready=1) the whole time, waiting for data that
    // never arrives -- so the real stall is upstream, and this is the
    // next place to look: is iq_ppdma stuck waiting on a real m_axi_gmem
    // AXI4 response that never comes back (a genuine DDR/PS arbitration
    // issue), or stuck in its own control FSM (ap_idle/ap_done pattern
    // wrong) for some other reason?
    //
    // Tracks: ap_idle/ap_done (control FSM state) and the full m_axi_gmem
    // AXI4 read address/data channel (ARVALID/ARREADY/RVALID/RREADY) --
    // if ARVALID sits high with ARREADY never following, the PS VIP isn't
    // accepting a new read address; if ARREADY fires but RVALID never
    // follows, the read data never comes back; if neither channel shows
    // any activity at all, iq_ppdma isn't even attempting a new read,
    // pointing back at its own control logic instead.
    //--------------------------------------------------------------------------
    bit ap_prev_iq_idle, ap_prev_iq_done;
    bit ap_prev_arvalid, ap_prev_arready, ap_prev_rvalid, ap_prev_rready;
    bit ap_probe_iq_first = 1'b1;

    always_ff @(posedge `PS_CLK) begin
        automatic bit cur_idle    = dut.sdr_fm_receiver_i.iq_ppdma_0.ap_idle;
        automatic bit cur_done    = dut.sdr_fm_receiver_i.iq_ppdma_0.ap_done;
        automatic bit cur_arvalid = dut.sdr_fm_receiver_i.iq_ppdma_0.m_axi_gmem_ARVALID;
        automatic bit cur_arready = dut.sdr_fm_receiver_i.iq_ppdma_0.m_axi_gmem_ARREADY;
        automatic bit cur_rvalid  = dut.sdr_fm_receiver_i.iq_ppdma_0.m_axi_gmem_RVALID;
        automatic bit cur_rready  = dut.sdr_fm_receiver_i.iq_ppdma_0.m_axi_gmem_RREADY;

        if (ap_probe_iq_first ||
            cur_idle != ap_prev_iq_idle || cur_done != ap_prev_iq_done ||
            cur_arvalid != ap_prev_arvalid || cur_arready != ap_prev_arready ||
            cur_rvalid  != ap_prev_rvalid  || cur_rready  != ap_prev_rready) begin

            $display("[iq_ppdma@%0t] ap_idle=%0d ap_done=%0d  ARVALID=%0d ARREADY=%0d  RVALID=%0d RREADY=%0d",
                      $time, cur_idle, cur_done, cur_arvalid, cur_arready, cur_rvalid, cur_rready);

            ap_prev_iq_idle  = cur_idle;
            ap_prev_iq_done  = cur_done;
            ap_prev_arvalid  = cur_arvalid;
            ap_prev_arready  = cur_arready;
            ap_prev_rvalid   = cur_rvalid;
            ap_prev_rready   = cur_rready;
            ap_probe_iq_first = 1'b0;
        end
    end

    // fm_demod-internal probe (freq_corr_0.out_ready / nco_0.dds_tready /
    // aa_lpf_I.ap_idle+ap_done) REMOVED for now -- the fm_demod_i guess
    // for the nested block-design wrapper name was wrong (confirmed at
    // elaboration: 'fm_demod_i' is not declared under 'fm_demod_0'), and
    // finding the real path isn't urgent right now given audio_ppdma was
    // just confirmed alive (not frozen) -- the more useful next
    // experiment is simply giving the real, correctly-backpressured
    // system enough time to see if it completes on its own (see the
    // AUDIO_HANG_TIMEOUT_NS/IQ_HANG_TIMEOUT_NS/TEST_DURATION_NS bump
    // above). Revisit this probe, with the real hierarchy confirmed via
    // the waveform scope browser under dut.sdr_fm_receiver_i.fm_demod_0
    // rather than another guess, only if that longer run still hangs.

    //--------------------------------------------------------------------------
    // Downstream-stage probes: fm_disc_0 / fir_dec_0 / audio_lpf_0 / de_emph_0
    //
    // freq_corr_0/aa_lpf_I/aa_lpf_Q/nco_0 are all independently confirmed
    // fixed and correctly passing 100% of accepted input (isolated
    // fm_demod-only chain test). iq_ppdma's handoff into freq_corr_0 is
    // now also confirmed clean (57390 real transfers, 0 desync, this same
    // 152ms run). That leaves these four stages as the only genuinely
    // unverified territory -- the isolated test's earlier success doesn't
    // clear them, because before aa_lpf/freq_corr were fixed, these
    // stages were themselves starved and never actually exercised under
    // sustained, real, bursty throughput.
    //
    // Correct hierarchy prefix confirmed via the Scope pane (screenshot):
    //   dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i.<subblock>
    // (an extra .inst level beyond the earlier wrong guess -- same
    // pattern already seen for zynq_ultra_ps_e_0, now also confirmed for
    // a user-packaged IP, not just Xilinx's own VIP models).
    //
    // Per-block confidence, since each guess risks another slow
    // elaborate-fail-reflash cycle if wrong:
    //   fm_disc_0   : HIGH   -- disc_out_TVALID/TREADY already empirically
    //                           confirmed working in the isolated
    //                           fm_demod-only chain test, same instance
    //                           name, just the corrected prefix here.
    //   de_emph_0   : MEDIUM -- confirmed VHDL (audio_ppdma.h's own
    //                           comment references de_emph.vhd), and its
    //                           output is known to map directly to
    //                           fm_demod's top-level m_axis_data_0 port,
    //                           so m_axis_data_tvalid/tready is a
    //                           reasoned guess at carrying that same name
    //                           through, not a confirmed one.
    //   fir_dec_0   : LOWER  -- confirmed VHDL (fir_dec.vhd, from the
    //                           original archive's fir_decimation/
    //                           directory), but no prior probe of any
    //                           kind to anchor a guess against.
    //   audio_lpf_0 : LOWER  -- confirmed HLS-style icon in the Scope
    //                           tree, presumed to mirror aa_lpf's own
    //                           x/y argument naming (same 127-tap FIR
    //                           architecture family) but never confirmed.
    //
    // If any one of these four elaboration-fails, comment out just that
    // block (each is self-contained) rather than the whole section.
    //--------------------------------------------------------------------------
    localparam string FMD = "dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i";

    bit ap_prev_fmdisc_tvalid, ap_prev_fmdisc_tready;
    bit ap_probe_fmdisc_first = 1'b1;
    always_ff @(posedge `PS_CLK) begin
        automatic bit cur_tvalid = dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i.fm_disc_0.disc_out_TVALID;
        automatic bit cur_tready = dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i.fm_disc_0.disc_out_TREADY;
        if (ap_probe_fmdisc_first || cur_tvalid != ap_prev_fmdisc_tvalid || cur_tready != ap_prev_fmdisc_tready) begin
            $display("[fm_disc_0@%0t] disc_out_tvalid=%0d disc_out_tready=%0d", $time, cur_tvalid, cur_tready);
            ap_prev_fmdisc_tvalid = cur_tvalid;
            ap_prev_fmdisc_tready = cur_tready;
            ap_probe_fmdisc_first = 1'b0;
        end
    end

    bit ap_prev_deemph_tvalid;
    bit ap_probe_deemph_first = 1'b1;
    always_ff @(posedge `PS_CLK) begin
        automatic bit cur_tvalid = dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i.de_emph_0.m_axis_data_tvalid;
        if (ap_probe_deemph_first || cur_tvalid != ap_prev_deemph_tvalid) begin
            $display("[de_emph_0@%0t] m_axis_data_tvalid=%0d (no tready on this port -- confirmed at elaboration)", $time, cur_tvalid);
            ap_prev_deemph_tvalid = cur_tvalid;
            ap_probe_deemph_first = 1'b0;
        end
    end

    bit ap_prev_firdec_tvalid;
    bit ap_probe_firdec_first = 1'b1;
    always_ff @(posedge `PS_CLK) begin
        automatic bit cur_tvalid = dut.sdr_fm_receiver_i.fm_demod_0.inst.fm_demod_i.fir_dec_0.m_axis_data_tvalid;
        if (ap_probe_firdec_first || cur_tvalid != ap_prev_firdec_tvalid) begin
            $display("[fir_dec_0@%0t] m_axis_data_tvalid=%0d (no tready on this port -- confirmed at elaboration)", $time, cur_tvalid);
            ap_prev_firdec_tvalid = cur_tvalid;
            ap_probe_firdec_first = 1'b0;
        end
    end

    // audio_lpf_0 probe removed -- y_TVALID/y_TREADY guess (mirroring
    // aa_lpf's exact x/y naming) was wrong, confirmed at elaboration.
    // Not worth a third guess right now: fm_disc_0 (tvalid+tready) plus
    // de_emph_0/fir_dec_0 (tvalid) already bracket audio_lpf_0 on both
    // sides -- if the stall shows up between fir_dec_0 staying healthy
    // and de_emph_0 going quiet, that already implicates audio_lpf_0 (or
    // the fir_dec_0->audio_lpf_0->de_emph_0 handoffs) by elimination,
    // without needing a direct probe on it.

    final begin
        $display("========================================================");
        $display("=== audio_ppdma hierarchical active_buf check ===");
        $display("  Hierarchical active_buf toggles observed : %0d", ap_active_buf_toggle_count);
        if (ap_active_buf_toggle_count == 0) begin
            $display("  VERDICT: active_buf genuinely never toggles at the RTL level,");
            $display("           despite confirmed clean sample acceptance -- real bug in");
            $display("           audio_ppdma's own widx/cur_buf counting logic.");
        end else begin
            $display("  VERDICT: active_buf DOES toggle at the RTL level -- the GPIO-based");
            $display("           watchdog/capture path is missing it. Testbench monitoring");
            $display("           artifact, not a hardware bug -- check GPIO wiring/polling,");
            $display("           not audio_ppdma itself.");
        end
        $display("========================================================");
        $display("========================================================");
        $display("=== iq_ppdma i_out/q_out synchronization check (real SoC sim) ===");
        $display("  Matched I/Q pairs transferred : %0d", iq_n_matched_pairs);
        $display("  Total i_out transfers         : %0d", iq_n_i_transfers);
        $display("  Total q_out transfers         : %0d", iq_n_q_transfers);
        $display("  DESYNC events                 : %0d", iq_n_desync_events);
        if (iq_n_desync_events == 0) begin
            $display("  VERDICT: i_out and q_out ALWAYS transferred together under real timing.");
        end else begin
            $display("  VERDICT: CONFIRMED desync -- %0d event(s) under real backpressure.", iq_n_desync_events);
        end
        $display("========================================================");
    end

endmodule