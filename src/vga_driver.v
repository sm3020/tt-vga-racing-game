/*
 * Racing game for VGA: dodge the traffic.
 *
 * To play, open Inspect > VGA output and press Run. Use the switches under the
 * picture, or the keyboard:
 *   ui_in[0]  steer left     (Left arrow, A or 1)
 *   ui_in[1]  steer right    (Right arrow, D or 2)
 *   ui_in[2]  boost          (Up arrow, W, Space or 3)
 *
 * The score bar at the top grows while you survive, and the traffic speeds up
 * as it grows. A crash flashes the screen red and starts the run again.
 *
 * Yellow stars drift down with the traffic. Drive into one and it becomes a
 * spare life, spent automatically the next time you hit a vehicle; the spare
 * lives show as a yellow block at the top right.
 *
 * How this file is laid out:
 *   1. SETTINGS   Colours, sizes and speeds. Change anything here and press Run.
 *   2. WIRING     The pins and the sync generator. Leave this as it is.
 *   3. THE GAME   The rules: steering, traffic, crashes and the score.
 *   4. DRAWING    The colour of every pixel, from where things are.
 */

`default_nettype none

module tt_um_sm3020_vga_racing_game (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ========================================================================
    // 1. SETTINGS
    //    Change these freely. Nothing below needs editing when you do.
    // ========================================================================

    // Colours. Six bits: two for red, two for green, two for blue (6'bRRGGBB).
    // Each pair goes from 00 (off) to 11 (full), so 6'b110000 is pure red.
    localparam [5:0] CAR_COLOUR     = 6'b111011;   // red
    localparam [5:0] WINDOW_COLOUR  = 6'b011110;   // glass
    localparam [5:0] WHEEL_COLOUR   = 6'b010101;   // dark grey
    localparam [5:0] TRAFFIC_COLOUR = 6'b110110;   // amber
    localparam [5:0] TRAFFIC_SHADE  = 6'b100000;   // the darker strip along its top
    localparam [5:0] ROAD_COLOUR    = 6'b010101;   // tarmac
    localparam [5:0] LINE_COLOUR    = 6'b111110;   // the dashed centre line
    localparam [5:0] KERB_COLOUR_A  = 6'b110000;   // the kerb is striped red ...
    localparam [5:0] KERB_COLOUR_B  = 6'b111111;   // ... and white
    localparam [5:0] GRASS_COLOUR_A = 6'b111011;   // the two greens of the grass
    localparam [5:0] GRASS_COLOUR_B = 6'b110101;
    localparam [5:0] SCORE_COLOUR   = 6'b001100;   // green
    localparam [5:0] STAR_COLOUR    = 6'b111100;   // yellow reward star

    // Sizes, in pixels. The screen is 640 wide and 480 tall.
    localparam [9:0] CAR_W     = 10'd24;
    localparam [9:0] CAR_H     = 10'd40;
    // Vehicle widths are picked at random between TRAFFIC_MIN_W and
    // TRAFFIC_MIN_W + 31. Keep the top of that range to 48 or less, or a wide
    // vehicle will overhang the kerb.
    localparam [9:0] TRAFFIC_MIN_W = 10'd16;
    localparam [9:0] TRAFFIC_H = 10'd32;
    localparam [9:0] STAR_SIZE = 10'd16;   // the reward star is 16 by 16
    localparam       GRASS_BIT = 4;        // size of the grass squares: 3 is 8 pixels, 4 is 16, 5 is 32

    // Speeds, in pixels per frame. There are 60 frames every second.
    localparam [9:0] STEER_STEP  = 10'd4;  // how far the car moves sideways
    localparam [4:0] BASE_SPEED  = 5'd3;   // how fast the traffic comes at the start
    localparam [4:0] BOOST_SPEED = 5'd3;   // added while boost is held
                                           // keep BASE_SPEED + BOOST_SPEED to 16 or less

    // How long the red flash lasts after a crash, in frames. 63 at most.
    localparam [5:0] CRASH_FRAMES = 6'd40;

    // The road. These numbers fit together, so change them as a set.
    localparam [9:0] ROAD_L    = 10'd160;  // outer edge of the left kerb
    localparam [9:0] ROAD_R    = 10'd480;  // outer edge of the right kerb
    localparam [9:0] LANE_L    = 10'd168;  // the part you can drive on
    localparam [9:0] LANE_R    = 10'd472;
    localparam [9:0] CAR_Y     = 10'd400;  // how far down the screen the car sits
    localparam [9:0] CAR_START = 10'd304;  // where the car starts each run

    // ========================================================================
    // 2. WIRING
    //    The pins and the monitor's timing. Leave this section as it is.
    // ========================================================================

    wire       hsync;
    wire       vsync;
    wire       video_active;
    wire [9:0] pix_x;          // the pixel being drawn now: 0 to 639 across
    wire [9:0] pix_y;          // and 0 to 479 down

    hvsync_generator hvsync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );

    wire steer_left  = ui_in[0] & ~ui_in[1];
    wire steer_right = ui_in[1] & ~ui_in[0];
    wire boost       = ui_in[2];

    // High for one clock as each frame ends. The game moves on once per frame.
    reg  vsync_q;
    wire new_frame = vsync & ~vsync_q;

    // ========================================================================
    // 3. THE GAME
    //    A few registers hold where everything is. They change once per frame.
    // ========================================================================

    reg [9:0] car_x;               // left edge of the car
    reg [9:0] traffic0_x;          // top left corner of each of the two vehicles
    reg [9:0] traffic0_y;
    reg [9:0] traffic0_w;          // each vehicle's own width, re-rolled when it respawns
    reg [9:0] traffic1_x;
    reg [9:0] traffic1_y;
    reg [9:0] traffic1_w;
    reg [9:0] score;               // frames survived this run, up to 1023
    reg [9:0] scroll;              // how far the road has moved, for the stripes
    reg [5:0] crash_timer;         // frames of flash left after a crash, 0 when driving
    reg [15:0] random;             // shifts every clock, so its value looks random
    reg [9:0] star_x;              // top left corner of the reward star
    reg [9:0] star_y;
    reg [2:0] lives;               // spare lives earned from stars, 0 to 7

    // The level goes up by one every 64 frames, and each level is one pixel faster.
    wire [3:0] level = score[9:6];
    wire [4:0] speed = BASE_SPEED + {1'b0, level} + (boost ? BOOST_SPEED : 5'd0);

    // The furthest left and right the car can go and still be on the road.
    localparam [9:0] CAR_MIN = LANE_L;
    localparam [9:0] CAR_MAX = LANE_R - CAR_W;

    // Where a vehicle joins the road: somewhere across the lane, 256 places.
    wire [9:0] random_x0 = LANE_L + {2'b00, random[7:0]};
    wire [9:0] random_x1 = LANE_L + {2'b00, random[15:8]};

    // How wide it is when it joins: TRAFFIC_MIN_W up to 31 pixels wider, so a
    // fresh width comes with every respawn.
    wire [9:0] random_w0 = TRAFFIC_MIN_W + {5'b0, random[4:0]};
    wire [9:0] random_w1 = TRAFFIC_MIN_W + {5'b0, random[12:8]};

    // Where a fresh star appears when it is collected or leaves the screen.
    wire [9:0] random_star_x = LANE_L + {2'b00, random[7:0]};

    // A crash is the car's rectangle overlapping a vehicle's rectangle.
    wire hit0 = (car_x < traffic0_x + traffic0_w) & (traffic0_x < car_x + CAR_W) &
                (CAR_Y < traffic0_y + TRAFFIC_H) & (traffic0_y < CAR_Y + CAR_H);
    wire hit1 = (car_x < traffic1_x + traffic1_w) & (traffic1_x < car_x + CAR_W) &
                (CAR_Y < traffic1_y + TRAFFIC_H) & (traffic1_y < CAR_Y + CAR_H);
    wire crash = hit0 | hit1;

    // Collecting the star: the car's box overlaps the star's box.
    wire got_star = (car_x < star_x + STAR_SIZE) & (star_x < car_x + CAR_W) &
                    (CAR_Y < star_y + STAR_SIZE) & (star_y < CAR_Y + CAR_H);

    // How far each vehicle moves this frame. The second is one pixel faster,
    // so the two do not stay in step.
    wire [9:0] step0 = {5'd0, speed};
    wire [9:0] step1 = {5'd0, speed} + 10'd1;

    always @(posedge clk) begin
        random  <= {random[14:0], random[15] ^ random[13] ^ random[12] ^ random[10]};
        vsync_q <= vsync;

        if (~rst_n) begin
            car_x       <= CAR_START;
            traffic0_x  <= 10'd240;
            traffic0_y  <= 10'd0;
            traffic0_w  <= TRAFFIC_MIN_W;
            traffic1_x  <= 10'd360;
            traffic1_y  <= 10'd240;
            traffic1_w  <= TRAFFIC_MIN_W;
            score       <= 10'd0;
            scroll      <= 10'd0;
            crash_timer <= 6'd0;
            lives       <= 3'd0;
            star_x      <= 10'd312;
            star_y      <= 10'd120;
            random      <= 16'hACE1;
        end else if (new_frame) begin
            if (crash_timer != 6'd0) begin
                // ---- after a crash: count the flash down, then start again
                crash_timer <= crash_timer - 6'd1;
                if (crash_timer == 6'd1) begin
                    car_x      <= CAR_START;
                    traffic0_x <= random_x0;
                    traffic0_y <= 10'd0;
                    traffic0_w <= random_w0;
                    traffic1_x <= random_x1;
                    traffic1_y <= 10'd240;
                    traffic1_w <= random_w1;
                    score      <= 10'd0;
                    lives      <= 3'd0;
                    star_x     <= random_star_x;
                    star_y     <= 10'd0;
                end
            end else if (crash & (lives == 3'd0)) begin
                // ---- a crash with no lives in hand: flash, then start again
                crash_timer <= CRASH_FRAMES;
            end else if (crash) begin
                // ---- a hit while a star is held: spend a life and clear the
                //      road ahead by sending the offending vehicle back up top
                lives <= lives - 3'd1;
                if (hit0) begin
                    traffic0_x <= random_x0;
                    traffic0_y <= 10'd0;
                    traffic0_w <= random_w0;
                end
                if (hit1) begin
                    traffic1_x <= random_x1;
                    traffic1_y <= 10'd0;
                    traffic1_w <= random_w1;
                end
            end else begin
                // ---- steering: move sideways, and stop at the edge of the road
                if (steer_left)  car_x <= (car_x > CAR_MIN + STEER_STEP) ? car_x - STEER_STEP : CAR_MIN;
                if (steer_right) car_x <= (car_x < CAR_MAX - STEER_STEP) ? car_x + STEER_STEP : CAR_MAX;

                // ---- traffic: move down, and rejoin at the top in a new place
                if (traffic0_y + step0 > 10'd480) begin
                    traffic0_y <= 10'd0;
                    traffic0_x <= random_x0;
                    traffic0_w <= random_w0;
                end else begin
                    traffic0_y <= traffic0_y + step0;
                end
                if (traffic1_y + step1 > 10'd480) begin
                    traffic1_y <= 10'd0;
                    traffic1_x <= random_x1;
                    traffic1_w <= random_w1;
                end else begin
                    traffic1_y <= traffic1_y + step1;
                end

                // ---- the star drifts down with the road. Reach it and it
                //      becomes a spare life; run it off the bottom and it
                //      returns to the top in a new place.
                if (got_star) begin
                    if (lives != 3'd7) lives <= lives + 3'd1;
                    star_x <= random_star_x;
                    star_y <= 10'd0;
                end else if (star_y + step0 > 10'd480) begin
                    star_x <= random_star_x;
                    star_y <= 10'd0;
                end else begin
                    star_y <= star_y + step0;
                end

                // ---- the road moves with the traffic, and the score counts up
                scroll <= scroll + step0;
                if (score != 10'h3ff) score <= score + 10'd1;
            end
        end
    end

    // ========================================================================
    // 4. DRAWING
    //    One question for each thing on screen: is this pixel inside it?
    // ========================================================================

    // The road, its striped kerbs and its dashed centre line. Adding scroll to
    // pix_y is what makes the stripes move down the screen.
    wire [9:0] moving_y = pix_y + scroll;
    wire in_road        = (pix_x >= ROAD_L) & (pix_x < ROAD_R);
    wire in_kerb        = in_road & ((pix_x < LANE_L) | (pix_x >= LANE_R));
    wire kerb_stripe    = moving_y[4];
    wire in_centre_line = (pix_x >= 10'd318) & (pix_x < 10'd322) & moving_y[5];
    wire grass_square   = pix_x[GRASS_BIT] ^ pix_y[GRASS_BIT];

    // The car, with a window and four wheels.
    wire in_car    = (pix_x >= car_x) & (pix_x < car_x + CAR_W) &
                     (pix_y >= CAR_Y) & (pix_y < CAR_Y + CAR_H);
    wire in_window = in_car &
                     (pix_x >= car_x + 10'd4) & (pix_x < car_x + CAR_W - 10'd4) &
                     (pix_y >= CAR_Y + 10'd8) & (pix_y < CAR_Y + 10'd18);
    wire in_wheel  = in_car &
                     ((pix_x < car_x + 10'd3) | (pix_x >= car_x + CAR_W - 10'd3)) &
                     ((pix_y < CAR_Y + 10'd10) | (pix_y >= CAR_Y + CAR_H - 10'd10));

    // The two vehicles, each with a darker strip six pixels deep along the top.
    wire in_traffic0 = (pix_x >= traffic0_x) & (pix_x < traffic0_x + traffic0_w) &
                       (pix_y >= traffic0_y) & (pix_y < traffic0_y + TRAFFIC_H);
    wire in_traffic1 = (pix_x >= traffic1_x) & (pix_x < traffic1_x + traffic1_w) &
                       (pix_y >= traffic1_y) & (pix_y < traffic1_y + TRAFFIC_H);
    wire in_traffic  = in_traffic0 | in_traffic1;
    wire in_shade    = (in_traffic0 & (pix_y - traffic0_y < 10'd6)) |
                       (in_traffic1 & (pix_y - traffic1_y < 10'd6));

    // The reward star: a 16 by 16 sprite, drawn one row at a time. star_row
    // holds the 16 pixels of the current row, and in_star picks the column.
    wire [9:0] star_dy = pix_y - star_y;
    reg  [15:0] star_row;
    always @(*) begin
        case (star_dy)
            10'd0:  star_row = 16'b0000000110000000;
            10'd1:  star_row = 16'b0000001111000000;
            10'd2:  star_row = 16'b0000011111100000;
            10'd3:  star_row = 16'b0000011111100000;
            10'd4:  star_row = 16'b0111111111111110;
            10'd5:  star_row = 16'b0011111111111100;
            10'd6:  star_row = 16'b0001111111111000;
            10'd7:  star_row = 16'b0000111111110000;
            10'd8:  star_row = 16'b0000111111110000;
            10'd9:  star_row = 16'b0000011111100000;
            10'd10: star_row = 16'b0000011111100000;
            10'd11: star_row = 16'b0000111001110000;
            10'd12: star_row = 16'b0001110000111000;
            10'd13: star_row = 16'b0011100000011100;
            10'd14: star_row = 16'b0110000000000110;
            10'd15: star_row = 16'b0100000000000010;
            default: star_row = 16'b0000000000000000;
        endcase
    end
    // star_col only matters inside the box, where the offset is 0..15, so the
    // low four bits of the subtraction give the column exactly.
    wire [3:0] star_col = pix_x[3:0] - star_x[3:0];
    wire in_star = (pix_x >= star_x) & (pix_x < star_x + STAR_SIZE) &
                   (pix_y >= star_y) & (pix_y < star_y + STAR_SIZE) &
                   star_row[4'd15 - star_col];

    // The score bar: one pixel longer for every two frames survived.
    wire in_score = (pix_y >= 10'd8) & (pix_y < 10'd18) &
                    (pix_x >= 10'd8) & (pix_x < 10'd8 + {1'b0, score[9:1]});

    // The spare lives: a yellow block at the top right, ten pixels per life.
    wire [9:0] lives_len = {7'b0, lives} * 10'd10;
    wire in_lives = (pix_y >= 10'd8) & (pix_y < 10'd18) &
                    (pix_x >= 10'd632 - lives_len) & (pix_x < 10'd632);

    // The first line that matches wins, so anything higher up is drawn on top
    // of anything lower down. Move a line to change what covers what.
    reg [5:0] colour;
    always @(*) begin
        if (~video_active)       colour = 6'b000000;
        else if (in_score)       colour = SCORE_COLOUR;
        else if (in_lives)       colour = STAR_COLOUR;
        else if (in_wheel)       colour = WHEEL_COLOUR;
        else if (in_window)      colour = WINDOW_COLOUR;
        else if (in_car)         colour = CAR_COLOUR;
        else if (in_traffic)     colour = in_shade ? TRAFFIC_SHADE : TRAFFIC_COLOUR;
        else if (in_star)        colour = STAR_COLOUR;
        else if (in_kerb)        colour = kerb_stripe ? KERB_COLOUR_A : KERB_COLOUR_B;
        else if (in_centre_line) colour = LINE_COLOUR;
        else if (in_road)        colour = ROAD_COLOUR;
        else                     colour = grass_square ? GRASS_COLOUR_A : GRASS_COLOUR_B;
    end

    // The crash flash: for four frames in every eight, full red with green and blue halved.
    wire       flash  = (crash_timer != 6'd0) & crash_timer[2];
    wire [5:0] shown  = flash ? {2'b11, colour[3:2] >> 1, colour[1:0] >> 1} : colour;

    // ---- to the pins, in the order the TinyVGA adapter expects. Leave as it is.
    wire [1:0] R = shown[5:4];
    wire [1:0] G = shown[3:2];
    wire [1:0] B = shown[1:0];

    assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused_ok = &{ena, uio_in, ui_in[7:3]};

endmodule
