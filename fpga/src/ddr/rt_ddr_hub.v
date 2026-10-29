`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_ddr_hub.v
// PCIe EP DMA -> DDR3 write hub + doorbell queue + DDR3->RAM readback.
// Verilog-2001 synthesizable.
//
//  - rt_async_fifo : gray-code async FIFO (registered read)
//  - rt_sync2      : generic 2-stage synchronizer
//  - rt_ddr_hub    : top of this file
//////////////////////////////////////////////////////////////////////////////

//============================================================================
// generic 2-stage synchronizer
//============================================================================
module rt_sync2 #(parameter WIDTH = 1) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);
    reg [WIDTH-1:0] s1;
    reg [WIDTH-1:0] s2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin s1 <= {WIDTH{1'b0}}; s2 <= {WIDTH{1'b0}}; end
        else        begin s1 <= d;             s2 <= s1;             end
    assign q = s2;
endmodule

//============================================================================
// async FIFO : gray-code pointers, 2-stage sync, registered read
//============================================================================
module rt_async_fifo #(parameter DW = 288, parameter AW = 9) (
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire           wr_en,
    input  wire [DW-1:0]  wr_data,
    output wire           wr_full,
    output wire [AW:0]    wr_level,
    input  wire           rd_clk,
    input  wire           rd_rst_n,
    input  wire           rd_en,
    output reg  [DW-1:0]  rd_data,
    output reg            rd_valid,
    output wire           rd_empty,
    output wire [AW:0]    rd_level
);
    localparam DEPTH = (1 << AW);

    reg [DW-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] wgray_s1, wgray_s2, rgray_s1, rgray_s2;

    wire [AW:0] wbin_nxt  = wbin + 1'b1;
    wire [AW:0] wgray_nxt = wbin_nxt ^ (wbin_nxt >> 1);
    wire [AW:0] rbin_nxt  = rbin + 1'b1;
    wire [AW:0] rgray_nxt = rbin_nxt ^ (rbin_nxt >> 1);

    assign wr_full  = (wgray_nxt == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    assign rd_empty = (rgray == wgray_s2);

    // ---- write domain ----
    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) begin wbin <= 0; wgray <= 0; end
        else if (wr_en && !wr_full) begin wbin <= wbin_nxt; wgray <= wgray_nxt; end

    always @(posedge wr_clk)
        if (wr_en && !wr_full) mem[wbin[AW-1:0]] <= wr_data;

    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) begin rgray_s1 <= 0; rgray_s2 <= 0; end
        else           begin rgray_s1 <= rgray; rgray_s2 <= rgray_s1; end

    // ---- read domain ----
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin rbin <= 0; rgray <= 0; rd_valid <= 1'b0; end
        else begin
            rd_valid <= (rd_en && !rd_empty);
            if (rd_en && !rd_empty) begin
                rbin    <= rbin_nxt;
                rgray   <= rgray_nxt;
            end
        end

    // separate block-RAM-friendly read (no async reset)  // fix1018
    always @(posedge rd_clk)
        if (rd_en && !rd_empty) rd_data <= mem[rbin[AW-1:0]];  // fix1018

    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin wgray_s1 <= 0; wgray_s2 <= 0; end
        else           begin wgray_s1 <= wgray; wgray_s2 <= wgray_s1; end

    function [AW:0] g2b;
        input [AW:0] g;
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i-1)
                g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    assign wr_level = wbin - g2b(rgray_s2);
    assign rd_level = g2b(wgray_s2) - rbin;
endmodule

//============================================================================
// rt_ddr_hub
//============================================================================
module rt_ddr_hub #(
    parameter WFIFO_AW = 9,
    parameter CFIFO_AW = 9,   // fix1018hw: >= WFIFO_AW so 1-beat bursts cannot overflow the command FIFO
    parameter RFIFO_AW = 8,
    parameter HOLD_TH  = 240
) (
    input  wire         pclk,
    input  wire         pclk_rst_n,
    input  wire         i_tap_vld,
    input  wire [11:0]  i_tap_addr,
    input  wire [31:0]  i_tap_data,
    input  wire         i_dma_wr_en,
    input  wire [31:0]  i_dma_wr_addr,
    input  wire [127:0] i_dma_wr_data,
    input  wire [15:0]  i_dma_wr_be,
    // 20261026 cam: camera (cam1) write port -> DDR, PCIe DMA has priority
    input  wire         i_cam_wr_en,
    input  wire [31:0]  i_cam_wr_addr,
    input  wire [127:0] i_cam_wr_data,
    input  wire [15:0]  i_cam_wr_be,
    output wire         o_cam_wr_ready,
    // 20261027 cam : camera FIFO nearly full -> pause NEW PCIe MRd requests
    input  wire         i_cam_urgent,
    output reg  [31:0]  o_cam_urg_cnt,   // number of MRd pause episodes
    input  wire         i_mrd_start,
    input  wire         i_mrd_done,
    input  wire         i_db_ack,
    output reg          o_db_req,
    output reg  [31:0]  o_db_addr,
    output reg  [19:0]  o_db_len_dw,
    output wire         o_issue_hold,
    output wire         o_start_block,
    output wire         o_final_done_host,   // fix1018: assigned by continuous assign
    output wire         o_copy_wr_en,
    output wire [11:0]  o_copy_wr_addr,
    output wire [127:0] o_copy_wr_data,
    output wire [127:0] o_stat1c0,
    output wire [127:0] o_stat1d0,
    output wire [127:0] o_stat1e0,
    input  wire         ddr_clk,
    input  wire         ddr_rst_n,
    input  wire         ddr_init_done,
    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awlen,
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    output wire [27:0]  axi_araddr,
    output wire [3:0]   axi_arlen,
    output reg          axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire         axi_rlast,
    input  wire         axi_rvalid
);

    //------------------------------------------------------------------------
    // reset generation : async assert, sync release
    //------------------------------------------------------------------------
    wire rst_any_n = pclk_rst_n & ddr_rst_n;
    reg  rp1, rp2, rd1, rd2;
    always @(posedge pclk or negedge rst_any_n)
        if (!rst_any_n) begin rp1 <= 1'b0; rp2 <= 1'b0; end
        else            begin rp1 <= 1'b1; rp2 <= rp1; end
    always @(posedge ddr_clk or negedge rst_any_n)
        if (!rst_any_n) begin rd1 <= 1'b0; rd2 <= 1'b0; end
        else            begin rd1 <= 1'b1; rd2 <= rd1; end
    wire rst_p_sync = rp2;
    wire rst_d_sync = rd2;

    // forward declarations (signals used before their defining section)
    reg          flush_pushed;
    reg          rb_busy;
    reg          wfifo_wr_en;
    reg  [287:0] wfifo_wr_data;
    wire         wfifo_wr_full;
    wire [WFIFO_AW:0] wfifo_wr_level;
    wire         wfifo_rd_empty;
    wire [287:0] wfifo_rd_data;
    wire         wfifo_rd_valid;
    wire [WFIFO_AW:0] wfifo_rd_level;
    reg          wfifo_rd_en;
    reg          cfifo_wr_en;
    reg  [31:0]  cfifo_wr_data;
    wire         cfifo_wr_full;
    wire [CFIFO_AW:0] cfifo_wr_level;
    wire         cfifo_rd_empty;
    wire [31:0]  cfifo_rd_data;
    wire         cfifo_rd_valid;
    wire [CFIFO_AW:0] cfifo_rd_level;
    reg          cfifo_rd_en;
    reg          rfifo_wr_en;
    reg  [255:0] rfifo_wr_data;
    wire         rfifo_wr_full;
    wire [RFIFO_AW:0] rfifo_wr_level;
    wire         rfifo_rd_empty;
    wire [255:0] rfifo_rd_data;
    wire         rfifo_rd_valid;
    wire [RFIFO_AW:0] rfifo_rd_level;
    reg          rfifo_rd_en;

    //------------------------------------------------------------------------
    // init_p : ddr_init_done -> pclk (2 stage)
    //------------------------------------------------------------------------
    reg init_meta, init_p;
    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin init_meta <= 1'b0; init_p <= 1'b0; end
        else             begin init_meta <= ddr_init_done; init_p <= init_meta; end

    //========================================================================
    // B. registers (pclk)
    //========================================================================
    reg [31:0] db_host_r, db_len_r, db_dst_r;
    reg        ddr_en_r;
    reg [31:0] ddr_dst_host_r;
    reg [31:0] rb_src_r, rb_len_r;
    reg [11:0] rb_ramoff_r;
    reg        rb_start_r;
    reg        clr_stat_r;

    wire ddr_en_eff = ddr_en_r & init_p;

    // doorbell queue : depth 16
    localparam QW = 118;                       // {host[31:0],len[23:0],dst[29:0],id[31:0]}
    reg [QW-1:0] q_mem [0:15];
    reg [4:0]    q_wr, q_rd;                    // fix1018
    wire [4:0]   q_level = q_wr - q_rd;         // fix1018
    wire         q_full = (q_level == 5'd16);
    reg [31:0]   push_cnt, ovf_cnt;

    wire [QW-1:0] q_entry = {db_host_r, db_len_r[23:0], db_dst_r[29:0], i_tap_data};

    // stats cleared by ctrl[1]
    reg [31:0] done_cnt, rb_done_cnt;
    reg [31:0] last_id, last_db_cycles;
    reg [31:0] pushed_beats, rb_beats;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            db_host_r      <= 32'h0;
            db_len_r       <= 32'h0;
            db_dst_r       <= 32'h0;
            ddr_en_r       <= 1'b0;
            ddr_dst_host_r <= 32'h0;
            rb_src_r       <= 32'h0;
            rb_len_r       <= 32'h0;
            rb_ramoff_r    <= 12'h0;
            rb_start_r     <= 1'b0;
            clr_stat_r     <= 1'b0;
            q_wr           <= 5'h0;         // fix1018
            push_cnt       <= 32'h0;
            ovf_cnt        <= 32'h0;
        end else begin
            rb_start_r <= 1'b0;
            clr_stat_r <= 1'b0;
            if (i_tap_vld) begin
                case (i_tap_addr)
                    12'h190: db_host_r      <= i_tap_data;
                    12'h194: db_len_r       <= i_tap_data;
                    12'h198: db_dst_r       <= i_tap_data;
                    12'h19C: begin
                        if (q_full) ovf_cnt <= ovf_cnt + 1'b1;
                        else begin
                            q_mem[q_wr[3:0]] <= q_entry;    // fix1018
                            q_wr        <= q_wr + 1'b1;
                            push_cnt    <= push_cnt + 1'b1;
                        end
                    end
                    12'h1A0: begin
                        ddr_en_r   <= i_tap_data[0];
                        if (i_tap_data[1]) clr_stat_r <= 1'b1;
                    end
                    12'h1A4: ddr_dst_host_r <= i_tap_data;
                    12'h1A8: rb_src_r       <= i_tap_data;
                    12'h1AC: rb_len_r       <= i_tap_data;
                    12'h1B0: rb_ramoff_r    <= i_tap_data[11:0];
                    12'h1B4: if (!rb_busy) rb_start_r <= 1'b1;
                    default: ;
                endcase
            end
        end

    // queue level tracking : combinational  // fix1018

    //========================================================================
    // C. command tracking & commit (pclk)
    //========================================================================
    localparam C_IDLE = 2'd0, C_FLUSH = 2'd1, C_WAIT = 2'd2;
    reg [1:0]  commit_state;
    reg        flush_req;
    reg        cmd_is_db, cmd_ddr;
    reg [25:0] base16;
    reg        final_host_r, fd_db_r;

    // flush ack toggle (ddr domain) -> pclk
    reg flush_ack_t;
    wire flush_ack_s;
    rt_sync2 #(.WIDTH(1)) u_sync_fack (
        .clk(pclk), .rst_n(rst_p_sync), .d(flush_ack_t), .q(flush_ack_s));
    reg flush_ack_s_d;
    always @(posedge pclk or negedge rst_p_sync)
        if (!rst_p_sync) flush_ack_s_d <= 1'b0;
        else             flush_ack_s_d <= flush_ack_s;
    wire flush_ack_edge = flush_ack_s ^ flush_ack_s_d;

    // doorbell engine cur regs
    reg [31:0] cur_host;
    reg [23:0] cur_len;
    reg [29:0] cur_dst;
    reg [31:0] cur_id;
    reg [4:0]  q_level_d;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            commit_state <= C_IDLE;
            flush_req    <= 1'b0;
            cmd_is_db    <= 1'b0;
            cmd_ddr      <= 1'b0;
            base16       <= 26'h0;
            final_host_r <= 1'b0;
            fd_db_r      <= 1'b0;
        end else begin
            final_host_r <= 1'b0;
            fd_db_r      <= 1'b0;
            if (i_mrd_start) begin
                cmd_is_db <= i_db_ack;
                cmd_ddr   <= ddr_en_eff;
                base16    <= (i_db_ack ? {4'b0, cur_dst} : ddr_dst_host_r) >> 4;
            end
            case (commit_state)
                C_IDLE: if (i_mrd_done) begin
                            if (cmd_ddr) begin
                                flush_req    <= 1'b1;
                                commit_state <= C_FLUSH;
                            end else begin
                                if (cmd_is_db) fd_db_r      <= 1'b1;
                                else           final_host_r <= 1'b1;
                            end
                        end
                C_FLUSH: if (flush_pushed) begin
                             flush_req    <= 1'b0;
                             commit_state <= C_WAIT;
                         end
                C_WAIT:  if (flush_ack_edge) begin
                             if (cmd_is_db) fd_db_r      <= 1'b1;
                             else           final_host_r <= 1'b1;
                             commit_state <= C_IDLE;
                         end
                default: commit_state <= C_IDLE;
            endcase
        end

    wire commit_busy   = (commit_state != C_IDLE);
    assign o_final_done_host = final_host_r;
    assign o_start_block     = commit_busy | i_mrd_done;

    //========================================================================
    // D. doorbell engine (pclk)
    //========================================================================
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_RUN = 2'd2;
    reg [1:0]  eng_state;
    reg [31:0] cyc_cnt;
    reg [31:0] q_rd_plus;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            eng_state  <= S_IDLE;
            o_db_req   <= 1'b0;
            o_db_addr  <= 32'h0;
            o_db_len_dw<= 20'h0;
            cur_host   <= 32'h0;
            cur_len    <= 24'h0;
            cur_dst    <= 30'h0;
            cur_id     <= 32'h0;
            cyc_cnt    <= 32'h0;
            q_rd       <= 5'h0;         // fix1018
            done_cnt   <= 32'h0;
            last_id    <= 32'h0;
            last_db_cycles <= 32'h0;
        end else begin
            if (clr_stat_r) begin
                done_cnt       <= 32'h0;
                last_db_cycles <= 32'h0;
            end
            case (eng_state)
                S_IDLE: if ((q_level != 5'h0) && !commit_busy) begin
                            cur_host    <= q_mem[q_rd[3:0]][117:86];    // fix1018
                            cur_len     <= q_mem[q_rd[3:0]][85:62];     // fix1018
                            cur_dst     <= q_mem[q_rd[3:0]][61:32];     // fix1018
                            cur_id      <= q_mem[q_rd[3:0]][31:0];      // fix1018
                            q_rd        <= q_rd + 1'b1;
                            o_db_req    <= 1'b1;
                            o_db_addr   <= q_mem[q_rd[3:0]][117:86];    // fix1018
                            o_db_len_dw <= q_mem[q_rd[3:0]][85:62] >> 2; // fix1018
                            eng_state   <= S_REQ;
                        end
                S_REQ:  if (i_db_ack) begin
                            o_db_req  <= 1'b0;
                            cyc_cnt   <= 32'h0;
                            eng_state <= S_RUN;
                        end
                S_RUN:  begin
                            cyc_cnt <= cyc_cnt + 1'b1;
                            if (fd_db_r) begin
                                done_cnt       <= done_cnt + 1'b1;
                                last_id        <= cur_id;
                                last_db_cycles <= cyc_cnt;
                                eng_state      <= S_IDLE;
                            end
                        end
                default: eng_state <= S_IDLE;
            endcase
        end

    //========================================================================
    // E. write packer (pclk)
    //========================================================================
    reg         hv, hv_low;
    reg         hv_src;                 // 20261026 cam: source of the held half
    reg [24:0]  hb;
    reg [255:0] hdata;
    reg [31:0]  hstrb;
    reg         bo;
    reg         bo_src;                 // 20261026 cam: source of the open burst
    reg [24:0]  bstart, blast;
    reg [3:0]   bn;
    reg [5:0]   idle_cnt;               // 20261026 cam : 6 bit (camera half waits longer)
    reg         flushed;

    reg         wfifo_ovf;
    reg         cfifo_ovf;   // fix1018hw
    reg [15:0]  wmax_level;

    //------------------------------------------------------------------------
    // 20261026 cam : write arbitration in front of the packer.
    //   PCIe DMA has absolute priority (the camera can wait, PCIe cannot lose
    //   a frame).  The camera address is absolute : base16 (doorbell cur_dst /
    //   ddr_dst_host_r) is never added to it, and the packer stamps every
    //   burst with its source so a burst can never mix two sources.
    //   i_cam_wr_addr is a byte address, pk_g works in 16-byte units exactly
    //   like the DMA path (base16 = host byte address >> 4).
    //
    //   fix1026 : a camera beat is now refused while
    //     - a DMA beat is offered                (~dma_beat)
    //     - the DMA is closing out / flushing    (commit_busy | i_mrd_done |
    //                                             flush_req)
    //     - the write FIFO is above CAM_WFIFO_LIM
    //   The last point keeps >= 350 beats of the 512 deep write FIFO free, so
    //   the host (throttled at HOLD_TH = 240 + one 8 beat burst) can never
    //   overflow it.  Before this fix the camera could push the level up to
    //   the host's own headroom; the next PCIe beat then hit a full FIFO, was
    //   dropped while still counted in its command entry, and the command/data
    //   FIFO pair desynchronised -> the AXI write engine waited for a beat that
    //   no longer existed, the completion path stalled and DONE stayed at 0.
    //------------------------------------------------------------------------
    localparam [9:0] CAM_WFIFO_LIM = 10'd160;

    wire [25:0] pk_g     = base16 + i_dma_wr_addr[25:0];  // DMA : 16-byte units
    wire [25:0] pk_g_cam = {2'b00, i_cam_wr_addr[27:4]};  // cam : abs byte addr/16
                                                          // (DDR3 is 256 MB, so
                                                          //  byte bits 27:0 only)
    wire        dma_beat = i_dma_wr_en & cmd_ddr;
    wire        dma_tail = commit_busy | i_mrd_done | flush_req;
    wire        cam_beat = i_cam_wr_en & ~dma_beat & ~dma_tail &
                           (wfifo_wr_level < CAM_WFIFO_LIM) &
                           ~wfifo_wr_full & ~cfifo_wr_full;
    wire        wk_en    = dma_beat | cam_beat;
    wire        wk_src   = cam_beat;                      // 1 = camera
    wire [25:0] wk_g     = cam_beat ? pk_g_cam : pk_g;
    wire [24:0] wk_b     = wk_g[25:1];
    wire        wk_h     = wk_g[0];
    wire [127:0] wk_data = cam_beat ? i_cam_wr_data : i_dma_wr_data;
    wire [15:0]  wk_be   = cam_beat ? i_cam_wr_be   : i_dma_wr_be;

    assign o_cam_wr_ready = cam_beat;

    // next-state combinational
    reg         hv_n, hv_low_n;
    reg         hv_src_n;
    reg [24:0]  hb_n;
    reg [255:0] hdata_n;
    reg [31:0]  hstrb_n;
    reg         bo_n;
    reg         bo_src_n;
    reg [24:0]  bstart_n, blast_n;
    reg [3:0]   bn_n;
    reg [5:0]   idle_cnt_n;
    reg         flushed_n;

    task pk_emit;
        input [24:0]  be;
        input [255:0] dat;
        input [31:0]  stb;
        input         src;          // 20261026 cam: 1 = camera burst
        begin
            if (bo_n && (be == (blast_n + 1'b1)) && (bn_n < 4'd8) &&
                (be[2:0] != 3'd0) && (bo_src_n == src)) begin
                wfifo_wr_en   = 1'b1;
                wfifo_wr_data = {stb, dat};
                bn_n          = bn_n + 1'b1;
                blast_n       = be;
                if ((bn_n == 4'd8) || (be[2:0] == 3'd7)) begin
                    cfifo_wr_en   = 1'b1;
                    // [26:25] = source tag : 0 = PCIe DMA, 1 = camera
                    cfifo_wr_data = {1'b0, (bn_n - 1'b1), 1'b0, bo_src_n, bstart_n};
                    bo_n          = 1'b0;
                end
            end else begin
                if (bo_n) begin
                    cfifo_wr_en   = 1'b1;
                    cfifo_wr_data = {1'b0, (bn_n - 1'b1), 1'b0, bo_src_n, bstart_n};
                    bo_n          = 1'b0;
                end
                wfifo_wr_en   = 1'b1;
                wfifo_wr_data = {stb, dat};
                bo_n          = 1'b1;
                bo_src_n      = src;
                bstart_n      = be;
                blast_n       = be;
                bn_n          = 4'd1;
            end
        end
    endtask

    // 20261026 cam : a held camera half waits up to 48 idle cycles for its
    // 128 bit partner (the two 16 byte words of a row are ~24 cycles apart) so
    // the burst becomes one full 32 byte write.  The DMA keeps the original 8.
    wire [5:0] idle_lim = hv_src ? 6'd48 : 6'd8;

    always @(*) begin
        wfifo_wr_en    = 1'b0;
        wfifo_wr_data  = 288'h0;
        cfifo_wr_en    = 1'b0;
        cfifo_wr_data  = 32'h0;
        flush_pushed   = 1'b0;        hv_n      = hv;
        hv_low_n  = hv_low;
        hv_src_n  = hv_src;
        hb_n      = hb;
        hdata_n   = hdata;
        hstrb_n   = hstrb;
        bo_n      = bo;
        bo_src_n  = bo_src;
        bstart_n  = bstart;
        blast_n   = blast;
        bn_n      = bn;
        idle_cnt_n= idle_cnt;
        flushed_n = flushed;

        if (!flush_req) flushed_n = 1'b0;

        if (wk_en) begin
            idle_cnt_n = 6'd0;
            if (hv && (hb == wk_b) && wk_h && hv_low && (hv_src == wk_src)) begin
                pk_emit(wk_b, {wk_data, hdata[127:0]},
                              {wk_be, hstrb[15:0]}, hv_src);
                hv_n = 1'b0;
            end else begin
                if (hv) pk_emit(hb, hdata, hstrb, hv_src);
                hv_n     = 1'b1;
                hv_low_n = ~wk_h;
                hv_src_n = wk_src;
                hb_n     = wk_b;
                hdata_n  = wk_h ? {wk_data, 128'h0} : {128'h0, wk_data};
                hstrb_n  = wk_h ? {wk_be, 16'h0}    : {16'h0, wk_be};
            end
        end else begin
            if (idle_cnt != idle_lim) idle_cnt_n = idle_cnt + 1'b1;
            if ((idle_cnt >= idle_lim) || flush_req) begin
                if (hv) begin
                    pk_emit(hb, hdata, hstrb, hv_src);
                    hv_n = 1'b0;
                end else if (bo) begin
                    cfifo_wr_en   = 1'b1;
                    cfifo_wr_data = {1'b0, (bn - 1'b1), 1'b0, bo_src, bstart};
                    bo_n          = 1'b0;
                end else if (flush_req && !flushed) begin
                    cfifo_wr_en   = 1'b1;
                    cfifo_wr_data = {1'b1, 31'h0};   // fix1018: flush flag must be bit31
                    flush_pushed  = 1'b1;
                    flushed_n     = 1'b1;
                end
            end
        end
    end

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            hv <= 1'b0; hv_low <= 1'b0; hv_src <= 1'b0;
            hb <= 25'h0; hdata <= 256'h0; hstrb <= 32'h0;
            bo <= 1'b0; bo_src <= 1'b0; bstart <= 25'h0; blast <= 25'h0;
            bn <= 4'h0; idle_cnt <= 6'h0;
            flushed <= 1'b0;
            wfifo_ovf <= 1'b0; wmax_level <= 16'h0; pushed_beats <= 32'h0;
            cfifo_ovf <= 1'b0;   // fix1018hw
        end else begin
            hv       <= hv_n;
            hv_low   <= hv_low_n;
            hv_src   <= hv_src_n;
            hb       <= hb_n;
            hdata    <= hdata_n;
            hstrb    <= hstrb_n;
            bo       <= bo_n;
            bo_src   <= bo_src_n;
            bstart   <= bstart_n;
            blast    <= blast_n;
            bn       <= bn_n;
            idle_cnt <= idle_cnt_n;
            flushed  <= flushed_n;
            if (clr_stat_r) begin
                wfifo_ovf  <= 1'b0;
                cfifo_ovf  <= 1'b0;   // fix1018hw
                wmax_level <= 16'h0;
                pushed_beats <= 32'h0;
            end else begin
                if (wfifo_wr_en && wfifo_wr_full) wfifo_ovf <= 1'b1;
                if (cfifo_wr_en && cfifo_wr_full) cfifo_ovf <= 1'b1;   // fix1018hw
                if (wfifo_wr_en && !wfifo_wr_full) pushed_beats <= pushed_beats + 1'b1;
                if ((wfifo_wr_level + {9'b0, wfifo_wr_en}) > {1'b0, wmax_level})
                    wmax_level <= wfifo_wr_level + {9'b0, wfifo_wr_en};
            end
        end

    //========================================================================
    // async FIFOs
    //========================================================================
    rt_async_fifo #(.DW(288), .AW(WFIFO_AW)) u_wfifo (
        .wr_clk(pclk),   .wr_rst_n(rst_p_sync), .wr_en(wfifo_wr_en),
        .wr_data(wfifo_wr_data), .wr_full(wfifo_wr_full), .wr_level(wfifo_wr_level),
        .rd_clk(ddr_clk), .rd_rst_n(rst_d_sync), .rd_en(wfifo_rd_en),
        .rd_data(wfifo_rd_data), .rd_valid(wfifo_rd_valid),
        .rd_empty(wfifo_rd_empty), .rd_level(wfifo_rd_level));

    rt_async_fifo #(.DW(32), .AW(CFIFO_AW)) u_cfifo (
        .wr_clk(pclk),   .wr_rst_n(rst_p_sync), .wr_en(cfifo_wr_en),
        .wr_data(cfifo_wr_data), .wr_full(cfifo_wr_full), .wr_level(cfifo_wr_level),
        .rd_clk(ddr_clk), .rd_rst_n(rst_d_sync), .rd_en(cfifo_rd_en),
        .rd_data(cfifo_rd_data), .rd_valid(cfifo_rd_valid),
        .rd_empty(cfifo_rd_empty), .rd_level(cfifo_rd_level));

    rt_async_fifo #(.DW(256), .AW(RFIFO_AW)) u_rfifo (
        .wr_clk(ddr_clk), .wr_rst_n(rst_d_sync), .wr_en(rfifo_wr_en),
        .wr_data(rfifo_wr_data), .wr_full(rfifo_wr_full), .wr_level(rfifo_wr_level),
        .rd_clk(pclk),   .rd_rst_n(rst_p_sync), .rd_en(rfifo_rd_en),
        .rd_data(rfifo_rd_data), .rd_valid(rfifo_rd_valid),
        .rd_empty(rfifo_rd_empty), .rd_level(rfifo_rd_level));

    // 20261027 cam : o_issue_hold also pauses the MRd issue when the camera
    // write FIFO runs full (i_cam_urgent).  i_issue_hold in
    // rt0202_dma_mrd_ctrl only gates "fire" (a new MRd TLP), so in flight
    // completions are still received and written -> PCIe data is never lost,
    // the doorbell transfer just starts a few us later.
    // 20261027 cam9 : urgent protection timeout (100 us @ 125 MHz = 12500 cycles)
    localparam [15:0] URG_MAX_CYC = 16'd12500;
    reg [15:0] urg_cnt;
    reg        urg_timeout;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            urg_cnt     <= 16'd0;
            urg_timeout <= 1'b0;
        end else if (!i_cam_urgent) begin
            urg_cnt     <= 16'd0;
            urg_timeout <= 1'b0;
        end else if (!urg_timeout) begin
            if (urg_cnt >= (URG_MAX_CYC - 1'b1))
                urg_timeout <= 1'b1;
            else
                urg_cnt <= urg_cnt + 1'b1;
        end

    wire hold_level = (wfifo_wr_level >= HOLD_TH);
    assign o_issue_hold = hold_level | (i_cam_urgent & ~urg_timeout);

    reg cam_urg_d;
    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            cam_urg_d     <= 1'b0;
            o_cam_urg_cnt <= 32'h0;
        end else begin
            cam_urg_d <= i_cam_urgent;
            if (i_cam_urgent && !cam_urg_d && (o_cam_urg_cnt != 32'hFFFF_FFFF))
                o_cam_urg_cnt <= o_cam_urg_cnt + 1'b1;
        end

    //========================================================================
    // F. AXI write master (ddr_clk)
    //========================================================================
    localparam W_IDLE = 3'd0, W_CFGET = 3'd1, W_FETCH = 3'd2,
               W_ADDR = 3'd3, W_DATA  = 3'd4, W_FLUSH = 3'd5;

    reg [2:0]   wstate;
    reg [24:0]  cur_start;
    reg [3:0]   cur_nm1;
    reg [3:0]   cur_n;
    // 20261026 cam : command FIFO source tag
    //   0 = PCIe doorbell DMA : cur_start already includes base16
    //   1 = camera            : cur_start is the absolute camera address
    // The tag keeps the two address rules apart (a camera burst can never be
    // re-based with the doorbell cur_dst, and a DMA burst keeps its base).
    reg          cur_src /* synthesis PAP_MARK_DEBUG="1" */;
    reg  [31:0]  cam_beats /* synthesis PAP_MARK_DEBUG="1" */;
    reg [3:0]   req_cnt;                    // fix1018
    reg [3:0]   cap_cnt;                    // fix1018
    reg [3:0]   data_idx;
    reg [7:0]   flush_cnt;
    reg [287:0] wbuf [0:7];
    reg [31:0]  axi_bursts, axi_beats;

    assign axi_awaddr = {cur_start, 3'b000};
    assign axi_awlen  = {1'b0, cur_nm1};
    assign axi_wdata  = wbuf[data_idx][255:0];
    assign axi_wstrb  = wbuf[data_idx][287:256];

    always @(posedge ddr_clk or negedge ddr_rst_n)
        if (!ddr_rst_n) begin
            wstate     <= W_IDLE;
            axi_awvalid<= 1'b0;
            cfifo_rd_en<= 1'b0;
            wfifo_rd_en<= 1'b0;
            cur_start  <= 25'h0;
            cur_src    <= 1'b0;
            cam_beats  <= 32'h0;
            cur_nm1    <= 4'h0;
            cur_n      <= 4'h0;
            req_cnt    <= 4'h0;         // fix1018
            cap_cnt    <= 4'h0;         // fix1018
            data_idx   <= 4'h0;
            flush_cnt  <= 8'h0;
            axi_bursts <= 32'h0;
            axi_beats  <= 32'h0;
            flush_ack_t<= 1'b0;
        end else begin
            cfifo_rd_en <= 1'b0;
            wfifo_rd_en <= 1'b0;
            case (wstate)
                W_IDLE: if (!cfifo_rd_empty) begin
                            cfifo_rd_en <= 1'b1;
                            wstate      <= W_CFGET;
                        end
                W_CFGET: if (cfifo_rd_valid) begin        // fix1018
                            if (cfifo_rd_data[31]) begin
                                flush_cnt <= 8'h0;
                                wstate    <= W_FLUSH;
                            end else begin
                                cur_start <= cfifo_rd_data[24:0];
                                cur_src   <= cfifo_rd_data[25];   // 20261026 cam
                                cur_nm1   <= cfifo_rd_data[30:27];          // fix1018
                                cur_n     <= cfifo_rd_data[30:27] + 1'b1;   // fix1018
                                req_cnt   <= 4'h0;                          // fix1018
                                cap_cnt   <= 4'h0;                          // fix1018
                                wstate    <= W_FETCH;
                            end
                        end
                W_FETCH: begin
                            // issue up to cur_n reads once enough data present  // fix1018
                            if ((req_cnt != cur_n) &&
                                ((req_cnt != 4'h0) || (wfifo_rd_level >= cur_n))) begin
                                wfifo_rd_en <= 1'b1;
                                req_cnt     <= req_cnt + 1'b1;
                            end
                            if (wfifo_rd_valid) begin
                                wbuf[cap_cnt] <= wfifo_rd_data;
                                if ((cap_cnt + 1'b1) == cur_n) begin
                                    cap_cnt <= 4'h0;
                                    wstate  <= W_ADDR;
                                end else begin
                                    cap_cnt <= cap_cnt + 1'b1;
                                end
                            end
                        end
                W_ADDR: begin
                            axi_awvalid <= 1'b1;
                            axi_bursts  <= axi_bursts + 1'b1;
                            wstate      <= W_DATA;
                            data_idx    <= 4'h0;
                        end
                W_DATA: begin
                            if (axi_awready) axi_awvalid <= 1'b0;
                            if (axi_wready) begin
                                axi_beats <= axi_beats + 1'b1;
                                if (cur_src) cam_beats <= cam_beats + 1'b1;
                                if (data_idx == (cur_n - 1'b1)) begin
                                    axi_awvalid <= 1'b0;
                                    wstate      <= W_IDLE;
                                end else begin
                                    data_idx <= data_idx + 1'b1;
                                end
                            end
                        end
                W_FLUSH: begin
                            if (flush_cnt == 8'd64) begin
                                flush_ack_t <= ~flush_ack_t;
                                wstate      <= W_IDLE;
                            end else begin
                                flush_cnt <= flush_cnt + 1'b1;
                            end
                        end
                default: wstate <= W_IDLE;
            endcase
        end

    // sync ddr counters to pclk
    wire [31:0] axi_bursts_p, axi_beats_p;
    rt_sync2 #(.WIDTH(32)) u_sync_bursts (
        .clk(pclk), .rst_n(rst_p_sync), .d(axi_bursts), .q(axi_bursts_p));
    rt_sync2 #(.WIDTH(32)) u_sync_beats (
        .clk(pclk), .rst_n(rst_p_sync), .d(axi_beats), .q(axi_beats_p));

    //========================================================================
    // G. readback : ddr read engine
    //========================================================================
    localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_AR = 2'd2, R_DATA = 2'd3;

    reg [1:0]   rd_state;
    reg [15:0]  rburst_i;
    reg [3:0]   rbeat;
    reg         rfifo_ovf;

    // rb_req_t toggle (pclk)
    reg rb_req_t;
    always @(posedge pclk or negedge rst_p_sync)
        if (!rst_p_sync) rb_req_t <= 1'b0;
        else if (rb_start_r) rb_req_t <= ~rb_req_t;

    // latch params at start (pclk)
    reg [25:0] rb_src4;
    reg [15:0] rb_nbursts;
    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin rb_src4 <= 26'h0; rb_nbursts <= 16'h0; end
        else if (rb_start_r) begin
            rb_src4    <= rb_src_r >> 2;
            rb_nbursts <= rb_len_r >> 9;
        end

    // sync rb_req_t into ddr, edge detect
    wire rb_req_s;
    rt_sync2 #(.WIDTH(1)) u_sync_rbreq (
        .clk(ddr_clk), .rst_n(rst_d_sync), .d(rb_req_t), .q(rb_req_s));
    reg rb_req_s_d;
    always @(posedge ddr_clk or negedge rst_d_sync)
        if (!rst_d_sync) rb_req_s_d <= 1'b0;
        else             rb_req_s_d <= rb_req_s;
    wire rb_req_edge = rb_req_s ^ rb_req_s_d;

    assign axi_araddr = rb_src4 + {rburst_i, 7'b0};
    assign axi_arlen  = 4'hF;

    always @(posedge ddr_clk or negedge ddr_rst_n)
        if (!ddr_rst_n) begin
            rd_state   <= R_IDLE;
            axi_arvalid<= 1'b0;
            rburst_i   <= 16'h0;
            rbeat      <= 4'h0;
            rfifo_wr_en<= 1'b0;
            rfifo_wr_data <= 256'h0;
            rfifo_ovf  <= 1'b0;
        end else begin
            rfifo_wr_en <= 1'b0;
            case (rd_state)
                R_IDLE: if (rb_req_edge) begin
                            rburst_i <= 16'h0;
                            rd_state <= R_WAIT;
                        end
                R_WAIT: if (rfifo_wr_level <= ((1 << RFIFO_AW) - 32)) begin
                            axi_arvalid <= 1'b1;
                            rd_state    <= R_AR;
                        end
                R_AR:   if (axi_arready) begin
                            axi_arvalid <= 1'b0;
                            rbeat       <= 4'h0;
                            rd_state    <= R_DATA;
                        end
                R_DATA: if (axi_rvalid) begin
                            rfifo_wr_en   <= 1'b1;
                            rfifo_wr_data <= axi_rdata;
                            if (rfifo_wr_full) rfifo_ovf <= 1'b1;
                            rbeat <= rbeat + 1'b1;
                            if (axi_rlast) begin
                                if ((rburst_i + 1'b1) == rb_nbursts)
                                    rd_state <= R_IDLE;
                                else begin
                                    rburst_i <= rburst_i + 1'b1;
                                    rd_state <= R_WAIT;
                                end
                            end
                        end
                default: rd_state <= R_IDLE;
            endcase
        end

    wire rfifo_ovf_s;
    rt_sync2 #(.WIDTH(1)) u_sync_rfovf (
        .clk(pclk), .rst_n(rst_p_sync), .d(rfifo_ovf), .q(rfifo_ovf_s));

    //------------------------------------------------------------------------
    // G. readback : pclk RAM writer
    //------------------------------------------------------------------------
    localparam RB_IDLE = 2'd0, RB_GET = 2'd1, RB_W0 = 2'd2, RB_W1 = 2'd3;

    reg [1:0]   rb_rd_state;
    reg [31:0]  rb_expect, rb_got, wcnt;
    reg [255:0] rb_word;
    reg         copy_pending;
    reg [127:0] copy_data;
    reg [11:0]  copy_addr;

    assign o_copy_wr_en   = copy_pending & ~i_dma_wr_en;
    assign o_copy_wr_addr = copy_addr;
    assign o_copy_wr_data = copy_data;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            rb_rd_state  <= RB_IDLE;
            rb_busy      <= 1'b0;
            rb_expect    <= 32'h0;
            rb_got       <= 32'h0;
            wcnt         <= 32'h0;
            rb_word      <= 256'h0;
            copy_pending <= 1'b0;
            copy_data    <= 128'h0;
            copy_addr    <= 12'h0;
            rfifo_rd_en  <= 1'b0;
            rb_beats     <= 32'h0;
            rb_done_cnt  <= 32'h0;
        end else begin
            rfifo_rd_en <= 1'b0;
            if (clr_stat_r) begin rb_beats <= 32'h0; rb_done_cnt <= 32'h0; end
            if (rb_start_r && !rb_busy) begin
                rb_busy   <= 1'b1;
                rb_expect <= rb_len_r >> 5;
                rb_got    <= 32'h0;
                wcnt      <= 32'h0;
            end
            case (rb_rd_state)
                RB_IDLE: if (rb_busy && !rfifo_rd_empty) begin
                             rfifo_rd_en  <= 1'b1;
                             rb_rd_state  <= RB_GET;
                         end
                RB_GET:  if (rfifo_rd_valid) begin        // fix1018
                             rb_word      <= rfifo_rd_data;
                             copy_data    <= rfifo_rd_data[127:0];
                             copy_addr    <= rb_ramoff_r + wcnt[11:0];
                             copy_pending <= 1'b1;
                             rb_rd_state  <= RB_W0;
                         end
                RB_W0:   if (o_copy_wr_en) begin
                             wcnt         <= wcnt + 1'b1;
                             copy_data    <= rb_word[255:128];
                             copy_addr    <= rb_ramoff_r + wcnt[11:0] + 12'h1;
                             rb_rd_state  <= RB_W1;
                         end
                RB_W1:   if (o_copy_wr_en) begin
                             wcnt         <= wcnt + 1'b1;
                             copy_pending <= 1'b0;
                             rb_got       <= rb_got + 1'b1;
                             rb_beats     <= rb_beats + 1'b1;
                             if ((rb_got + 1'b1) == rb_expect) begin
                                 rb_busy     <= 1'b0;
                                 rb_done_cnt <= rb_done_cnt + 1'b1;
                             end
                             rb_rd_state  <= RB_IDLE;
                         end
                default: rb_rd_state <= RB_IDLE;
            endcase
        end

    //========================================================================
    // H. status words
    //========================================================================
    assign o_stat1c0 = { last_id,
                         done_cnt,
                         push_cnt,
                         {ovf_cnt[15:0], 2'b0, commit_state, eng_state, 1'b0,
                          q_full, 3'b0, q_level} };
    assign o_stat1d0 = { rb_done_cnt,
                         axi_bursts_p,
                         pushed_beats,
                         {wmax_level, 8'b0, cfifo_ovf, rb_busy, rfifo_ovf_s, wfifo_ovf,   // fix1018hw: bit7 cfifo_ovf
                          commit_busy, hold_level, ddr_en_eff, init_p} };
    assign o_stat1e0 = { rb_beats,
                         32'h44445231,
                         axi_beats_p,
                         last_db_cycles };

endmodule
