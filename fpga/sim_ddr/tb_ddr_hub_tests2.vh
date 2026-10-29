//============================================================================
// tb_ddr_hub_tests2.vh : H6..H9 + main stimulus, included by tb_ddr_hub.v
//============================================================================
integer mi;

//----------------------------------------------------------------- 16-byte markers
task set_marker16;
    input [31:0] ba;
    input [7:0]  val;
    integer i;
    begin
        for (i = 0; i < 16; i = i + 1)
            ddr_mem[(ba+i)>>5][((ba+i)&31)*8 +: 8] = val;
    end
endtask

task chk_marker16;
    input [31:0] ba;
    input [7:0]  val;
    input integer tag;
    integer i;
    reg [7:0] got;
    begin
        for (i = 0; i < 16; i = i + 1) begin
            got = ddr_mem[(ba+i)>>5][((ba+i)&31)*8 +: 8];
            if (got !== val) begin
                $display("    H6 marker[%0d] byte %h exp=%h got=%h", tag, ba+i, val, got);
                g_err = g_err + 1;
            end
        end
    end
endtask

//----------------------------------------------------------------- H6
task test_h6;
    integer e0;
    begin
        e0 = g_err;
        set_marker16(32'h0002_0000, 8'hA5);
        set_marker16(32'h0002_1010, 8'h5A);
        db_wi  = db_ri;
        t_len[0] = 4096;
        t_dst[0] = 32'h0002_0010;
        t_seed[0]= 32'h0000_5001;
        db_enqueue(32'h1000_0000, 4096, 32'h0002_0010, 400, t_seed[0]);
        wait_done_inc(1);
        chk_region(32'h0002_0010, 4096, t_seed[0], 400);
        chk_marker16(32'h0002_0000, 8'hA5, 1);
        chk_marker16(32'h0002_1010, 8'h5A, 2);
        if (g_err == e0) $display("H6 PASS");
        else begin $display("H6 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H7
task test_h7;
    integer i, e0, off, rbase;
    begin
        e0 = g_err;
        GAP = 15; split_en = 1'b1; swap_en = 1'b1; mrd_ngap = 1'b0;
        db_wi = db_ri;
        hold_seen = 1'b0;
        for (i = 0; i < 20; i = i + 1) begin
            if      ((i % 3) == 0) off = 32'h0;
            else if ((i % 3) == 1) off = 32'h80;
            else                   off = 32'h10;
            rbase = 32'h0004_0000 + i*32'h0001_0200;
            t_len[i]  = 256 + 16*($urandom_range(4080));
            t_dst[i]  = rbase + off;
            t_seed[i] = 32'h0000_7000 + i;
        end
        // 20 > doorbell queue depth (16): enqueue in waves so none are dropped
        for (i = 0; i < 10; i = i + 1)
            db_enqueue(32'h1000_0000 + i*32'h1000, t_len[i], t_dst[i], 500 + i, t_seed[i]);
        wait_done_inc(10);
        for (i = 10; i < 20; i = i + 1)
            db_enqueue(32'h1000_0000 + i*32'h1000, t_len[i], t_dst[i], 500 + i, t_seed[i]);
        wait_done_inc(10);
        for (i = 0; i < 20; i = i + 1)
            chk_region(t_dst[i], t_len[i], t_seed[i], 500 + i);
        if (!hold_seen) begin $display("    H7 FAIL issue_hold never seen"); g_err = g_err + 1; end
        if (st_wfovf)   begin $display("    H7 FAIL wfifo_ovf=1"); g_err = g_err + 1; end
        if (st_rfovf)   begin $display("    H7 FAIL rfifo_ovf=1"); g_err = g_err + 1; end
        if (st_cfovf)   begin $display("    H7 FAIL cfifo_ovf=1"); g_err = g_err + 1; end
        db_wi = db_ri;
        if (g_err == e0) $display("H7 PASS");
        else begin $display("H7 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H8
task test_h8;
    integer e0, C, N, wb0, bs0;
    real    ratio;
    begin
        e0 = g_err;
        GAP = 0; split_en = 1'b0; swap_en = 1'b0; mrd_ngap = 1'b1;
        db_wi = db_ri;
        h8_arm = 1'b0; h8_started = 1'b0; h8_n = 0; h8_first = 0; h8_last = 0;
        wb0 = wr_beat_cnt;
        bs0 = st_bursts;
        hold_rise = 0; hold_cyc = 0;
        t_len[0]  = 65536;
        t_dst[0]  = 32'h001C_0000;
        t_seed[0] = 32'h0000_8001;
        h8_arm = 1'b1;
        db_enqueue(32'h1000_0000, 65536, 32'h001C_0000, 600, t_seed[0]);
        wait_done_inc(1);
        repeat (20) @(posedge pclk);
        h8_arm = 1'b0;
        C = h8_last - h8_first;
        N = h8_n;
        ratio = C*1.0 / N;
        $display("    H8 C=%0d N=%0d C/N=%0.2f", C, N, ratio);
        $display("    H8 dbg wr_delta=%0d bursts_delta=%0d wfovf=%0d cfovf=%0d wmax=%0d first=%0d last=%0d",
                 wr_beat_cnt-wb0, st_bursts-bs0, st_wfovf, st_cfovf, st_wmax, h8_first, h8_last);
        $display("    H8 dbg hold_rise=%0d hold_cyc=%0d", hold_rise, hold_cyc);
        chk_region(32'h001C_0000, 65536, t_seed[0], 600);
        if (N != 2048) begin $display("    H8 FAIL N=%0d exp=2048", N); g_err = g_err + 1; end
        if (ratio > 3.5) begin $display("    H8 FAIL C/N=%0.2f > 3.5", ratio); g_err = g_err + 1; end
        db_wi = db_ri;
        if (g_err == e0) $display("H8 PASS (C/N=%0.2f)", ratio);
        else begin $display("H8 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H9
task test_h9;
    integer i, e0;
    begin
        e0 = g_err;
        GAP = 15; split_en = 1'b0; swap_en = 1'b0; mrd_ngap = 1'b1;
        tap_wr(12'h1A0, 32'h0000_0003);       // DDR on + clear sticky stats
        db_wi = db_ri;
        hold_seen = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            t_len[i]  = 259200;
            t_dst[i]  = 32'h0004_0080 + i*32'h0004_0000;
            t_seed[i] = 32'h0000_9000 + i;
            db_enqueue(32'h1000_0000 + i*32'h1000, 259200, t_dst[i], 700 + i, t_seed[i]);
        end
        wait_done_inc(4);
        repeat (30) @(posedge pclk);
        for (i = 0; i < 4; i = i + 1)
            chk_region(t_dst[i], t_len[i], t_seed[i], 700 + i);
        if (!hold_seen) begin $display("    H9 FAIL issue_hold never seen"); g_err = g_err + 1; end
        if (st_cfovf)   begin $display("    H9 FAIL cfifo_ovf=1"); g_err = g_err + 1; end
        if (st_wfovf)   begin $display("    H9 FAIL wfifo_ovf=1"); g_err = g_err + 1; end
        db_wi = db_ri;
        if (g_err == e0) $display("H9 PASS");
        else begin $display("H9 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- watchdog
initial begin
    #50_000_000;
    $display("TIMEOUT");
    $display("TESTS FAILED: 1");
    $finish;
end

//----------------------------------------------------------------- main stimulus
initial begin
    i_tap_vld  = 1'b0;
    i_tap_addr = 12'd0;
    i_tap_data = 32'd0;
    GAP = 3; split_en = 1'b1; swap_en = 1'b1; db_pause = 1'b0; mrd_ngap = 1'b0;
    g_err = 0; g_fail = 0; g_conflict = 0; wr_beat_cnt = 0; ddr_cyc = 0;
    hold_seen = 1'b0; final_seen = 1'b0;
    db_wi = 0; db_ri = 0;
    h8_arm = 1'b0; h8_started = 1'b0; h8_n = 0; h8_first = 0; h8_last = 0;
    last_imrd_cyc = 0; last_final_cyc = 0; pclk_cyc = 0; final_cnt = 0; imrd_cnt = 0;
    for (mi = 0; mi < 65536; mi = mi + 1) ddr_mem[mi] = 256'd0;
    for (mi = 0; mi < 4096;  mi = mi + 1) ram[mi]     = 128'd0;

    wait (ddr_init_done === 1'b1);
    repeat (30) @(posedge pclk);

    $display("=== rt_ddr_hub H1-H9 ===");
    test_h1;
    test_h2;
    test_h3;
    test_h4;
    test_h5;
    test_h6;
    test_h7;
    test_h8;
    test_h9;

    if (g_conflict != 0) $display("WARN copy/dma write conflict count=%0d", g_conflict);
    if (g_fail == 0) $display("ALL TESTS PASSED");
    else             $display("TESTS FAILED: %0d", g_fail);
    $finish;
end
