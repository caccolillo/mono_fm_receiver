//------------------------------------------------------------------------------
// tb_fm_demod_chain.sv
// Full-chain behavioral testbench for fm_demod_wrapper.
//
// MODIFIED: feeds I/Q BACK-TO-BACK (as fast as the DUT will accept),
// properly respecting s_axis_i_0_tready / s_axis_q_0_tready, instead of
// the original fixed-400-cycle-gap (paced 250 kHz) feed. The paced
// version proved the chain's decimation ratio is correct at its designed
// input rate (5000 in -> 997 out, ~1/5 as expected) but never actually
// exercised the DUT's tready handshaking at all, since 400 cycles is
// always more than enough time regardless of internal pipeline behavior.
// This is a closer match to how iq_ppdma_0 actually drives this
// interface on real hardware: free-running, back-to-back, no pacing.
// If s_axis_i_0_tready/s_axis_q_0_tready ever go low under this load,
// that's direct proof this input boundary imposes real backpressure and
// isn't the (assumed) always-ready case the paced version implicitly
// tested. Stall-cycle counting added below to make that visible/
// quantifiable rather than just pass/fail.
//
// Drives s_axis_i_0 / s_axis_q_0 with real captured I/Q samples from
// rds.wav (quantised to sfix16_En15 by gen_fm_demod_stimulus.m).
// The on-chip nco_0 (DDS Compiler v6.0, +10 kHz, configured by
// create_nco_sim.tcl) generates its own cos/sin internally -- no
// external NCO stimulus is needed.
//
// Captures m_axis_data_0 (de-emphasis output, sfix32_En13, 50 kHz) to a
// text file of stored integers for MATLAB to read, resample to 48 kHz,
// and play back / compare against the Simulink reference.
//
// NOTE: M_DATA_WIDTH assumed 32 bits (sfix32_En13, matching
// de_emph_0/m_axis_data per its standalone verification). Confirm against
// the actual generated fm_demod_wrapper.v port list before running --
// if the wrapper differs, adjust M_DATA_WIDTH and the port map below.
//
// Clock: 100 MHz (10 ns period), matching every sub-block's aclk.
// NOTE: SAMPLE_RATE / the old 400-cycle gap is now UNUSED for pacing --
// left defined below only because other comments in this file still
// reference it for context; the stimulus loop itself no longer inserts
// any fixed delay between samples.
//
// Marco Aiello, 2024
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_fm_demod_chain;

    localparam time CLK_PERIOD   = 10ns;   // 100 MHz
    localparam int  SAMPLE_RATE  = 400;    // cycles per 250 kHz input sample

    // Input/output widths -- confirm M_DATA_WIDTH against the generated wrapper
    localparam int S_DATA_WIDTH  = 16;     // sfix16_En15, matches TDATA_NUM_BYTES=2
    localparam int M_DATA_WIDTH  = 32;     // sfix32_En13 (de_emph_0 output) -- VERIFY

    // Stimulus / output files
    localparam string I_STIM_FILE    = "s_axis_i_stimulus.txt";
    localparam string Q_STIM_FILE    = "s_axis_q_stimulus.txt";
    localparam string AUDIO_OUT_FILE = "m_axis_data_dut_output.txt";
    localparam string AA_I_LOG_FILE  = "aa_lpf_I_y_dut_output.txt";
    localparam string FM_DISC_LOG_FILE = "fm_disc_disc_out_dut_output.txt";
    localparam string FREQ_CORR_LOG_FILE = "freq_corr_0_m_axis_ic_dut_output.txt";

    // AA_I output: y is sfix18_En17 (18 bits), padded to 24-bit TDATA by
    // HLS's AXI-Stream byte-alignment (see earlier discussion on x_TDATA[23:0]
    // / y_TDATA[23:0] widths). Only the low 18 bits are meaningful; the
    // upper 6 bits are sign-extension padding.
    localparam int AA_I_DATA_WIDTH = 24;
    localparam int AA_I_VALID_BITS = 18;

    // fm_disc output: disc_out is sfix32_En14 (out_t in fm_disc.h), a clean
    // 32-bit width with no AXI-S byte-padding concern (32 bits is already
    // a whole number of bytes), unlike AA_I's 18-into-24 case.
    localparam int FM_DISC_DATA_WIDTH = 32;

    // DUT signals
    logic aclk_0    = 1'b0;
    logic aresetn_0 = 1'b0;

    logic [S_DATA_WIDTH-1:0] s_axis_i_tdata  = '0;
    logic                    s_axis_i_tvalid = 1'b0;
    logic                    s_axis_i_tready;

    logic [S_DATA_WIDTH-1:0] s_axis_q_tdata  = '0;
    logic                    s_axis_q_tvalid = 1'b0;
    logic                    s_axis_q_tready;

    logic [M_DATA_WIDTH-1:0] m_axis_data_tdata;
    logic                    m_axis_data_tvalid;
    // NOTE: m_axis_data_0 has NO tready port on fm_demod_wrapper -- confirmed
    // against the generated wrapper.v. de_emph_0 drives this as a free-running
    // output stream with no downstream backpressure, so there is nothing to
    // connect/drive here.

    // Stimulus done flag, used to know when to stop waiting for output
    bit stim_done = 1'b0;

    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    always #(CLK_PERIOD/2) aclk_0 = ~aclk_0;

    //--------------------------------------------------------------------------
    // Reset
    //--------------------------------------------------------------------------
    initial begin
        aresetn_0 = 1'b0;
        repeat (16) @(posedge aclk_0);
        aresetn_0 = 1'b1;
    end

    //--------------------------------------------------------------------------
    // DUT: instantiate the generated block design wrapper.
    // Port names must match fm_demod_wrapper.v exactly -- adjust this
    // instantiation if the actual generated wrapper differs (e.g. if
    // Vivado names ports m_axis_data_0_tdata vs m_axis_data_tdata).
    //--------------------------------------------------------------------------
    fm_demod_wrapper dut (
        .aclk_0                (aclk_0),
        .aresetn_0              (aresetn_0),

        .s_axis_i_0_tdata       (s_axis_i_tdata),
        .s_axis_i_0_tvalid      (s_axis_i_tvalid),
        .s_axis_i_0_tready      (s_axis_i_tready),

        .s_axis_q_0_tdata       (s_axis_q_tdata),
        .s_axis_q_0_tvalid      (s_axis_q_tvalid),
        .s_axis_q_0_tready      (s_axis_q_tready),

        .m_axis_data_0_tdata    (m_axis_data_tdata),
        .m_axis_data_0_tvalid   (m_axis_data_tvalid)
    );

    //--------------------------------------------------------------------------
    // Stimulus: feed I and Q BACK-TO-BACK, respecting s_axis_i_0_tready /
    // s_axis_q_0_tready like a real AXI-Stream master must -- holding
    // tdata/tvalid stable across any stall cycles rather than firing and
    // forgetting after a fixed delay. This is the closer match to how
    // iq_ppdma_0 actually drives this interface on real hardware.
    //--------------------------------------------------------------------------
    initial begin : stim_proc
        int fd_i, fd_q;
        int vi, vq;
        int code_i, code_q;
        int n_fed;
        longint stall_cycles;
        int this_sample_stalls;

        fd_i = $fopen(I_STIM_FILE, "r");
        fd_q = $fopen(Q_STIM_FILE, "r");
        if (fd_i == 0 || fd_q == 0) begin
            $error("Could not open stimulus files (%s / %s)", I_STIM_FILE, Q_STIM_FILE);
            $finish;
        end

        n_fed = 0;
        stall_cycles = 0;
        wait (aresetn_0 == 1'b1);
        @(posedge aclk_0);

        while (!$feof(fd_i)) begin
            code_i = $fscanf(fd_i, "%d\n", vi);
            code_q = $fscanf(fd_q, "%d\n", vq);
            if (code_i != 1 || code_q != 1) begin
                // EOF or malformed line -- stop feeding
                break;
            end

            s_axis_i_tdata  <= vi[S_DATA_WIDTH-1:0];
            s_axis_q_tdata  <= vq[S_DATA_WIDTH-1:0];
            s_axis_i_tvalid <= 1'b1;
            s_axis_q_tvalid <= 1'b1;

            // Handshake: the transfer completes on the first clock edge
            // where BOTH tready signals sample high while tvalid is
            // asserted. Until then, tdata/tvalid MUST stay held exactly
            // as they are -- this is the part the original fixed-delay
            // version never had to do, since 400 cycles was always more
            // than enough regardless of whether the DUT was really ready.
            this_sample_stalls = 0;
            @(posedge aclk_0);
            while (!(s_axis_i_tready && s_axis_q_tready)) begin
                stall_cycles++;
                this_sample_stalls++;
                @(posedge aclk_0);
            end

            s_axis_i_tvalid <= 1'b0;
            s_axis_q_tvalid <= 1'b0;

            n_fed++;
            if (n_fed % 1000 == 0) begin
                $display("Stimulus progress (back-to-back): sample %0d -- I=%0d Q=%0d  (stall cycles so far: %0d, this sample: %0d)",
                          n_fed, vi, vq, stall_cycles, this_sample_stalls);
            end
        end

        $fclose(fd_i);
        $fclose(fd_q);

        $display("Stimulus complete (back-to-back): %0d I/Q samples fed.", n_fed);
        $display("Total stall cycles: %0d (%0d.%0d avg per sample) -- %s",
                  stall_cycles,
                  (n_fed > 0) ? (stall_cycles / n_fed) : 0,
                  (n_fed > 0) ? ((stall_cycles * 10 / n_fed) % 10) : 0,
                  (stall_cycles == 0) ?
                      "DUT NEVER stalled -- input side accepted everything back-to-back" :
                      "DUT applied real backpressure at least once -- see per-sample stalls above");

        // Allow pipeline to flush through all stages (NCO + FreqCorr + AA LPF
        // x2 + FM disc + FIR dec + Audio LPF + De-emph latencies combined)
        // before declaring stimulus done.
        repeat (5000) @(posedge aclk_0);
        stim_done = 1'b1;
    end

    //--------------------------------------------------------------------------
    // AA_I diagnostic log: capture every VALID sample of aa_lpf_I's output
    // (y_TDATA / y_TVALID), hierarchically referenced into the DUT instance,
    // so the filter's actual output stream can be checked numerically
    // instead of read off the waveform viewer at a single cursor position.
    //
    // Hierarchical path matches what was inspected interactively in the
    // xsim waveform viewer:
    //   /tb_fm_demod_chain/dut/fm_demod_i/aa_lpf_I/y_TDATA
    //   /tb_fm_demod_chain/dut/fm_demod_i/aa_lpf_I/y_TVALID
    //
    // Logs one line per valid sample: "<sample_index> <raw24> <signed18>"
    // where raw24 is the full 24-bit TDATA stored integer (includes the
    // 6 sign-extension padding bits) and signed18 is that value
    // sign-extended/truncated to the meaningful 18-bit sfix18_En17 range
    // -- divide signed18 by 2^17 in MATLAB to get the real value.
    //--------------------------------------------------------------------------
    initial begin : aa_i_log_proc
        int fd_aai;
        int n_logged;
        logic signed [AA_I_DATA_WIDTH-1:0] raw24;
        logic signed [AA_I_VALID_BITS-1:0] sig18;

        fd_aai = $fopen(AA_I_LOG_FILE, "w");
        if (fd_aai == 0) begin
            $error("Could not open AA_I log file: %s", AA_I_LOG_FILE);
            $finish;
        end

        n_logged = 0;
        wait (aresetn_0 == 1'b1);

        forever begin
            @(posedge aclk_0);
            if (dut.fm_demod_i.aa_lpf_I.y_TVALID) begin
                raw24 = dut.fm_demod_i.aa_lpf_I.y_TDATA;
                sig18 = raw24[AA_I_VALID_BITS-1:0];
                $fdisplay(fd_aai, "%0d %0d %0d", n_logged, raw24, sig18);
                n_logged++;
                if (n_logged % 10000 == 0) begin
                    $display("AA_I log progress: %0d samples captured", n_logged);
                end
            end

            if (stim_done) break;
        end

        $fclose(fd_aai);
        $display("AA_I log complete: %0d samples written to %s",
                  n_logged, AA_I_LOG_FILE);
    end

    //--------------------------------------------------------------------------
    // freq_corr_0 OUTPUT handshake diagnostic: added specifically because
    // switching aa_lpf from ap_ctrl_none to ap_ctrl_hs (see aa_lpf.cpp)
    // had ZERO effect on the observed collapse (still 5000 in / 21 AA_I /
    // 2 audio out, byte-identical to before the fix, confirmed on a
    // genuinely fresh rebuild+resim -- not a stale-cache artifact).
    //
    // Realization: the testbench's s_axis_i_0/s_axis_q_0 tready, which
    // showed near-zero stalling throughout every back-to-back run so far,
    // is freq_corr_0's tready, NOT aa_lpf's -- per bd.tcl, s_axis_i_0
    // feeds freq_corr_0 first, and ONLY freq_corr_0's own output feeds
    // aa_lpf. Every prior "input side never stalls" conclusion was really
    // "freq_corr_0 never stalls", which says nothing about whether
    // aa_lpf's (now-fixed) tready is being correctly honored one hop
    // further upstream.
    //
    // This logs EVERY cycle where freq_corr_0/m_axis_ic_tvalid is
    // asserted, regardless of whether m_axis_ic_tready was also high --
    // i.e. it captures both accepted AND rejected beats, unlike the
    // AA_I/fm_disc logs above which only ever record accepted samples.
    // That's the point: if freq_corr_0 is a correct AXI-Stream master,
    // tdata must stay IDENTICAL across any run of consecutive
    // tvalid=1/tready=0 log lines (holding the same not-yet-accepted
    // beat steady). If tdata instead changes between them, that's a
    // direct, unambiguous protocol violation -- freq_corr_0 overwriting
    // presented-but-not-yet-accepted data instead of holding it, which
    // would produce exactly this kind of silent, upstream-of-aa_lpf data
    // loss no matter how correct aa_lpf's own tready handling is.
    //
    // Logs one line per cycle where tvalid=1: "<cycle_index> <tvalid> <tready> <tdata>"
    //--------------------------------------------------------------------------
    initial begin : freq_corr_log_proc
        int fd_fc;
        int n_logged;
        int n_rejected;
        // WIDTH NOTE: freq_corr_0/m_axis_ic_tdata's true native width isn't
        // confirmed here (freq_corr.vhd isn't available to check directly
        // -- same archive gap as fm_disc/). Using AA_I_DATA_WIDTH (24) as a
        // safe upper bound; if the real signal is narrower (plausible,
        // e.g. 18-bit sfix18_En17 before I_adapter pads it for aa_lpf's
        // AXI-S TDATA), this just reads high bits as 0 -- harmless for the
        // tdata-changed-while-rejected check below, which only cares
        // whether consecutive captures differ, not their absolute width.
        logic [AA_I_DATA_WIDTH-1:0] tdata_val;
        logic prev_tready_was_0;
        logic [AA_I_DATA_WIDTH-1:0] prev_tdata_val;

        fd_fc = $fopen(FREQ_CORR_LOG_FILE, "w");
        if (fd_fc == 0) begin
            $error("Could not open freq_corr_0 log file: %s", FREQ_CORR_LOG_FILE);
            $finish;
        end

        n_logged = 0;
        n_rejected = 0;
        prev_tready_was_0 = 1'b0;
        prev_tdata_val = '0;
        wait (aresetn_0 == 1'b1);

        forever begin
            @(posedge aclk_0);
            if (dut.fm_demod_i.freq_corr_0.m_axis_ic_tvalid) begin
                tdata_val = dut.fm_demod_i.freq_corr_0.m_axis_ic_tdata;
                $fdisplay(fd_fc, "%0d %0d %0d %0d",
                          n_logged,
                          dut.fm_demod_i.freq_corr_0.m_axis_ic_tvalid,
                          dut.fm_demod_i.freq_corr_0.m_axis_ic_tready,
                          tdata_val);

                if (!dut.fm_demod_i.freq_corr_0.m_axis_ic_tready) begin
                    n_rejected++;
                    // PROTOCOL CHECK: if the previous logged beat was also
                    // rejected (tready=0), tdata MUST be unchanged from
                    // that previous beat -- a real AXI-Stream master holds
                    // a presented-but-unaccepted beat steady. A mismatch
                    // here is the direct, unambiguous smoking gun.
                    if (prev_tready_was_0 && (tdata_val !== prev_tdata_val)) begin
                        $display("*** PROTOCOL VIOLATION at cycle %0d: freq_corr_0/m_axis_ic changed tdata (0x%0h -> 0x%0h) while tready was LOW across consecutive beats -- master is overwriting rejected data instead of holding it ***",
                                  n_logged, prev_tdata_val, tdata_val);
                    end
                    prev_tready_was_0 = 1'b1;
                end else begin
                    prev_tready_was_0 = 1'b0;
                end
                prev_tdata_val = tdata_val;

                n_logged++;
                if (n_logged % 10000 == 0) begin
                    $display("freq_corr_0 m_axis_ic log progress: %0d beats (%0d rejected so far)",
                              n_logged, n_rejected);
                end
            end

            if (stim_done) break;
        end

        $fclose(fd_fc);
        $display("freq_corr_0 m_axis_ic log complete: %0d total beats, %0d rejected (tvalid=1,tready=0), %0d accepted -- written to %s",
                  n_logged, n_rejected, n_logged - n_rejected, FREQ_CORR_LOG_FILE);
    end

    //--------------------------------------------------------------------------
    // fm_disc diagnostic log: capture every VALID sample of fm_disc_0's
    // output (disc_out_TDATA / disc_out_TVALID), hierarchically referenced
    // into the DUT instance, same approach as the AA_I log above.
    //
    // Hierarchical path matches the instance/port names seen in the block
    // design diagram and waveform viewer:
    //   /tb_fm_demod_chain/dut/fm_demod_i/fm_disc_0/disc_out_TDATA
    //   /tb_fm_demod_chain/dut/fm_demod_i/fm_disc_0/disc_out_TVALID
    //
    // disc_out is sfix32_En14 (out_t in fm_disc.h) -- the FM discriminator's
    // frequency-deviation output in Hz, full 32-bit width, no byte-padding.
    // Logs one line per valid sample: "<sample_index> <signed32>"
    // -- divide signed32 by 2^14 in MATLAB to get the real value in Hz.
    //--------------------------------------------------------------------------
    initial begin : fm_disc_log_proc
        int fd_disc;
        int n_logged;
        logic signed [FM_DISC_DATA_WIDTH-1:0] raw32;

        fd_disc = $fopen(FM_DISC_LOG_FILE, "w");
        if (fd_disc == 0) begin
            $error("Could not open fm_disc log file: %s", FM_DISC_LOG_FILE);
            $finish;
        end

        n_logged = 0;
        wait (aresetn_0 == 1'b1);

        forever begin
            @(posedge aclk_0);
            if (dut.fm_demod_i.fm_disc_0.disc_out_TVALID) begin
                raw32 = dut.fm_demod_i.fm_disc_0.disc_out_TDATA;
                $fdisplay(fd_disc, "%0d %0d", n_logged, raw32);
                n_logged++;
                if (n_logged % 10000 == 0) begin
                    $display("fm_disc log progress: %0d samples captured", n_logged);
                end
            end

            if (stim_done) break;
        end

        $fclose(fd_disc);
        $display("fm_disc log complete: %0d samples written to %s",
                  n_logged, FM_DISC_LOG_FILE);
    end

    //--------------------------------------------------------------------------
    // Capture: log every valid m_axis_data_0 sample as a stored integer
    // (sfix32_En13) to a text file. MATLAB divides by 2^13 on read.
    //--------------------------------------------------------------------------
    initial begin : capture_proc
        int fd_out;
        int n_caught;
        logic signed [M_DATA_WIDTH-1:0] raw_val;

        fd_out = $fopen(AUDIO_OUT_FILE, "w");
        if (fd_out == 0) begin
            $error("Could not open output file: %s", AUDIO_OUT_FILE);
            $finish;
        end

        n_caught = 0;
        wait (aresetn_0 == 1'b1);

        forever begin
            @(posedge aclk_0);
            if (m_axis_data_tvalid) begin
                raw_val = m_axis_data_tdata;
                $fdisplay(fd_out, "%0d", raw_val);
                n_caught++;
                if (n_caught % 10000 == 0) begin
                    $display("Capture progress: %0d audio samples captured", n_caught);
                end
            end

            if (stim_done) break;
        end

        $fclose(fd_out);
        $display("Capture complete: %0d audio samples written to %s",
                  n_caught, AUDIO_OUT_FILE);

        $display("=== TESTBENCH RUN COMPLETE ===");
        $finish;
    end

endmodule
