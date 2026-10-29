//============================================================================
// tb_ddr_hub_engine.vh : MRd engine model (pclk), included by tb_ddr_hub.v
//   - doorbell auto-arbiter with i_db_ack + i_mrd_start
//   - host command task interface (i_mrd_start only)
//   - 128-bit completion write-port data generator with random slicing /
//     out-of-order blocks, gap between slices, issue_hold back-pressure
//============================================================================

//----------------------------------------------------------------- engine state
localparam E_IDLE = 3'd0, E_HOST = 3'd1, E_DBW  = 3'd2, E_SEND = 3'd3,
           E_GAP  = 3'd4, E_HOLD = 3'd5, E_DONE = 3'd6, E_POST = 3'd7;

reg [2:0]  estate;
reg [31:0] e_len, e_seed, e_dst, e_id;
reg        e_is_db;
reg        tb_busy;
reg        cmd_finished;
reg        host_pend;
reg [31:0] host_len, host_seed, host_dst;
reg [3:0]  db_delay;
integer    seg, seg_beat, gap_left, done_wait, post_wait;

integer    nchunk;
integer    chunk_s [0:8191];
integer    chunk_l [0:8191];
integer    chunk_o [0:8191];

reg  [31:0] db_seed_q [0:511];
reg  [31:0] db_len_q  [0:511];
reg  [31:0] db_dst_q  [0:511];
integer     db_wi, db_ri;      // write ptr (tests) / read ptr (FSM)

reg        split_en, swap_en;
reg        db_pause;
reg        mrd_ngap;           // 1 = no inter-slice gap, single chunk

//----------------------------------------------------------------- monitors
reg        hold_seen;
integer    hold_rise, hold_cyc;
reg        hold_prev;
integer    pclk_cyc;
integer    last_imrd_cyc, last_final_cyc;
reg        final_seen;
integer    final_cnt;
integer    imrd_cnt;

//----------------------------------------------------------------- data pattern
function [31:0] dpat;
    input [31:0] sd;
    input [31:0] k;
    begin dpat = sd ^ k ^ (k << 16); end
endfunction

function [127:0] bdat;
    input integer sd;
    input integer bk;
    integer k0;
    begin
        k0  = bk * 4;
        bdat = { dpat(sd,k0+3), dpat(sd,k0+2), dpat(sd,k0+1), dpat(sd,k0) };
    end
endfunction

//----------------------------------------------------------------- chunk builder
task prepare_chunks;
    integer i, nb, sz, ci, tmp;
    begin
        nb     = e_len / 16;
        nchunk = 0;
        if (mrd_ngap && !split_en) begin
            chunk_s[0] = 0;
            chunk_l[0] = nb;
            nchunk     = 1;
        end else begin
            i = 0;
            while (i < nb) begin
                if (split_en) sz = 4  - (i % 4);
                else          sz = 16 - (i % 16);
                if (sz > (nb - i)) sz = nb - i;
                chunk_s[nchunk] = i;
                chunk_l[nchunk] = sz;
                nchunk = nchunk + 1;
                i = i + sz;
            end
        end
        if (swap_en) begin
            ci = 0;
            while ((ci + 1) < nchunk) begin
                if ($urandom_range(1)) begin
                    tmp = chunk_s[ci];   chunk_s[ci]   = chunk_s[ci+1];   chunk_s[ci+1]   = tmp;
                    tmp = chunk_l[ci];   chunk_l[ci]   = chunk_l[ci+1];   chunk_l[ci+1]   = tmp;
                end
                ci = ci + 2;
            end
        end
        for (ci = 0; ci < nchunk; ci = ci + 1) chunk_o[ci] = ci;
    end
endtask

//----------------------------------------------------------------- main FSM
always @(posedge pclk or negedge pclk_rst_n)
    if (!pclk_rst_n) begin
        estate      <= E_IDLE;
        i_mrd_start <= 1'b0;
        i_mrd_done  <= 1'b0;
        i_db_ack    <= 1'b0;
        i_dma_wr_en <= 1'b0;
        i_dma_wr_addr <= 32'd0;
        i_dma_wr_data <= 128'd0;
        i_dma_wr_be   <= 16'd0;
        tb_busy     <= 1'b0;
        cmd_finished<= 1'b0;
        host_pend   <= 1'b0;
        seg         <= 0;
        seg_beat    <= 0;
        done_wait   <= 0;
        post_wait   <= 0;
        gap_left    <= 0;
    end else begin
        i_mrd_start <= 1'b0;
        i_mrd_done  <= 1'b0;
        i_db_ack    <= 1'b0;
        i_dma_wr_en <= 1'b0;
        case (estate)
            E_IDLE: begin
                if (host_pend && !tb_busy && !o_start_block) begin
                    e_len = host_len; e_seed = host_seed; e_dst = host_dst;
                    e_is_db = 1'b0; e_id = 32'hFFFFFFFF;
                    host_pend <= 1'b0;
                    prepare_chunks;
                    seg <= 0; seg_beat <= 0;
                    tb_busy <= 1'b1;
                    estate  <= E_HOST;
                end else if (o_db_req && !tb_busy && !o_start_block &&
                             !db_pause && (db_ri < db_wi)) begin
                    db_delay <= $urandom_range(5,2);
                    estate   <= E_DBW;
                end
            end
            E_HOST: begin
                i_mrd_start <= 1'b1;
                estate      <= E_SEND;
            end
            E_DBW: begin
                if (!o_db_req || o_start_block || db_pause) estate <= E_IDLE;
                else if (db_delay == 4'd0) begin
                    if (!o_start_block) begin
                        e_len  = db_len_q[db_ri % 512];
                        e_seed = db_seed_q[db_ri % 512];
                        e_dst  = db_dst_q[db_ri % 512];
                        e_id   = db_ri;
                        e_is_db= 1'b1;
                        db_ri  = db_ri + 1;
                        prepare_chunks;
                        seg <= 0; seg_beat <= 0;
                        tb_busy     <= 1'b1;
                        i_db_ack    <= 1'b1;
                        i_mrd_start <= 1'b1;
                        estate      <= E_SEND;
                    end else estate <= E_IDLE;
                end else db_delay <= db_delay - 1'b1;
            end
            E_SEND: begin
                if (o_issue_hold && (((chunk_s[chunk_o[seg]] + seg_beat) & 15) == 0)) begin
                    estate <= E_HOLD;      // pause on the packer's 8-word burst boundary
                end else if (seg_beat < chunk_l[chunk_o[seg]]) begin
                    i_dma_wr_en   <= 1'b1;
                    i_dma_wr_addr <= chunk_s[chunk_o[seg]] + seg_beat;
                    i_dma_wr_data <= bdat(e_seed, chunk_s[chunk_o[seg]] + seg_beat);
                    i_dma_wr_be   <= 16'hFFFF;
                    seg_beat      <= seg_beat + 1;
                end else if ((seg + 1) < nchunk) begin
                    seg       <= seg + 1;
                    seg_beat  <= 0;
                    gap_left  <= (mrd_ngap ? 0 : $urandom_range(3));
                    estate    <= E_GAP;
                end else begin
                    estate    <= E_DONE;
                    done_wait <= 16;
                end
            end
            E_GAP: begin
                if (gap_left == 0) estate <= E_SEND;
                else               gap_left <= gap_left - 1;
            end
            E_HOLD: begin
                if (!o_issue_hold) begin
                    gap_left <= 0;
                    estate   <= E_SEND;
                end
            end
            E_DONE: begin
                if (done_wait == 0) begin
                    i_mrd_done <= 1'b1;
                    post_wait  <= 6;
                    estate     <= E_POST;
                end else done_wait <= done_wait - 1;
            end
            E_POST: begin
                if (post_wait != 0) post_wait <= post_wait - 1;
                else if (!o_start_block) begin
                    tb_busy <= 1'b0;
                    if (!e_is_db) cmd_finished <= 1'b1;   // host only
                    estate  <= E_IDLE;
                end
            end
            default: estate <= E_IDLE;
        endcase
    end

//----------------------------------------------------------------- pclk monitor
always @(posedge pclk) begin
    pclk_cyc <= pclk_cyc + 1;
    if (o_issue_hold) begin
        hold_seen <= 1'b1;
        hold_cyc  <= hold_cyc + 1;
        if (!hold_prev) hold_rise <= hold_rise + 1;
    end
    hold_prev <= o_issue_hold;
    if (i_mrd_done)         begin last_imrd_cyc <= pclk_cyc; imrd_cnt <= imrd_cnt + 1; end
    if (o_final_done_host)  begin last_final_cyc <= pclk_cyc; final_seen <= 1'b1; final_cnt <= final_cnt + 1; end
end
