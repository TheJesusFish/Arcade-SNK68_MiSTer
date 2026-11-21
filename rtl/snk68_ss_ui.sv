// SNK68 save-state UI: savestate_ui (TaitoF2, unmodified) with the F1 / Alt key mapping and Autoincrement after a finished save
module snk68_ss_ui (
    input             clk,
    input      [10:0] ps2_key,
    input             joy_ss,
    input       [3:0] joy_ssd,
    input       [1:0] status_slot,
    input             autoinc,
    input       [1:0] osd_saveload,
    input             saved,
    input       [1:0] saved_slot,
    output            ss_save,
    output            ss_load,
    output            info_req,
    output      [7:0] info,
    output            status_set,
    output      [1:0] slot
);

function [7:0] slot_key(input [1:0] s);
    slot_key = ( s == 2'd0 ) ? 8'h05 : ( s == 2'd1 ) ? 8'h06 : ( s == 2'd2 ) ? 8'h04 : 8'h0c;
endfunction

// F1 reaches the UI as the F key of the selected slot, so F1 / Alt-F1 use that slot
reg         key_tgl;
wire [10:0] key = ( ps2_key[7:0] == 8'h05 ) ? { ps2_key[10:8], slot_key(slot) } :
                  ( ps2_key[7:0] == 8'h11 ) ? ps2_key : { key_tgl, ps2_key[9:0] };
always @(posedge clk) if ( ps2_key[7:0] == 8'h05 || ps2_key[7:0] == 8'h11 ) key_tgl <= ps2_key[10];

// Autoincrement: a finished save selects the next slot as a released F key, in a cycle without a real key event
reg         inc_pend = 0, inc_par = 0, key10_l = 0;
reg   [1:0] inc_slot = 0;
wire        inc_now = inc_pend & ( key[10] == key10_l );
wire [10:0] ui_key  = inc_now ? { ~( key[10] ^ inc_par ), 2'b00, slot_key(inc_slot) } : { key[10] ^ inc_par, key[9:0] };
always @(posedge clk) begin
    key10_l <= key[10];
    if ( inc_now ) begin inc_pend <= 0; inc_par <= ~inc_par; end
    if ( saved & autoinc ) begin inc_pend <= 1; inc_slot <= saved_slot + 2'd1; end
end

savestate_ui #(.INFO_TIMEOUT_BITS(25)) savestate_ui (
    .clk            ( clk ),
    .ps2_key        ( ui_key ),
    .allow_ss       ( 1'b1 ),
    .joySS          ( joy_ss ),
    .joyRight       ( joy_ssd[0] ),
    .joyLeft        ( joy_ssd[1] ),
    .joyDown        ( joy_ssd[2] ),
    .joyUp          ( joy_ssd[3] ),
    .joyStart       ( 1'b0 ),
    .joyRewind      ( 1'b0 ),
    .rewindEnable   ( 1'b0 ),
    .status_slot    ( status_slot ),
    .autoincslot    ( 1'b0 ),
    .OSD_saveload   ( osd_saveload ),
    .ss_save        ( ss_save ),
    .ss_load        ( ss_load ),
    .ss_info_req    ( info_req ),
    .ss_info        ( info ),
    .statusUpdate   ( status_set ),
    .selected_slot  ( slot )
);

endmodule
