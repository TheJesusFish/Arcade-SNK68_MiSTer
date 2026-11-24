// SNK68 save states: sequencer (68000 IPL7 handler / reset restore, Z80 park), chunk adaptors, YM3812 register shadow
import system_consts::*;

module snk68_ss (
    input             clk,
    input             reset,

    input             ss_save,
    input             ss_load,
    input       [1:0] ss_slot,
    output reg        ss_saved,      // one-cycle pulse: the save finished writing slot ss_saved_slot
    output      [1:0] ss_saved_slot,

    ddr_if.to_host    ddr,
    ssbus_if.master   ssbus,
    ssbus_if.slave    ss_ssp,

    // 68000 bus
    input             cen68,
    input      [23:1] m68k_a,
    input             m68k_as_n,
    input             m68k_uds_n,
    input             m68k_lds_n,
    input             m68k_rw,
    input       [2:0] m68k_fc,
    input      [15:0] m68k_dout,

    // frame position {line, pixel, pixel-clock phase}: the 68000 resumes where it stopped
    input      [21:0] vpos,
    output reg [21:0] vpos_saved,
    input      [21:0] vpos_load,

    output reg        hold68,
    output reg        run68,
    output reg        reset68,
    output reg        ipl7,
    output            ovr_hit,
    output reg [15:0] ovr_data,

    // Z80
    input             z80_m1_n,
    output            z_hold,
    output reg        z_reset,
    output reg        z_dirset,

    // sound chips
    output reg        snd_reset,
    output            opl_run,
    output reg        opl_replay,
    input             opl_replay_busy,

    output            active,
    output            park68,
    output            cache_flush,
    output reg        board_load,
    output reg        nmi_retrigger
);

typedef enum logic [3:0] {
    ST_IDLE,
    ST_PARKZ,
    ST_SAVE_IRQ,
    ST_SAVE_SSP,
    ST_SAVE_HDR,
    ST_SAVE_WRITE,
    ST_SAVE_SYNC,
    ST_SAVE_EXIT,
    ST_LOAD_READ,
    ST_LOAD_SNDRST,
    ST_LOAD_OPL,
    ST_LOAD_Z80,
    ST_LOAD_68RST,
    ST_LOAD_68RUN,
    ST_LOAD_68SYNC,
    ST_LOAD_68EXIT
} ss_state_t;

ss_state_t st = ST_IDLE;

// level-7 handler at $3F0000 (unmapped on all three boards); restore resumes at $3F0008
logic [15:0] HANDLER [16] = '{
    16'h48e7, 16'hfffe,            // movem.l d0-d7/a0-a6,-(a7)
    16'h4e6e,                      // move.l usp,a6
    16'h2f0e,                      // move.l a6,-(a7)
    16'h4df9, 16'h003f, 16'h0000,  // lea $3f0000,a6
    16'h2c8f,                      // move.l a7,(a6)
    16'h2c5f,                      // move.l (a7)+,a6
    16'h4e66,                      // move.l a6,usp
    16'h4cdf, 16'h7fff,            // movem.l (a7)+,d0-d7/a0-a6
    16'h4e73,                      // rte
    16'h0000, 16'h0000, 16'h0000
};

reg  [31:0] ssp_saved, ssp_restore;
reg   [1:0] slot_l;
reg         ss_write, ss_read;
wire        ss_busy;
reg   [6:0] cnt;
reg         m1_l;
reg         z_hold_r;
reg         rp_start;
reg         got_state;
reg         hd_start, hd_done;
reg         loading;

wire        ds        = ~m68k_uds_n | ~m68k_lds_n;
wire        in_hdl    = m68k_a[23:5] == 19'h1f800;
wire        in_vec    = m68k_a[23:2] == 22'h00001f;
wire        in_rst    = m68k_a[23:3] == 21'h0;
wire        prog_rd   = ~m68k_as_n & ds & m68k_rw & m68k_fc[1:0] == 2'b10;
wire        iack7     = ~m68k_as_n & m68k_fc == 3'b111 & m68k_a[3:1] == 3'b111;

wire        save_ovr  = st == ST_SAVE_SSP || st == ST_SAVE_HDR || st == ST_SAVE_WRITE || st == ST_SAVE_SYNC || st == ST_SAVE_EXIT;
wire        load_ovr  = st == ST_LOAD_68RST || st == ST_LOAD_68RUN || st == ST_LOAD_68SYNC || st == ST_LOAD_68EXIT;
// the handler's write of the low SSP word: the 68000 is held here on save and on restore
wire        ssp_lo_wr = ~m68k_as_n & ~m68k_rw & ds & in_hdl & m68k_a[1];

assign active  = st != ST_IDLE;
// restore: the board ignores the 68000's unfinished bus cycle from the first restored write until the 68000 restarts
assign park68  = st == ST_LOAD_SNDRST || st == ST_LOAD_OPL || st == ST_LOAD_Z80 || st == ST_LOAD_68RST;
assign ss_saved_slot = slot_l;
assign opl_run = st == ST_LOAD_OPL;
// the 68000 ROM cache restarts empty while the 68000 waits at the sync point, on save and on restore
assign cache_flush = st == ST_SAVE_SYNC || st == ST_LOAD_68SYNC;
assign ovr_hit = (save_ovr | load_ovr) & ~m68k_as_n & ds & m68k_rw &
                 (in_hdl | (save_ovr & in_vec) | (load_ovr & in_rst));
// Z80 stops on the cycle its M1 falls (T1 of an opcode fetch)
assign z_hold  = z_hold_r | (st == ST_PARKZ & m1_l & ~z80_m1_n);

always_comb begin
    ovr_data = 16'h0000;
    if (in_hdl)
        ovr_data = HANDLER[m68k_a[4:1]];
    else if (in_vec)
        ovr_data = m68k_a[1] ? 16'h0000 : 16'h003f;
    else if (in_rst)
        case (m68k_a[2:1])
            2'd0: ovr_data = ssp_restore[31:16];
            2'd1: ovr_data = ssp_restore[15:0];
            2'd2: ovr_data = 16'h003f;
            2'd3: ovr_data = 16'h0008;
        endcase
end

always_comb begin
    hold68 = 0; run68 = 0; reset68 = 0; ipl7 = 0;
    z_reset = 0; snd_reset = 0;
    case (st)
        ST_PARKZ:       hold68 = 1;
        ST_SAVE_IRQ:    begin run68 = 1; ipl7 = 1; end
        ST_SAVE_SSP:    run68 = 1;
        ST_SAVE_HDR:    hold68 = 1;
        ST_SAVE_WRITE:  hold68 = 1;
        ST_SAVE_SYNC:   hold68 = 1;
        ST_SAVE_EXIT:   run68 = 1;
        ST_LOAD_READ:   hold68 = 1;
        ST_LOAD_SNDRST: begin hold68 = 1; z_reset = 1; snd_reset = 1; end
        ST_LOAD_OPL:    begin hold68 = 1; z_reset = 1; end
        ST_LOAD_Z80:    hold68 = 1;
        ST_LOAD_68RST:  begin run68 = 1; reset68 = 1; end
        ST_LOAD_68RUN:  run68 = 1;
        ST_LOAD_68SYNC: hold68 = 1;
        ST_LOAD_68EXIT: run68 = 1;
        default: ;
    endcase
end

// chunk 0: 68000 supervisor stack pointer
always_ff @(posedge clk) begin
    ss_ssp.setup(0, 1, 3);
    if (st == ST_IDLE) got_state <= 0;
    if (ss_ssp.access(0)) begin
        if (ss_ssp.write) begin
            ssp_restore <= ss_ssp.data[31:0];
            got_state   <= 1;
            ss_ssp.write_ack(0);
        end else if (ss_ssp.read) begin
            ss_ssp.read_response(0, {32'd0, ssp_saved});
        end
    end
end

always_ff @(posedge clk) begin
    m1_l          <= z80_m1_n;
    board_load    <= 0;
    nmi_retrigger <= 0;
    rp_start      <= 0;
    z_dirset      <= 0;
    hd_start      <= 0;
    ss_saved      <= 0;
    if (reset) begin
        st       <= ST_IDLE;
        ss_write <= 0;
        ss_read  <= 0;
        z_hold_r <= 0;
    end else begin
        case (st)
            ST_IDLE: begin
                z_hold_r <= 0;
                slot_l   <= ss_slot;  // save / restore the slot shown when the request is accepted
                if (ss_save)      begin st <= ST_PARKZ; loading <= 0; end
                else if (ss_load) begin st <= ST_PARKZ; loading <= 1; end
            end

            // save and restore both wait for the Z80's next opcode fetch, so no Z80 write is in flight
            ST_PARKZ:
                if (z_hold) begin
                    z_hold_r <= 1;
                    if (loading) begin st <= ST_LOAD_READ; ss_read <= 1; end
                    else st <= ST_SAVE_IRQ;
                end

            ST_SAVE_IRQ:
                if (iack7) st <= ST_SAVE_SSP;

            ST_SAVE_SSP:
                if (~m68k_as_n & ~m68k_rw & ds & in_hdl) begin
                    if (~m68k_a[1]) ssp_saved[31:16] <= m68k_dout;
                    else begin
                        ssp_saved[15:0] <= m68k_dout;
                        vpos_saved <= vpos;
                        hd_start <= 1;
                        st <= ST_SAVE_HDR;
                    end
                end

            // the slot reads as empty until the stream writes its new header
            ST_SAVE_HDR:
                if (hd_done) begin ss_write <= 1; st <= ST_SAVE_WRITE; end

            ST_SAVE_WRITE:
                if (ss_busy & ss_write) ss_write <= 0;
                else if (~ss_busy & ~ss_write) begin ss_saved <= 1; st <= ST_SAVE_SYNC; end

            ST_SAVE_SYNC:
                if (vpos == vpos_saved) st <= ST_SAVE_EXIT;

            ST_SAVE_EXIT:
                if (prog_rd & ~in_hdl) st <= ST_IDLE;

            // an empty slot delivers no chunks: both CPUs simply resume
            ST_LOAD_READ:
                if (ss_busy & ss_read) ss_read <= 0;
                else if (~ss_busy & ~ss_read) begin
                    cnt <= 0;
                    st  <= got_state ? ST_LOAD_SNDRST : ST_IDLE;
                end

            ST_LOAD_SNDRST: begin
                cnt <= cnt + 1'd1;
                if (&cnt) begin
                    board_load <= 1;
                    rp_start   <= 1;
                    st <= ST_LOAD_OPL;
                end
            end

            ST_LOAD_OPL:
                if (~rp_start & ~opl_replay_busy) begin
                    cnt <= 0;
                    st  <= ST_LOAD_Z80;
                end

            ST_LOAD_Z80: begin
                z_dirset <= 1;
                cnt <= cnt + 1'd1;
                if (cnt == 7'd15) begin cnt <= 0; st <= ST_LOAD_68RST; end
            end

            ST_LOAD_68RST:
                if (cen68) begin
                    cnt <= cnt + 1'd1;
                    if (&cnt[5:0]) st <= ST_LOAD_68RUN;
                end

            ST_LOAD_68RUN:
                if (ssp_lo_wr) st <= ST_LOAD_68SYNC;

            ST_LOAD_68SYNC:
                if (vpos == vpos_load) st <= ST_LOAD_68EXIT;

            ST_LOAD_68EXIT:
                if (prog_rd & ~in_hdl & ~in_rst) begin
                    nmi_retrigger <= 1;
                    st <= ST_IDLE;
                end

            default: st <= ST_IDLE;
        endcase
    end
end

always_comb opl_replay = rp_start;

// slot header (length, change counter) and stream share the save-state DDR port
ddr_if ddr_hd();
ddr_if ddr_ms();
ddr_mux hd_mux (.clk(clk), .x(ddr), .a(ddr_hd), .b(ddr_ms));

typedef enum logic [2:0] { HD_IDLE, HD_RD, HD_RD_WAIT, HD_WR, HD_WR_WAIT } hd_state_t;
hd_state_t  hd = HD_IDLE;
reg  [31:0] hd_count;
wire [31:0] slot_base = SS_DDR_BASE + {8'd0, slot_l, 22'd0};

assign ddr_hd.burstcnt   = 8'd1;
assign ddr_hd.byteenable = 8'hff;

// header length set to 0 with the change counter kept: an interrupted save leaves an empty slot
always_ff @(posedge clk) begin
    hd_done <= 0;
    if (reset) begin
        hd             <= HD_IDLE;
        ddr_hd.acquire <= 0;
        ddr_hd.read    <= 0;
        ddr_hd.write   <= 0;
    end else case (hd)
        HD_IDLE:
            if (hd_start) begin ddr_hd.acquire <= 1; hd <= HD_RD; end
        HD_RD:
            if (~ddr_hd.busy) begin ddr_hd.read <= 1; ddr_hd.addr <= slot_base; hd <= HD_RD_WAIT; end
        HD_RD_WAIT:
            if (~ddr_hd.busy) begin
                ddr_hd.read <= 0;
                if (ddr_hd.rdata_ready) begin hd_count <= ddr_hd.rdata[31:0]; hd <= HD_WR; end
            end
        HD_WR:
            if (~ddr_hd.busy) begin
                ddr_hd.write <= 1;
                ddr_hd.addr  <= slot_base;
                ddr_hd.wdata <= {32'd0, hd_count};
                hd <= HD_WR_WAIT;
            end
        HD_WR_WAIT:
            if (~ddr_hd.busy) begin
                ddr_hd.write   <= 0;
                ddr_hd.acquire <= 0;
                hd_done        <= 1;
                hd             <= HD_IDLE;
            end
        default: hd <= HD_IDLE;
    endcase
end

save_state_data save_state_data (
    .clk(clk),
    .reset(reset),
    .ddr(ddr_ms),
    .read_start(ss_read),
    .write_start(ss_write),
    .index(slot_l),
    .busy(ss_busy),
    .ssbus(ssbus)
);

endmodule

// RAM chunk: muxes one RAM port to the stream while the stream addresses it (one-cycle read latency)
module ss_ram_adaptor #(parameter AW = 13, parameter DW = 16, parameter SS_IDX = 1) (
    input               clk,
    ssbus_if.slave      ssbus,
    output              sel,
    output     [AW-1:0] addr,
    output     [DW-1:0] din,
    output              we,
    input      [DW-1:0] q
);
localparam int WCODE = DW == 8 ? 0 : DW == 16 ? 1 : DW == 32 ? 2 : 3;
assign sel  = ssbus.access(SS_IDX);
assign addr = ssbus.addr[AW-1:0];
assign din  = ssbus.data[DW-1:0];
assign we   = sel & ssbus.write;

reg read_delay;
always_ff @(posedge clk) begin
    ssbus.setup(SS_IDX, 32'd1 << AW, WCODE);
    if (sel) begin
        if (ssbus.write) ssbus.write_ack(SS_IDX);
        else if (ssbus.read) begin
            if (read_delay) ssbus.read_response(SS_IDX, {{(64-DW){1'b0}}, q});
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end
endmodule

// Register chunk: WORDS x 64 bits, read from cur, written to saved
module ss_reg_chunk #(parameter WORDS = 1, parameter SS_IDX = 0) (
    input                     clk,
    ssbus_if.slave            ssbus,
    input  [64*WORDS-1:0]     cur,
    output reg [64*WORDS-1:0] saved
);
localparam int IW = WORDS > 1 ? $clog2(WORDS) : 1;
wire [IW-1:0] w = ssbus.addr[IW-1:0];
always_ff @(posedge clk) begin
    ssbus.setup(SS_IDX, WORDS, 3);
    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            saved[w*64 +: 64] <= ssbus.data;
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, cur[w*64 +: 64]);
        end
    end
end
endmodule

// YM3812 register shadow (snooped writes) saved as 256 registers + selected register, replayed on restore
module snk68_opl_shadow #(parameter SS_IDX = 8) (
    input             clk,
    ssbus_if.slave    ssbus,
    input             snoop_wr,
    input             snoop_a,
    input       [7:0] snoop_d,
    input             replay,
    output            busy,
    output reg        rp_cs,
    output reg        rp_a,
    output reg  [7:0] rp_d
);
reg  [7:0] mem [0:255];
reg  [7:0] sel, sel_saved;
reg  [7:0] q;
reg  [8:0] rp_reg;
reg [11:0] rp_cnt;
reg  [1:0] rp_ph;
reg        rp_on = 0;
reg        read_delay;

wire       acc    = ssbus.access(SS_IDX);
wire [8:0] caddr  = ssbus.addr[8:0];
wire       cwr    = acc & ssbus.write & ~caddr[8];
wire [7:0] raddr  = rp_on ? rp_reg[7:0] : caddr[7:0];

assign busy = rp_on;

// timer-control writes with bit 7 (IRQ reset) leave the stored timer start / mask bits as the chip does
wire       snoop_keep = sel == 8'h04 && snoop_d[7];

always_ff @(posedge clk) begin
    if (snoop_wr & snoop_a & ~snoop_keep) mem[sel] <= snoop_d;
    else if (cwr) mem[caddr[7:0]] <= ssbus.data[7:0];
    q <= mem[raddr];
end

always_ff @(posedge clk) begin
    if (snoop_wr & ~snoop_a) sel <= snoop_d;

    ssbus.setup(SS_IDX, 264, 0);
    if (acc) begin
        if (ssbus.write) begin
            if (caddr == 9'd256) sel_saved <= ssbus.data[7:0];
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (read_delay) ssbus.read_response(SS_IDX, {56'd0, caddr[8] ? (caddr == 9'd256 ? sel : 8'd0) : q});
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

// replay: per register an address write, then a data write, each held 36 clk, then 2000 clk for the slot update
always_ff @(posedge clk) begin
    rp_cs <= 0;
    if (replay & ~rp_on) begin
        rp_on  <= 1;
        rp_reg <= 0;
        rp_ph  <= 0;
        rp_cnt <= 0;
    end else if (rp_on) begin
        rp_cnt <= rp_cnt + 1'd1;
        case (rp_ph)
            2'd0: begin
                rp_cs <= rp_cnt < 12'd36;
                rp_a  <= 0;
                rp_d  <= rp_reg[8] ? sel_saved : rp_reg[7:0];
                if (rp_cnt == 12'd80) begin
                    rp_cnt <= 0;
                    if (rp_reg[8]) rp_on <= 0;
                    else rp_ph <= 2'd1;
                end
            end
            2'd1: begin
                rp_cs <= rp_cnt < 12'd36;
                rp_a  <= 1;
                rp_d  <= q;
                if (rp_cnt == 12'd2000) begin
                    rp_cnt <= 0;
                    rp_reg <= rp_reg + 1'd1;
                    rp_ph  <= 2'd0;
                end
            end
            default: rp_ph <= 2'd0;
        endcase
    end
end
endmodule
