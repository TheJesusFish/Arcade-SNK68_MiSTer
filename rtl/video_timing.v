
module video_timing
(
    input       clk,
    input       clk_pix,
    input       reset,

    input  signed [3:0] hs_offset,
    input  signed [3:0] vs_offset,

    input  signed [3:0] hs_width,
    input  signed [3:0] vs_width,

    output [8:0] hc,
    output [8:0] vc,

    output reg  hsync,
    output reg  vsync,

    output reg  hbl,
    output reg  vbl,

    output reg  hbl_d,
    output reg  vbl_d,
    output      frame_start
);

// OSD sync adjustments, sign-extended
wire [8:0] hso = {{5{hs_offset[3]}}, hs_offset};
wire [8:0] hsw = {{5{hs_width[3]}},  hs_width};
wire [9:0] vso = {{6{vs_offset[3]}}, vs_offset};
wire [4:0] vsl = 5'd9 + {vs_width[3], vs_width};

wire [8:0] h_ofs = 9'd0;
wire [8:0] HBL_START  = 9'd256 ;
wire [8:0] HBL_END    = 9'd0 ;
wire [8:0] HS_START   = HBL_START + 9'd41 + hso;
wire [8:0] HS_END     = HBL_START + 9'd73 + hso + hsw;
wire [8:0] HTOTAL     = 9'd383;

wire [8:0] v_ofs = 9'd0;
wire [8:0] VBL_START  = 9'd241 ;
wire [8:0] VBL_END    = 9'd17 ;
wire [8:0] VTOTAL     = 9'd263 ;
// V sync: 9 lines from line 257 by default, 1 to 16 lines, wrapped into the 264-line frame
wire [9:0] vs_start_calc = 10'd257 + vso;
wire [9:0] vs_end_calc   = vs_start_calc + {5'd0, vsl};
wire [9:0] vs_start_wr   = vs_start_calc - 10'd264;
wire [9:0] vs_end_wr     = vs_end_calc   - 10'd264;
wire [8:0] VS_START   = ( vs_start_calc < 10'd264 ) ? vs_start_calc[8:0] : vs_start_wr[8:0];
wire [8:0] VS_END     = ( vs_end_calc   < 10'd264 ) ? vs_end_calc[8:0]   : vs_end_wr[8:0];


reg [8:0] v = 9'd0;
reg [8:0] h = 9'd0;

initial begin
    hsync = 0; vsync = 0; hbl = 0; vbl = 0; hbl_d = 0; vbl_d = 0;
end

assign vc = v - v_ofs;
assign hc = h - h_ofs;

// the clk_pix enable on which the counters wrap to line 0, pixel 0
assign frame_start = clk_pix && h == HTOTAL && v == VTOTAL;

// counters, syncs and display blanking run through resets; the game's blanking is held low during reset
always @ (posedge clk) begin
    if ( clk_pix == 1 ) begin
        // counter
        if (h == HTOTAL) begin
            h <= 0;
            v <= v + 9'd1;

            if ( v == VTOTAL ) begin
                v <= 0;
            end
        end else begin
            h <= h + 9'd1;
        end

        // h signals
        if ( h == HBL_START ) begin
            hbl_d <= 1;
        end else if ( h == HBL_END ) begin
            hbl_d <= 0;
        end

        // v signals
        if ( v == VBL_START ) begin
            vbl_d <= 1;
        end else if ( v == VBL_END ) begin
            vbl_d <= 0;
        end

        if ( reset ) begin
            hbl <= 0;
            vbl <= 0;
        end else begin
            if ( h == HBL_START ) begin
                hbl <= 1;
            end else if ( h == HBL_END ) begin
                hbl <= 0;
            end

            if ( v == VBL_START ) begin
                vbl <= 1;
            end else if ( v == VBL_END ) begin
                vbl <= 0;
            end
        end

        if ( v == VS_START ) begin
            vsync <= 1;
        end else if ( v == VS_END ) begin
            vsync <= 0;
        end

        if ( h == HS_START ) begin
            hsync <= 1;
        end else if ( h == HS_END ) begin
            hsync <= 0;
        end
    end

end

endmodule
