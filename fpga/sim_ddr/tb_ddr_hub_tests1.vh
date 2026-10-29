//============================================================================
// tb_ddr_hub_tests1.vh : helper tasks + H1..H5, included by tb_ddr_hub.v
//============================================================================
integer     t_len  [0:255];
integer     t_dst  [0:255];
reg [31:0]  t_seed [0:255];

//----------------------------------------------------------------- DDR region check
task chk_region;
    input [31:0] dst;
    input [31:0] len;
    input [31:0] seed;
    input integer tag;
    integer k, w, b, cnt;
    reg [31:0] exp, got;
    begin
        cnt = 0;
        for (k = 0; k < (len/4); k = k + 1) begin
            exp = seed ^ k ^ (k << 16);
            w   = (dst + 4*k) >> 5;
            b   = ((dst + 4*k) >> 2) & 7;
            got = ddr_mem[w][b*32 +: 32];
            if (got !== exp) begin
                if (cnt < 6)
                    $display("    chk[%0d] byte %h exp=%h got=%h", tag, dst + 4*k, exp, got);
                cnt = cnt + 1;
                g_err = g_err + 1;
            end
        end
        if (cnt != 0) $display("    chk[%0d] %0d mismatches", tag, cnt);
    end
endtask

//----------------------------------------------------------------- wait helpers
task wait_done_inc;
    input integer inc;
    integer target, tmo;
    begin
        target = st_done + inc;
        tmo = 0;
        while ((st_done < target) && (tmo < 3000000)) begin
            @(posedge pclk); tmo = tmo + 1;
        end
        if (tmo >= 3000000) $display("    wait_done_inc TIMEOUT (done=%0d target=%0d)", st_done, target);
        repeat (20) @(posedge pclk);
    end
endtask

task wait_rbdone_inc;
    input integer inc;
    integer target, tmo;
    begin
        target = st_rbdone + inc;
        tmo = 0;
        while ((st_rbdone < target) && (tmo < 2000000)) begin
            @(posedge pclk); tmo = tmo + 1;
        end
        if (tmo >= 2000000) $display("    wait_rbdone_inc TIMEOUT (rb=%0d target=%0d)", st_rbdone, target);
        repeat (20) @(posedge pclk);
    end
endtask

//----------------------------------------------------------------- command drivers
task host_cmd;
    input [31:0] len;
    input [31:0] seed;
    input [31:0] dst;
    begin
        while (tb_busy) @(posedge pclk);
        @(posedge pclk);
        host_len  = len;
        host_seed = seed;
        host_dst  = dst;
        cmd_finished = 1'b0;
        host_pend = 1'b1;
        while (!tb_busy) @(posedge pclk);
        host_pend = 1'b0;
        while (!cmd_finished) @(posedge pclk);
        cmd_finished = 1'b0;
        repeat (5) @(posedge pclk);
    end
endtask

task db_enqueue;
    input [31:0] hosta;
    input [31:0] len;
    input [31:0] dst;
    input [31:0] fid;
    input [31:0] seed;
    begin
        db_seed_q[db_wi % 512] = seed;
        db_len_q [db_wi % 512] = len;
        db_dst_q [db_wi % 512] = dst;
        db_wi = db_wi + 1;
        tap_wr(12'h190, hosta);
        tap_wr(12'h194, len);
        tap_wr(12'h198, dst);
        tap_wr(12'h19C, fid);
    end
endtask

//----------------------------------------------------------------- H1
task test_h1;
    integer e0, fin0;
    begin
        e0   = g_err;
        fin0 = final_seen;
        tap_wr(12'h1A0, 32'h0000_0001);
        tap_wr(12'h1A4, 32'h0001_0000);
        host_cmd(32'd65536, 32'h0000_1001, 32'h0001_0000);
        if (final_seen == fin0) $display("    H1: no final_done_host seen");
        chk_region(32'h0001_0000, 32'd65536, 32'h0000_1001, 1);
        if (g_err == e0) $display("H1 PASS");
        else begin $display("H1 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H2
task test_h2;
    integer e0, rb0, j, cnt;
    reg [127:0] exp_lo, exp_hi;
    begin
        e0  = g_err;
        rb0 = st_rbdone;
        tap_wr(12'h1A8, 32'h0001_0000);
        tap_wr(12'h1AC, 32'd32768);
        tap_wr(12'h1B0, 32'd2048);
        tap_wr(12'h1B4, 32'd1);
        wait_rbdone_inc(1);
        cnt = 0;
        for (j = 0; j < 1024; j = j + 1) begin
            exp_lo = ddr_mem[(32'h0001_0000 >> 5) + j][127:0];
            exp_hi = ddr_mem[(32'h0001_0000 >> 5) + j][255:128];
            if (ram[2048 + 2*j] !== exp_lo) begin
                if (cnt < 6) $display("    H2 ram[%0d] exp=%h got=%h", 2048+2*j, exp_lo, ram[2048+2*j]);
                cnt = cnt + 1;
            end
            if (ram[2048 + 2*j + 1] !== exp_hi) begin
                if (cnt < 6) $display("    H2 ram[%0d] exp=%h got=%h", 2049+2*j, exp_hi, ram[2048+2*j+1]);
                cnt = cnt + 1;
            end
        end
        g_err = g_err + cnt;
        if ((st_rbdone - rb0) != 1) $display("    H2 rb_done delta=%0d", st_rbdone - rb0);
        if ((g_err == e0) && ((st_rbdone - rb0) == 1)) $display("H2 PASS");
        else begin
            $display("H2 FAIL errs=%0d rbdone_delta=%0d", g_err - e0, st_rbdone - rb0);
            g_fail = g_fail + 1;
        end
    end
endtask

//----------------------------------------------------------------- H3
task test_h3;
    integer e0, i;
    begin
        e0 = g_err;
        db_wi = db_ri;
        t_len[0] = 4096;  t_len[1] = 4112;  t_len[2] = 65536; t_len[3] = 256;
        t_len[4] = 8192;  t_len[5] = 32768; t_len[6] = 16384; t_len[7] = 512;
        for (i = 0; i < 8; i = i + 1) begin
            t_seed[i] = 32'h0000_2000 + i;
            t_dst[i]  = 32'h0008_0000 + i*32'h0002_0000;
        end
        for (i = 0; i < 8; i = i + 1)
            db_enqueue(32'h1000_0000 + i*32'h1000, t_len[i], t_dst[i], 100 + i, t_seed[i]);
        wait_done_inc(8);
        for (i = 0; i < 8; i = i + 1)
            chk_region(t_dst[i], t_len[i], t_seed[i], 100 + i);
        if (st_done < 8) begin $display("    H3 done_cnt=%0d < 8", st_done); g_err = g_err + 1; end
        if (st_lastid !== 32'd107) begin
            $display("    H3 last_id=%0d exp=107", st_lastid); g_err = g_err + 1;
        end
        if (g_err == e0) $display("H3 PASS");
        else begin $display("H3 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H4
task test_h4;
    integer e0, wb0, lat, fc0, im0, dn0;
    begin
        e0  = g_err;
        tap_wr(12'h1A0, 32'h0000_0000);          // DDR off
        wb0 = wr_beat_cnt;
        fc0 = final_cnt;
        im0 = imrd_cnt;
        dn0 = st_done;
        host_cmd(32'd2048, 32'h0000_3001, 32'h0002_0000);
        lat = last_final_cyc - last_imrd_cyc;
        $display("    H4 dbg: imrd+%0d final+%0d done+%0d ddr_en=%0d cmt=%0d eng=%0d d0=%h",
                 imrd_cnt-im0, final_cnt-fc0, st_done-dn0, o_stat1d0[1], st_cmt, st_eng, o_stat1d0);
        if (final_cnt <= fc0) begin
            $display("    H4 FAIL no final_done_host pulse");
            g_err = g_err + 1;
        end
        if (wr_beat_cnt != wb0) begin
            $display("    H4 FAIL DDR write beats=%0d exp=0", wr_beat_cnt - wb0);
            g_err = g_err + 1;
        end
        if ((lat < 0) || (lat > 3)) begin
            $display("    H4 FAIL final_done latency=%0d (exp 0..3)", lat);
            g_err = g_err + 1;
        end
        if (g_err == e0) $display("H4 PASS (final latency=%0d cyc)", lat);
        else begin $display("H4 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask

//----------------------------------------------------------------- H5
task test_h5;
    integer i, e0, push0, ovf0, push_add, ovf_add, exp_ovf, push_now, ovf_now;
    integer hlen, hdst;
    begin
        e0 = g_err;
        tap_wr(12'h1A0, 32'h0000_0001);          // DDR on
        db_wi  = db_ri;
        push0  = st_push;
        ovf0   = st_ovf;
        db_pause = 1'b1;
        for (i = 0; i < 18; i = i + 1) begin
            hlen = 256 + 16*($urandom_range(700));
            hdst = 32'h001A_0000 + i*32'h0000_4000;
            t_len[i]  = hlen;
            t_dst[i]  = hdst;
            t_seed[i] = 32'h0000_4000 + i;
            db_enqueue(32'h1000_0000 + i*32'h1000, hlen, hdst, 300 + i, t_seed[i]);
        end
        repeat (40) @(posedge pclk);
        push_now = st_push;
        ovf_now  = st_ovf;
        push_add = push_now - push0;
        ovf_add  = ovf_now  - ovf0;
        exp_ovf  = 18 - push_add;
        $display("    H5 pushed=%0d ovf=%0d (expected ovf=%0d)", push_add, ovf_add, exp_ovf);
        if ((push_add + ovf_add) != 18) begin
            $display("    H5 FAIL lost enqueue: push+ovf=%0d", push_add + ovf_add); g_err = g_err + 1;
        end
        if ((ovf_add != exp_ovf) || (push_add < 16) || (push_add > 17)) begin
            $display("    H5 FAIL ovf/push out of range"); g_err = g_err + 1;
        end
        db_pause = 1'b0;
        wait_done_inc(push_add);
        for (i = 0; i < push_add; i = i + 1)
            chk_region(t_dst[i], t_len[i], t_seed[i], 300 + i);
        db_wi = db_ri;
        if (g_err == e0) $display("H5 PASS");
        else begin $display("H5 FAIL errs=%0d", g_err - e0); g_fail = g_fail + 1; end
    end
endtask
