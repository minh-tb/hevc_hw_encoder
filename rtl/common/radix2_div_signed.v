//=============================================================================
// radix2_div_signed.v
// Sequential radix-2 non-restoring divider for signed integers.
// Computes: quotient = round(num / den)
//=============================================================================

module radix2_div_signed #(
    parameter W = 24
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire signed  [W-1:0] num,
    input  wire signed  [W-1:0] den,

    output reg          done,
    output reg  signed  [W-1:0] quo
);

    localparam S_IDLE = 2'd0;
    localparam S_DIV  = 2'd1;
    localparam S_RND  = 2'd2;
    localparam S_DONE = 2'd3;

    reg [1:0] state;
    reg [5:0] count;

    reg [W-1:0] abs_num;
    reg [W-1:0] abs_den;
    reg sign_res;

    reg [2*W-1:0] P;
    reg [W-1:0]   Q;

    wire [W:0] sub_res = P[2*W-2 : W-1] - {1'b0, abs_den};
    wire       sub_neg = sub_res[W];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
            quo   <= 0;
            count <= 0;
            P     <= 0;
            Q     <= 0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        if (den == 0 || num == 0) begin
                            quo <= 0;
                            done <= 1'b1;
                        end else begin
                            abs_num  <= num[W-1] ? -num : num;
                            abs_den  <= den[W-1] ? -den : den;
                            sign_res <= num[W-1] ^ den[W-1];
                            P        <= 0;
                            Q        <= num[W-1] ? -num : num;
                            count    <= W;
                            state    <= S_DIV;
                        end
                    end
                end
                S_DIV: begin
                    if (count > 0) begin
                        if (!sub_neg) begin
                            P <= {sub_res[W-1:0], Q[W-1]};
                            Q <= {Q[W-2:0], 1'b1};
                        end else begin
                            P <= {P[2*W-3:W-1], Q[W-1]};
                            Q <= {Q[W-2:0], 1'b0};
                        end
                        count <= count - 1;
                    end else begin
                        state <= S_RND;
                    end
                end
                S_RND: begin
                    // Remainder is in P[2*W-2 : W-1]
                    // If remainder * 2 >= abs_den, round up quotient
                    if ({P[2*W-3 : W-1], 1'b0} >= abs_den) begin
                        Q <= Q + 1;
                    end
                    state <= S_DONE;
                end
                S_DONE: begin
                    quo <= sign_res ? -Q : Q;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
