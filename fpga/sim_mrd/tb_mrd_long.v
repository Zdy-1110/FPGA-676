
`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// 20261018 mrd: long MRd testbench
// instantiates rt0202 / rt0102 / rt0105 / rt0103 / rt_mrd_checker
//////////////////////////////////////////////////////////////////////////////
module tb_mrd_long;

//---------------------------------------------------------------- clock/reset
reg clk;
reg rst_n;

initial begin
    clk = 1'b0;
    forever #4 clk = ~clk;
end

//---------------------------------------------------------------- config
reg [2:0] cfg_max_rd_req_size;
reg [2:0] cfg_max_payload_size;
reg [7:0] cfg_pbus_num;
reg [4:0] cfg_pbus_dev_num;

//---------------------------------------------------------------- rt0202
reg         tx_trdy;
reg         tx_tvld;
reg         tx_tlast;
reg         mrd32_req;
reg         mrd64_req;
wire        mrd32_ack;
wire        mrd64_ack;
reg  [10:0] mem_length;
reg  [63:0] mem_addr;
reg  [19:0] mrd_ext_length;
reg  [5:0]  mrd_max_out;
reg         mrd_abort;
wire        tag_free_vld;
wire [4:0]  tag_free;
wire        tx_mrd_en;
wire [9:0]  mrd_length;
wire [7:0]  mrd_tag;
wire [63:0] mrd_addr;
wire        chunk_wr_en;
wire [4:0]  chunk_wr_tag;
wire [15:0] chunk_wr_idx;
wire        mrd_start;
wire        mrd_done;
wire [31:0] stat_issued;
wire [31:0] stat_freed;
wire [31:0] stat_cycles;
wire [31:0] stat_busy_map;
wire [31:0] stat_word;

//---------------------------------------------------------------- rt0102
wire [63:0] cpld_addr;
reg  [9:0]  cpld_length;
reg  [7:0]  cpld_tag;
reg         cpld_multi;
reg         cpld_data_flag;

//---------------------------------------------------------------- rt0103
reg  [127:0] cpld_data;
reg  [3:0]   cpld_dw_vld;
reg  [11:0]  cpld_byte_cnt;
reg  [6:0]   cpld_low_addr;
reg          cpld_en;
wire         dma_wr_en;
wire [63:0]  dma_wr_addr;
wire [127:0] dma_wr_data;
wire [15:0]  dma_wr_be;
wire [7:0]   cpld_dwbe;

//---------------------------------------------------------------- checker
reg  [31:0]  chk_seed;
wire [191:0] chk_stat;

parameter [31:0] BASE = 32'h001B0000;

//---------------------------------------------------------------- DUTs
rt0202_dma_mrd_ctrl u_mrd
(
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .i_cfg_pbus_num         (cfg_pbus_num           ),
    .i_cfg_pbus_dev_num     (cfg_pbus_dev_num       ),
    .i_cfg_max_rd_req_size  (cfg_max_rd_req_size    ),
    .i_cfg_max_payload_size (cfg_max_payload_size   ),
    .i_axis_slave1_trdy     (tx_trdy                ),
    .i_axis_slave1_tvld     (tx_tvld                ),
    .i_axis_slave1_tlast    (tx_tlast               ),
    .i_mrd32_req            (mrd32_req              ),
    .o_mrd32_req_ack        (mrd32_ack              ),
    .i_mrd64_req            (mrd64_req              ),
    .o_mrd64_req_ack        (mrd64_ack              ),
    .i_mem_length           (mem_length             ),
    .i_mem_addr             (mem_addr               ),
    .i_mrd_ext_length       (mrd_ext_length         ),
    .i_mrd_max_out          (mrd_max_out            ),
    .i_mrd_abort            (mrd_abort              ),
    .i_tag_free_vld         (tag_free_vld           ),
    .i_tag_free             (tag_free               ),
    .o_mrd_start            (mrd_start              ),
    .o_mrd_done             (mrd_done               ),
    .o_stat_issued          (stat_issued            ),
    .o_stat_freed           (stat_freed             ),
    .o_stat_cycles          (stat_cycles            ),
    .o_stat_busy_map        (stat_busy_map          ),
    .o_stat_word            (stat_word              ),
    .o_chunk_wr_en          (chunk_wr_en            ),
    .o_chunk_wr_tag         (chunk_wr_tag           ),
    .o_chunk_wr_idx         (chunk_wr_idx           ),
    .o_tx_mrd_en            (tx_mrd_en              ),
    .o_mrd_length           (mrd_length             ),
    .o_mrd_at               (                       ),
    .o_mrd_attr             (                       ),
    .o_mrd_ep               (                       ),
    .o_mrd_td               (                       ),
    .o_mrd_th               (                       ),
    .o_mrd_tc               (                       ),
    .o_mrd_tlp_type         (                       ),
    .o_mrd_fmt              (                       ),
    .o_mrd_dwbe             (                       ),
    .o_mrd_tag              (mrd_tag                ),
    .o_mrd_requester_id     (                       ),
    .o_mrd_addr             (mrd_addr               ),
    .i_db_req               (1'b0                   ),   // 20261018 ddr:
    .i_db_addr              (32'd0                  ),   // 20261018 ddr:
    .i_db_len_dw            (20'd0                  ),   // 20261018 ddr:
    .o_db_ack               (                       ),   // 20261018 ddr:
    .i_issue_hold           (1'b0                   ),   // 20261018 ddr:
    .i_start_block          (1'b0                   )    // 20261018 ddr:
);

rt0102_dma_cpld_tag_ctrl u_tag
(
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .i_cfg_max_rd_req_size  (cfg_max_rd_req_size    ),
    .i_cfg_max_payload_size (cfg_max_payload_size   ),
    .i_cpld_length          (cpld_length            ),
    .i_cpld_tag             (cpld_tag               ),
    .i_multicpld_flag       (cpld_multi             ),
    .i_cpld_data_flag       (cpld_data_flag         ),
    .i_chunk_wr_en          (chunk_wr_en            ),
    .i_chunk_wr_tag         (chunk_wr_tag           ),
    .i_chunk_wr_idx         (chunk_wr_idx           ),
    .o_cpld_addr            (cpld_addr              )
);

rt0105_cpld_tag_free u_free
(
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .i_cpld_tag             (cpld_tag               ),
    .i_cpld_length          (cpld_length            ),
    .i_cpld_byte_cnt        (cpld_byte_cnt          ),
    .i_cpld_low_addr        (cpld_low_addr          ),
    .i_cpld_en_flag         (cpld_data_flag         ),
    .o_tag_free_vld         (tag_free_vld           ),
    .o_tag_free             (tag_free               )
);

rt0103_dma_data_wr_ctrl u_wr
(
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .i_bar_sel              (3'd1                   ),
    .i_de                   (cpld_en                ),
    .i_length               (cpld_length            ),
    .i_dwbe                 (cpld_dwbe              ),
    .i_data                 (cpld_data              ),
    .i_dw_vld               (cpld_dw_vld            ),
    .i_addr                 (cpld_addr              ),
    .i_data_flag            (cpld_data_flag         ),
    .o_wr_bar_sel           (                       ),
    .o_wr_en                (dma_wr_en              ),
    .o_wr_addr              (dma_wr_addr            ),
    .o_wr_data              (dma_wr_data            ),
    .o_wr_be                (dma_wr_be              )
);

rt_mrd_checker u_chk
(
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .i_start                (mrd_start              ),
    .i_seed                 (chk_seed               ),
    .i_wr_en                (dma_wr_en              ),
    .i_wr_addr              (dma_wr_addr[31:0]      ),
    .i_wr_data              (dma_wr_data            ),
    .i_wr_be                (dma_wr_be              ),
    .o_stat                 (chk_stat               )
);

//---------------------------------------------------------------- dwbe from byte count / low addr (same as rt01_dma_rx)
reg  [3:0] first_dw_be;
reg  [3:0] last_dw_be;
wire [1:0] last_dw_byte_num;

always @(*)
begin
    case(cpld_low_addr[1:0])
        2'd0: first_dw_be = 4'b1111;
        2'd1: first_dw_be = 4'b1110;
        2'd2: first_dw_be = 4'b1100;
        2'd3: first_dw_be = 4'b1000;
        default: first_dw_be = 4'hf;
    endcase
end

assign last_dw_byte_num = cpld_byte_cnt[1:0] + cpld_low_addr[1:0];

always @(*)
begin
    case(last_dw_byte_num)
        2'd0: last_dw_be = 4'b1111;
        2'd1: last_dw_be = 4'b0001;
        2'd2: last_dw_be = 4'b0011;
        2'd3: last_dw_be = 4'b0111;
        default: last_dw_be = 4'hf;
    endcase
end

assign cpld_dwbe = {last_dw_be, first_dw_be};

//---------------------------------------------------------------- test control
reg         tc_bp;
reg         tc_ro;
reg         tc_split;
reg         flip_en;
reg  [31:0] flip_k;
reg         drop_en;
integer     drop_idx;
reg  [31:0] SEED;
reg  [31:0] test_seed;

integer     test_total_dw;
integer     exp_issued_cnt;
integer     exp_sum;
integer     exp_beats;
integer     exp_dw;
integer     hdr_err;
integer     hseq_no;
integer     tot_err;

reg         chk_first;
integer     exp_err;
integer     exp_max;
reg  [31:0] exp_fidx;
reg  [31:0] exp_fdata;
reg  [31:0] exp_fexp;

//---------------------------------------------------------------- host model state
integer     cyc;
integer     hs;
integer     gap_cnt;
integer     beat_i;
integer     beats_cur;
integer     lenb_cur;
integer     k_cur;
integer     tsel;

reg  [31:0] ob_mask;
integer     ob_cnt;

reg        hv    [0:31];
integer    hk    [0:31];
integer    hremb [0:31];
integer    hoff  [0:31];
integer    hbase [0:31];
integer    hdue  [0:31];
integer    hseq  [0:31];
reg        hdrop [0:31];

reg         tx_pend;
integer     i;
integer     n_ready;
integer     sel;
integer     Lb;
integer     tmpi;
integer     tmpj;
reg  [31:0] rnd;
reg  [31:0] tmp32;
reg  [127:0] tmp128;

//---------------------------------------------------------------- functions
function [31:0] hdata_raw;
    input integer k;
    reg [31:0] kk;
    begin
        kk = k;
        hdata_raw = SEED ^ kk ^ (kk << 16);
    end
endfunction

function [31:0] hdata;
    input integer k;
    reg [31:0] kk;
    begin
        kk = k;
        hdata = SEED ^ kk ^ (kk << 16);
        if (flip_en && (kk == flip_k))
            hdata = hdata ^ 32'h20;
    end
endfunction

function [127:0] beat_data;
    input integer k;
    input integer b;
    integer kk;
    reg [31:0] d0;
    reg [31:0] d1;
    reg [31:0] d2;
    reg [31:0] d3;
    begin
        kk = k + 4*b;
        d0 = hdata(kk);
        d1 = hdata(kk+1);
        d2 = hdata(kk+2);
        d3 = hdata(kk+3);
        beat_data = {d3,d2,d1,d0};
    end
endfunction

//---------------------------------------------------------------- main engine
always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        cyc            <= 0;
        tx_trdy        <= 1'b0;
        tx_tvld        <= 1'b0;
        tx_tlast       <= 1'b0;
        tx_pend        <= 1'b0;
        cpld_en        <= 1'b0;
        cpld_data_flag <= 1'b0;
        cpld_data      <= 128'd0;
        cpld_dw_vld    <= 4'd0;
        cpld_length    <= 10'd0;
        cpld_tag       <= 8'd0;
        cpld_multi     <= 1'b0;
        cpld_byte_cnt  <= 12'd0;
        cpld_low_addr  <= 7'd0;
        hs             <= 0;
        gap_cnt        <= 0;
        beat_i         <= 0;
        beats_cur      <= 0;
        lenb_cur       <= 0;
        k_cur          <= 0;
        tsel           <= 0;
        ob_mask        <= 32'd0;
        ob_cnt         <= 0;
        exp_sum        <= 0;
        exp_beats      <= 0;
        exp_dw         <= 0;
        hdr_err        <= 0;
    end
    else
    begin
        cyc <= cyc + 1;

        //-------------------------------------------- tx ready (optional back pressure)
        rnd = $random;
        tx_trdy <= tc_bp ? ((rnd % 10) < 7) : 1'b1;

        //-------------------------------------------- tx slave1 model
        if (tx_pend)
        begin
            tx_pend  <= 1'b0;
            tx_tvld  <= 1'b1;
            tx_tlast <= 1'b1;

            // ---- header checks
            tmpi = mrd_tag[4:0];
            if (ob_mask[tmpi] != 1'b0)
            begin
                $display("[hdrchk] tag %0d already outstanding (cyc=%0d)", tmpi, cyc);
                hdr_err = hdr_err + 1;
            end
            tmp32 = (mrd_max_out == 6'd0) ? 6'd16 : mrd_max_out;
            if (tmp32 > 6'd32) tmp32 = 6'd32;
            if ((ob_cnt + 1) > tmp32)
            begin
                $display("[hdrchk] outstanding overflow tag=%0d cnt=%0d (cyc=%0d)", tmpi, ob_cnt, cyc);
                hdr_err = hdr_err + 1;
            end
            if (mrd_addr[31:0] != (BASE + exp_issued_cnt*256))
            begin
                $display("[hdrchk] addr got %h exp %h (cyc=%0d)", mrd_addr[31:0], BASE + exp_issued_cnt*256, cyc);
                hdr_err = hdr_err + 1;
            end
            tmpi = test_total_dw - exp_issued_cnt*64;
            if (tmpi > 64) tmpi = 64;
            if (mrd_length != tmpi[9:0])
            begin
                $display("[hdrchk] length got %0d exp %0d (cyc=%0d)", mrd_length, tmpi, cyc);
                hdr_err = hdr_err + 1;
            end
            tmpj = mrd_addr[11:0] + (mrd_length * 4);
            if (tmpj > 4096)
            begin
                $display("[hdrchk] cross 4k addr=%h len=%0d (cyc=%0d)", mrd_addr[11:0], mrd_length, cyc);
                hdr_err = hdr_err + 1;
            end

            // ---- add request
            tmpi        = mrd_tag[4:0];
            hv[tmpi]    = 1'b1;
            hk[tmpi]    = exp_issued_cnt*64;
            hremb[tmpi] = mrd_length*4;
            hoff[tmpi]  = 0;
            hbase[tmpi] = BASE + exp_issued_cnt*256;
            rnd         = $random;
            hdue[tmpi]  = cyc + 50 + (rnd % 251);
            hseq[tmpi]  = hseq_no;
            hseq_no     = hseq_no + 1;
            hdrop[tmpi] = (drop_en && (exp_issued_cnt == drop_idx)) ? 1'b1 : 1'b0;
            ob_mask[tmpi] = 1'b1;
            ob_cnt      = ob_cnt + 1;
            exp_issued_cnt = exp_issued_cnt + 1;
        end
        else if (tx_tvld && tx_trdy)
        begin
            tx_tvld  <= 1'b0;
            tx_tlast <= 1'b0;
        end
        else if (tx_mrd_en && tx_trdy && !tx_tvld)
        begin
            tx_pend <= 1'b1;
        end

        //-------------------------------------------- cpld engine
        if (hs == 0)
        begin
            sel = -1;
            if (tc_ro)
            begin
                n_ready = 0;
                for (i=0;i<32;i=i+1)
                begin
                    if (hv[i] && !hdrop[i] && (hremb[i] > 0) && (cyc >= hdue[i]))
                    begin
                        n_ready = n_ready + 1;
                        rnd = $random;
                        if ((rnd % n_ready) == 0) sel = i;
                    end
                end
            end
            else
            begin
                tmpj = 1000000;
                for (i=0;i<32;i=i+1)
                begin
                    if (hv[i] && !hdrop[i] && (hremb[i] > 0) && (cyc >= hdue[i]) && (hseq[i] < tmpj))
                    begin
                        tmpj = hseq[i];
                        sel  = i;
                    end
                end
            end

            if (sel >= 0)
            begin
                if (tc_split)
                begin
                    rnd = $random;
                    Lb = (((rnd % 4) + 1) * 64);
                    if (Lb > hremb[sel]) Lb = hremb[sel];
                end
                else
                begin
                    Lb = hremb[sel];
                end
                if ((Lb % 16) != 0)
                begin
                    $display("[tb] packet not multiple of 16 bytes Lb=%0d", Lb);
                    tot_err = tot_err + 1;
                end

                if (Lb < 16) Lb = 16;
                beats_cur = (Lb + 15) / 16;
                if (beats_cur < 1) beats_cur = 1;
                lenb_cur  = Lb;
                k_cur     = hk[sel] + hoff[sel]/4;
                tsel      = sel;
                beat_i    = 0;

                tmp32 = sel;
                cpld_data_flag <= 1'b1;
                cpld_en        <= 1'b1;
                cpld_tag       <= tmp32[7:0];
                tmp32 = Lb/4;
                cpld_length    <= tmp32[9:0];
                tmp32 = hremb[sel];
                cpld_byte_cnt  <= (tmp32 == 32'd4096) ? 12'd0 : tmp32[11:0];
                tmp32 = (hbase[sel] + hoff[sel]) & 32'h7F;
                cpld_low_addr  <= tmp32[6:0];
                cpld_multi     <= (hremb[sel] > Lb) ? 1'b1 : 1'b0;
                cpld_dw_vld    <= 4'hF;
                tmp128         = beat_data(k_cur, 0);
                cpld_data      <= tmp128;

                exp_sum   = exp_sum + tmp128[31:0] + tmp128[63:32] + tmp128[95:64] + tmp128[127:96];
                exp_beats = exp_beats + 1;
                exp_dw    = exp_dw + 4;

                hremb[sel] = hremb[sel] - Lb;
                hoff[sel]  = hoff[sel] + Lb;
                if (hremb[sel] == 0)
                begin
                    hv[sel]      = 1'b0;
                    ob_mask[sel] = 1'b0;
                    ob_cnt       = ob_cnt - 1;
                end
                hs <= 1;
            end
        end
        else if (hs == 1)
        begin
            if (beat_i == (beats_cur - 1))
            begin
                cpld_en        <= 1'b0;
                cpld_data_flag <= 1'b0;
                rnd = $random;
                gap_cnt <= 1 + (rnd % 4);
                hs <= 2;
            end
            else
            begin
                beat_i    <= beat_i + 1;
                tmp128    = beat_data(k_cur, beat_i+1);
                cpld_data <= tmp128;
                exp_sum   = exp_sum + tmp128[31:0] + tmp128[63:32] + tmp128[95:64] + tmp128[127:96];
                exp_beats = exp_beats + 1;
                exp_dw    = exp_dw + 4;
            end
        end
        else
        begin
            if (gap_cnt <= 1)
            begin
                gap_cnt <= 0;
                hs <= 0;
            end
            else
            begin
                gap_cnt <= gap_cnt - 1;
            end
        end
    end
end

//---------------------------------------------------------------- tasks
task clear_host;
    integer k;
    begin
        for (k=0;k<32;k=k+1)
        begin
            hv[k]    = 1'b0;
            hdrop[k] = 1'b0;
            hremb[k] = 0;
            hoff[k]  = 0;
            hk[k]    = 0;
            hbase[k] = 0;
            hdue[k]  = 0;
            hseq[k]  = 0;
        end
        ob_mask = 32'd0;
        ob_cnt  = 0;
        hs      = 0;
        gap_cnt = 0;
        exp_issued_cnt = 0;
        hseq_no = 0;
    end
endtask

task issue_cmd;
    integer w;
    begin
        mrd32_req = 1'b0;
        @(posedge clk); #1;
        mrd32_req = 1'b1;
        @(posedge clk); #1;
        w = 0;
        while ((mrd32_ack !== 1'b1) && (w < 1000))
        begin
            @(posedge clk); #1;
            w = w + 1;
        end
        @(posedge clk); #1;
        mrd32_req = 1'b0;
    end
endtask

task run_test;
    input integer tn;
    input integer ext;
    input integer mxo;
    input integer mlen;
    input integer bp;
    input integer ro;
    input integer sp;
    integer w;
    integer done_seen;
    integer tmo;
    integer fail;
    integer mbps;
    integer total_bytes;
    integer limit_eff;
    reg [31:0] chk_err;
    reg [31:0] chk_beats;
    reg [31:0] chk_sum;
    reg [31:0] chk_fidx;
    reg [31:0] chk_fdata;
    reg [31:0] chk_fexp;
    begin
        w = 0;
        while ((hs != 0) && (w < 100000))
        begin
            @(posedge clk); #1;
            w = w + 1;
        end
        clear_host;

        SEED     = test_seed;
        chk_seed = test_seed;
        tc_bp    = bp;
        tc_ro    = ro;
        tc_split = sp;

        test_total_dw  = (ext != 0) ? ext : mlen;
        mem_length     = mlen;
        mrd_ext_length = ext;
        mrd_max_out    = mxo;
        mem_addr       = {32'd0, BASE};
        exp_sum        = 0;
        exp_beats      = 0;
        exp_dw         = 0;
        hdr_err        = 0;
        exp_issued_cnt = 0;
        hseq_no        = 0;

        issue_cmd;

        done_seen = 0;
        tmo       = 0;
        while ((done_seen == 0) && (tmo < 200000))
        begin
            @(posedge clk); #1;
            if (mrd_done === 1'b1) done_seen = 1;
            tmo = tmo + 1;
        end
        repeat(20) @(posedge clk); #1;

        chk_err   = chk_stat[31:0];
        chk_beats = chk_stat[63:32];
        chk_sum   = chk_stat[95:64];
        chk_fidx  = chk_stat[127:96];
        chk_fdata = chk_stat[159:128];
        chk_fexp  = chk_stat[191:160];

        if (mrd_max_out == 6'd0) limit_eff = 16;
        else if (mrd_max_out > 6'd32) limit_eff = 32;
        else limit_eff = mrd_max_out;

        fail = 0;
        if (done_seen == 0)
        begin
            $display("T%0d FAIL no done (timeout cyc=%0d)", tn, tmo);
            fail = 1;
        end
        if (hdr_err != 0)
        begin
            $display("T%0d FAIL header check errors=%0d", tn, hdr_err);
            fail = 1;
        end
        if (chk_err != exp_err)
        begin
            $display("T%0d FAIL checker err_cnt=%0d exp=%0d", tn, chk_err, exp_err);
            fail = 1;
        end
        if (chk_beats != (test_total_dw/4))
        begin
            $display("T%0d FAIL beats=%0d exp=%0d", tn, chk_beats, test_total_dw/4);
            fail = 1;
        end
        if (chk_sum !== exp_sum)
        begin
            $display("T%0d FAIL sum=%h exp=%h", tn, chk_sum, exp_sum);
            fail = 1;
        end
        if (chk_first == 1'b1)
        begin
            if (chk_fidx !== exp_fidx)
            begin
                $display("T%0d FAIL first_idx=%0d exp=%0d", tn, chk_fidx, exp_fidx);
                fail = 1;
            end
            if (chk_fdata !== exp_fdata)
            begin
                $display("T%0d FAIL first_data=%h exp=%h", tn, chk_fdata, exp_fdata);
                fail = 1;
            end
            if (chk_fexp !== exp_fexp)
            begin
                $display("T%0d FAIL first_exp=%h exp=%h", tn, chk_fexp, exp_fexp);
                fail = 1;
            end
        end
        else if (chk_fidx !== 32'hFFFFFFFF)
        begin
            $display("T%0d FAIL first_idx=%h exp=ffffffff", tn, chk_fidx);
            fail = 1;
        end
        if (stat_issued !== ((test_total_dw+63)/64))
        begin
            $display("T%0d FAIL issued=%0d exp=%0d", tn, stat_issued, (test_total_dw+63)/64);
            fail = 1;
        end
        if (stat_freed !== stat_issued)
        begin
            $display("T%0d FAIL freed=%0d issued=%0d", tn, stat_freed, stat_issued);
            fail = 1;
        end
        if (stat_word[5:0] !== 6'd0)
        begin
            $display("T%0d FAIL out_cnt=%0d", tn, stat_word[5:0]);
            fail = 1;
        end
        if (stat_word[13:8] > limit_eff)
        begin
            $display("T%0d FAIL max_out=%0d > limit=%0d", tn, stat_word[13:8], limit_eff);
            fail = 1;
        end
        if ((exp_max >= 0) && (stat_word[13:8] != exp_max[5:0]))
        begin
            $display("T%0d FAIL max_out=%0d exp=%0d", tn, stat_word[13:8], exp_max);
            fail = 1;
        end

        total_bytes = test_total_dw*4;
        if (stat_cycles == 0) mbps = 0;
        else mbps = (total_bytes*125)/stat_cycles;

        if (fail == 0)
            $display("T%0d PASS dw=%0d issued=%0d freed=%0d max_out=%0d cycles=%0d %0d MB/s",
                     tn, test_total_dw, stat_issued, stat_freed, stat_word[13:8], stat_cycles, mbps);
        else
            tot_err = tot_err + 1;

        tc_bp = 1'b0; tc_ro = 1'b0; tc_split = 1'b0;
    end
endtask

task run_abort_test;
    input integer tn;
    integer w;
    integer done_seen;
    integer fail;
    begin
        w = 0;
        while ((hs != 0) && (w < 100000))
        begin
            @(posedge clk); #1;
            w = w + 1;
        end
        clear_host;

        SEED     = test_seed;
        chk_seed = test_seed;
        tc_bp    = 1'b0;
        tc_ro    = 1'b0;
        tc_split = 1'b0;
        flip_en  = 1'b0;
        drop_en  = 1'b1;
        drop_idx = 9;

        test_total_dw  = 8192;
        mem_length     = 11'd0;
        mrd_ext_length = 20'd8192;
        mrd_max_out    = 6'd0;
        mem_addr       = {32'd0, BASE};
        exp_sum        = 0;
        exp_beats      = 0;
        exp_dw         = 0;
        hdr_err        = 0;
        exp_issued_cnt = 0;
        hseq_no        = 0;

        issue_cmd;

        done_seen = 0;
        for (w=0; w<20000; w=w+1)
        begin
            @(posedge clk); #1;
            if (mrd_done === 1'b1) done_seen = 1;
        end

        fail = 0;
        if (done_seen != 0)
        begin
            $display("T%0d FAIL got done before abort", tn);
            fail = 1;
        end
        if (stat_word[31] !== 1'b1)
        begin
            $display("T%0d FAIL cmd_active not 1 before abort (word=%h)", tn, stat_word);
            fail = 1;
        end

        mrd_abort = 1'b1;
        @(posedge clk);
        mrd_abort = 1'b0;
        for (w=0; w<10; w=w+1) @(posedge clk);
        #1;

        if (stat_word[31] !== 1'b0)
        begin
            $display("T%0d FAIL cmd_active still 1 after abort", tn);
            fail = 1;
        end
        if (stat_word[5:0] !== 6'd0)
        begin
            $display("T%0d FAIL out_cnt=%0d after abort", tn, stat_word[5:0]);
            fail = 1;
        end

        clear_host;
        drop_en  = 1'b0;
        drop_idx = -1;
        flip_en  = 1'b0;

        if (fail == 0)
            $display("T%0d PASS abort ok issued=%0d freed=%0d", tn, stat_issued, stat_freed);
        else
            tot_err = tot_err + 1;
    end
endtask

//---------------------------------------------------------------- stimulus
initial
begin
    rst_n = 1'b0;
    cfg_max_rd_req_size  = 3'd2;
    cfg_max_payload_size = 3'd1;
    cfg_pbus_num         = 8'd0;
    cfg_pbus_dev_num     = 5'd0;

    tx_trdy  = 1'b0;
    tx_tvld  = 1'b0;
    tx_tlast = 1'b0;
    mrd32_req = 1'b0;
    mrd64_req = 1'b0;
    mem_length = 11'd0;
    mem_addr   = 64'd0;
    mrd_ext_length = 20'd0;
    mrd_max_out    = 6'd0;
    mrd_abort      = 1'b0;

    cpld_length    = 10'd0;
    cpld_tag       = 8'd0;
    cpld_multi     = 1'b0;
    cpld_data_flag = 1'b0;
    cpld_data      = 128'd0;
    cpld_dw_vld    = 4'd0;
    cpld_byte_cnt  = 12'd0;
    cpld_low_addr  = 7'd0;
    cpld_en        = 1'b0;

    chk_seed = 32'd0;

    tc_bp    = 1'b0;
    tc_ro    = 1'b0;
    tc_split = 1'b0;
    flip_en  = 1'b0;
    flip_k   = 32'd0;
    drop_en  = 1'b0;
    drop_idx = -1;
    SEED     = 32'd0;
    test_seed = 32'h1001;

    tot_err   = 0;
    chk_first = 1'b0;
    exp_err   = 0;
    exp_max   = -1;
    exp_fidx  = 32'hFFFFFFFF;
    exp_fdata = 32'd0;
    exp_fexp  = 32'd0;

    clear_host;

    repeat(20) @(posedge clk);
    rst_n = 1'b1;
    repeat(20) @(posedge clk);

    test_seed = 32'h1001; chk_first = 1'b0; exp_err = 0; exp_max = -1;
    run_test(1, 0, 0, 1024, 0, 0, 0);

    test_seed = 32'h1002; chk_first = 1'b0; exp_err = 0; exp_max = -1;
    run_test(2, 0, 0, 16, 0, 0, 0);

    test_seed = 32'h1003; chk_first = 1'b0; exp_err = 0; exp_max = 16;
    run_test(3, 65536, 0, 0, 1, 1, 1);

    test_seed = 32'h1004; chk_first = 1'b0; exp_err = 0; exp_max = 1;
    run_test(4, 16388, 1, 0, 0, 0, 1);

    test_seed = 32'h1005; chk_first = 1'b0; exp_err = 0; exp_max = 32;
    run_test(5, 32768, 32, 0, 0, 1, 1);

    test_seed = 32'h1006; chk_first = 1'b0; exp_err = 0; exp_max = 3;
    run_test(6, 1000, 3, 0, 0, 0, 0);

    test_seed = 32'h1007;
    flip_en   = 1'b1;
    flip_k    = 32'd1000;
    chk_first = 1'b1;
    exp_err   = 1;
    exp_max   = -1;
    exp_fidx  = 32'd1000;
    exp_fexp  = 32'h1007 ^ 32'd1000 ^ (32'd1000 << 16);
    exp_fdata = (32'h1007 ^ 32'd1000 ^ (32'd1000 << 16)) ^ 32'h20;
    run_test(7, 8192, 0, 0, 0, 0, 0);
    flip_en = 1'b0;

    test_seed = 32'h1008;
    run_abort_test(8);

    test_seed = 32'h1009; chk_first = 1'b0; exp_err = 0; exp_max = -1;
    run_test(9, 0, 0, 1024, 0, 0, 0);

    if (tot_err == 0)
        $display("ALL TESTS PASSED");
    else
        $display("TESTS FAILED: %0d", tot_err);

    $finish;
end

endmodule
