// High scores: hiscore.dat entries (MRA index 3) checked in 68000 work RAM, saved table (NVRAM index 4) written back once
module snk68_hiscore #(parameter MAXE = 4) (
    input             clk,
    input             reset,
    input             vblank,

    input             ioctl_download,
    input             ioctl_upload,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input       [7:0] ioctl_dout,
    input      [15:0] ioctl_index,
    output      [7:0] ioctl_din,
    output reg        upload_req,
    input             osd_open,
    input             autosave,
    input             save_now,
    output            has_entries,

    input             port_busy,
    input             cpu_busy,
    output            ram_sel,
    output     [13:0] ram_addr,
    output      [7:0] ram_din,
    output            ram_we,
    input       [7:0] ram_q
);

localparam [23:0] RAM_BASE = 24'h040000;

reg  [7:0] ent [0:MAXE*8-1];
reg  [3:0] n_ent = 0;
reg  [7:0] tbl [0:1023];
reg        have_tbl = 0;

wire       dl_ent = ioctl_download & ioctl_index == 16'd3;
wire       dl_tbl = ioctl_download & ioctl_index == 16'd4;
wire       ul     = ioctl_upload & ioctl_index == 16'd4;

reg  [9:0] tbl_ra;
reg  [7:0] tbl_q;
// an upload also keeps each byte it sends (once its address has been stable past the RAM read) as the table the next reset restores
reg  [2:0] ul_d = 0;
reg [26:0] ul_a1, ul_a2, ul_a3;
// not while (or just after) a save state holds work-RAM port b: the byte read would be the stream's
reg  [2:0] pb_d = 0;
wire       ul_cap = ul_d[2] & ~port_busy & ~|pb_d & ioctl_addr < 1024 & ioctl_addr == ul_a1 & ioctl_addr == ul_a2 & ioctl_addr == ul_a3;
wire       tbl_we = (ioctl_wr & dl_tbl & ioctl_addr < 1024) | ul_cap;
wire [9:0] tbl_wa = ioctl_addr[9:0];
wire [7:0] tbl_wd = ul_cap ? ram_q : ioctl_dout;
always_ff @(posedge clk) begin
    tbl_q <= tbl[tbl_ra];
    ul_d  <= {ul_d[1:0], ul};
    pb_d  <= {pb_d[1:0], port_busy};
    ul_a1 <= ioctl_addr; ul_a2 <= ul_a1; ul_a3 <= ul_a2;
    if (ioctl_wr & dl_ent & ioctl_addr < MAXE*8) begin
        ent[ioctl_addr[4:0]] <= ioctl_dout;
        if (ioctl_addr[2:0] == 3'd7) n_ent <= ioctl_addr[6:3] + 1'd1;
    end
    if (tbl_we) begin
        tbl[tbl_wa] <= tbl_wd;
        have_tbl <= 1;
    end
end

// entry fields: work-RAM byte offset, length, start and end bytes, first table offset
wire [23:0] e_addr [MAXE];
wire [15:0] e_len  [MAXE];
wire  [7:0] e_beg  [MAXE];
wire  [7:0] e_end  [MAXE];
wire [15:0] e_base [MAXE+1];
wire  [MAXE-1:0] e_ok;
assign e_base[0] = 16'd0;
genvar gi;
generate
for (gi = 0; gi < MAXE; gi = gi + 1) begin : g_ent
    assign e_addr[gi]   = {ent[gi*8+1], ent[gi*8+2], ent[gi*8+3]} - RAM_BASE;
    assign e_len[gi]    = {ent[gi*8+4], ent[gi*8+5]};
    assign e_beg[gi]    = ent[gi*8+6];
    assign e_end[gi]    = ent[gi*8+7];
    assign e_base[gi+1] = e_base[gi] + (gi < n_ent ? e_len[gi] : 16'd0);
    assign e_ok[gi]     = gi >= n_ent ||
                          ({ent[gi*8], ent[gi*8+1], ent[gi*8+2], ent[gi*8+3]} >= {8'd0, RAM_BASE} &&
                           {ent[gi*8], ent[gi*8+1], ent[gi*8+2], ent[gi*8+3]} + e_len[gi] <= {8'd0, RAM_BASE} + 32'h4000 &&
                           e_len[gi] != 0);
end
endgenerate

wire [15:0] total = e_base[MAXE];
assign has_entries = n_ent != 0 && &e_ok && total <= 16'd1024;

// table offset -> work-RAM byte address
function [13:0] map_off(input [15:0] off);
    integer i;
    begin
        map_off = 14'd0;
        for (i = 0; i < MAXE; i = i + 1)
            if (off >= e_base[i] && i < n_ent) map_off = e_addr[i][13:0] + (off - e_base[i]);
    end
endfunction

// check / restore sequencer
typedef enum logic [2:0] { H_WAIT, H_IDLE, H_RD_BEG, H_RD_END, H_NEXT, H_WRITE, H_DONE } hs_state_t;
hs_state_t hst = H_WAIT;

reg  [5:0] frames;
reg  [2:0] passes;
reg  [1:0] ei;
reg  [1:0] lat;
reg        all_ok;
reg [15:0] wo;
reg        vbl_l;
reg        table_ok;
reg [13:0] fsm_addr;
reg        fsm_sel;
reg  [7:0] fsm_din;

wire vbl_rise = vblank & ~vbl_l;
// one table byte per cycle in which neither the 68000 nor a save state uses work RAM
wire wr_go    = hst == H_WRITE && lat == 2'd2 && !port_busy && !cpu_busy && !ul;

always_ff @(posedge clk) begin
    vbl_l   <= vblank;
    if (reset) begin
        hst      <= H_WAIT;
        frames   <= 0;
        passes   <= 0;
        table_ok <= 0;
        fsm_sel  <= 0;
    end else case (hst)
        H_WAIT: if (vbl_rise) begin
            frames <= frames + 1'd1;
            if (&frames) hst <= has_entries ? H_IDLE : H_DONE;
        end
        H_IDLE: if (vbl_rise) begin
            ei <= 0; all_ok <= 1; lat <= 0;
            hst <= H_RD_BEG;
        end
        H_RD_BEG: begin
            fsm_sel  <= 1;
            fsm_addr <= e_addr[ei][13:0];
            if (port_busy) lat <= 0;
            else begin
                lat <= lat + 1'd1;
                if (lat == 2'd2) begin
                    if (ram_q != e_beg[ei]) all_ok <= 0;
                    lat <= 0;
                    hst <= H_RD_END;
                end
            end
        end
        H_RD_END: begin
            fsm_addr <= e_addr[ei][13:0] + e_len[ei][13:0] - 1'd1;
            if (port_busy) lat <= 0;
            else begin
                lat <= lat + 1'd1;
                if (lat == 2'd2) begin
                    if (ram_q != e_end[ei]) all_ok <= 0;
                    lat <= 0;
                    hst <= H_NEXT;
                end
            end
        end
        H_NEXT: begin
            fsm_sel <= 0;
            if (ei + 1'd1 < n_ent) begin ei <= ei + 1'd1; hst <= H_RD_BEG; end
            else if (!all_ok) begin passes <= 0; hst <= H_IDLE; end
            else if (passes == 3'd3) begin
                table_ok <= 1;
                wo  <= 0;
                tbl_ra <= 0;
                hst <= have_tbl ? H_WRITE : H_DONE;
            end else begin
                passes <= passes + 1'd1;
                hst <= H_IDLE;
            end
        end
        H_WRITE: begin
            fsm_sel <= 1;
            tbl_ra  <= wo[9:0];
            case (lat)
                2'd0: lat <= 2'd1;
                2'd1: begin fsm_addr <= map_off(wo); fsm_din <= tbl_q; lat <= 2'd2; end
                default: if (wr_go) begin
                    lat <= 0;
                    wo  <= wo + 1'd1;
                    tbl_ra <= wo[9:0] + 1'd1;
                    if (wo + 1'd1 == total) hst <= H_DONE;
                end
            endcase
        end
        H_DONE: fsm_sel <= 0;
        default: hst <= H_DONE;
    endcase
end

// upload: the live table read through the same port
assign ram_sel  = ul | fsm_sel;
assign ram_addr = ul ? map_off(ioctl_addr[15:0]) : fsm_addr;
assign ram_din  = fsm_din;
assign ram_we   = wr_go;
assign ioctl_din = ram_q;

reg osd_l, save_l;
always_ff @(posedge clk) begin
    osd_l  <= osd_open;
    save_l <= save_now;
    upload_req <= table_ok & has_entries & ((autosave & osd_open & ~osd_l) | (save_now & ~save_l));
end

endmodule
