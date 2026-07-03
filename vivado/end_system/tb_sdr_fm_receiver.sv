`timescale 1ns / 1ps
`define PS7 dut.sdr_fm_receiver_i.processing_system7_0.inst

module tb_sdr_fm_receiver;
    parameter [31:0] DMA_BASE = 32'h4040_0000;
    parameter [31:0] MM2S_DMACR = 32'h00, MM2S_DMASR = 32'h04, MM2S_SA = 32'h18, MM2S_LENGTH = 32'h28;
    parameter [31:0] S2MM_DMACR = 32'h30, S2MM_DMASR = 32'h34, S2MM_DA = 32'h48, S2MM_LENGTH = 32'h58;
    parameter [31:0] DMACR_RUN = 32'h0000_0001, DMACR_RESET = 32'h0000_0004;
    parameter [31:0] DMASR_IDLE = 32'h0000_0002, DMASR_ERR = 32'h0000_4000;
    parameter [31:0] IQ_BUF_ADDR = 32'h1000_0000, AUDIO_BUF_ADDR = 32'h1010_0000;
    parameter integer FRAME_SAMPLES = 4095, FRAME_BYTES = 16380, POLL_INTERVAL = 1000, POLL_MAX = 100;
    parameter integer TLAST_TARGET = 10;

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

    reg [1023:0] wide_data; reg [31:0] gp0_resp, rdata, packed_iq; reg mm2s_ok, s2mm_ok;
    integer i, n_nonzero; real angle;

    // gp0_write/gp0_read/hp0_write/hp0_read are "automatic" so each call
    // gets its OWN private copy of the scratch temp vars below, instead of
    // sharing module-level regs. That's what makes it safe for the two
    // forked tasks further down to call these concurrently - no shared
    // state, no race, no mutex needed.
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
    // MM2S: arm once, then keep re-arming/polling forever in the
    // background so audio keeps streaming. Bounded poll loop per frame,
    // printing every iteration, same style as the original testbench.
    // ------------------------------------------------------------------
    integer mm2s_frame_count;
    task automatic mm2s_loop;
        reg [31:0] status;
        integer poll_cnt;
        begin
            mm2s_frame_count = 0;
            forever begin
                gp0_write(DMA_BASE + MM2S_DMACR, DMACR_RUN);
                gp0_write(DMA_BASE + MM2S_SA, IQ_BUF_ADDR);
                gp0_write(DMA_BASE + MM2S_LENGTH, FRAME_BYTES);

                mm2s_ok = 0;
                for (poll_cnt = 0; poll_cnt < POLL_MAX && !mm2s_ok; poll_cnt = poll_cnt + 1) begin
                    repeat (POLL_INTERVAL) @(posedge `PS7.FCLK_CLK0);
                    gp0_read(DMA_BASE + MM2S_DMASR, status);
                    $display("  [MM2S] frame %0d DMASR = 0x%08x (poll %0d)", mm2s_frame_count, status, poll_cnt);
                    if (status & DMASR_IDLE) mm2s_ok = 1;
                    if (status & DMASR_ERR) begin $error("MM2S Error!"); $finish; end
                end

                if (!mm2s_ok) begin
                    $error("MM2S: frame %0d timed out waiting for IDLE.", mm2s_frame_count);
                    $finish;
                end

                mm2s_frame_count = mm2s_frame_count + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // S2MM: arm, poll to completion (bounded, printing), count that as one
    // tlast, read back a sample of audio, repeat. After TLAST_TARGET
    // completions, print PASS/FAIL and end the sim.
    // ------------------------------------------------------------------
    integer tlast_count;
    task automatic s2mm_loop;
        reg [31:0] status;
        integer poll_cnt, j;
        begin
            tlast_count = 0;
            while (tlast_count < TLAST_TARGET) begin
                gp0_write(DMA_BASE + S2MM_DMACR, DMACR_RUN);
                gp0_write(DMA_BASE + S2MM_DA, AUDIO_BUF_ADDR);
                gp0_write(DMA_BASE + S2MM_LENGTH, FRAME_BYTES);

                s2mm_ok = 0;
                for (poll_cnt = 0; poll_cnt < POLL_MAX && !s2mm_ok; poll_cnt = poll_cnt + 1) begin
                    repeat (POLL_INTERVAL) @(posedge `PS7.FCLK_CLK0);
                    gp0_read(DMA_BASE + S2MM_DMASR, status);
                    $display("  [S2MM] tlast %0d DMASR = 0x%08x (poll %0d)", tlast_count, status, poll_cnt);
                    if (status & DMASR_IDLE) s2mm_ok = 1;
                    if (status & DMASR_ERR) begin $error("S2MM Error!"); $finish; end
                end

                if (!s2mm_ok) begin
                    $error("S2MM: timed out waiting for tlast %0d.", tlast_count);
                    $finish;
                end

                tlast_count = tlast_count + 1;
                $display("[S2MM] tlast #%0d received.", tlast_count);
            end

            $display("Checking audio output..."); n_nonzero = 0;
            for (j = 0; j < 32; j = j + 1) begin
                hp0_read(AUDIO_BUF_ADDR + (j * 4), rdata);
                if (rdata !== 32'h0) n_nonzero = n_nonzero + 1;
                $display("  audio[%0d] = 0x%08x (%0d)", j, rdata, $signed(rdata));
            end

            $display("==================================================");
            if (n_nonzero > 0) $display(" PASS: Received %0d S2MM tlast events. Non-zero count: %0d", tlast_count, n_nonzero);
            else $error(" FAIL: All samples read back as zero.");
            $display("==================================================");
            #1000; $finish;
        end
    endtask

    initial begin
        $display("=== SDR FM Receiver Testbench ===");
        mm2s_ok = 0; s2mm_ok = 0;
        ps_porb_drv = 1'b0; ps_srstb_drv = 1'b0; #100;
        ps_porb_drv = 1'b1; ps_srstb_drv = 1'b1; #200;

        $display("Executing PS7 soft reset...");
        `PS7.fpga_soft_reset(4'hF); repeat (16) @(posedge `PS7.FCLK_CLK0);
        `PS7.fpga_soft_reset(4'h0); repeat (5000) @(posedge `PS7.FCLK_CLK0);

        $display("Resetting DMA Controllers...");
        gp0_write(DMA_BASE + MM2S_DMACR, DMACR_RESET);
        gp0_write(DMA_BASE + S2MM_DMACR, DMACR_RESET);

        rdata = 32'h0000_0004; while (rdata & 32'h0000_0004) begin repeat (50) @(posedge `PS7.FCLK_CLK0); gp0_read(DMA_BASE + MM2S_DMACR, rdata); end
        rdata = 32'h0000_0004; while (rdata & 32'h0000_0004) begin repeat (50) @(posedge `PS7.FCLK_CLK0); gp0_read(DMA_BASE + S2MM_DMACR, rdata); end
        repeat (200) @(posedge `PS7.FCLK_CLK0);

        `PS7.set_slave_profile("S_AXI_HP0", 2'b00); `PS7.set_slave_profile("ALL", 2'b00);

        $display("Writing I/Q matrix to DDR...");
        // CRITICAL FIX: Changed loop condition to '<=' to pad out the final 64-bit AXI word boundary
        for (i = 0; i <= FRAME_SAMPLES; i = i + 1) begin
            angle = 2.0 * 3.14159265 * i / 250.0;
            packed_iq = {$rtoi(4000.0 * $cos(angle)), $rtoi(4000.0 * $sin(angle))};
            hp0_write(IQ_BUF_ADDR + (i * 4), packed_iq);
        end

        gp0_read(DMA_BASE + MM2S_DMASR, rdata); $display("Pre-Flight MM2S Status: 0x%08x", rdata);
        gp0_read(DMA_BASE + S2MM_DMASR, rdata); $display("Pre-Flight S2MM Status: 0x%08x", rdata);

        $display("Forking MM2S / S2MM tasks...");
        fork
            s2mm_loop();
            mm2s_loop();
        join_none
    end
endmodule