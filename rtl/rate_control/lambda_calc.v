//=============================================================================
// lambda_calc.v
// Standard HEVC Lagrangian Multiplier Lookup Engine (Q16.8 Fixed-Point)
//
// Computes:
//   lambda_mode   = 0.85 * 2^((QP - 12) / 3.0)       in Q16.8 (24 bits)
//   lambda_motion = sqrt(lambda_mode)                 in Q8.8  (16 bits)
//   lambda_chroma = 0.85 * 2^((QP_chroma - 12) / 3.0) in Q16.8 (24 bits)
//=============================================================================

`timescale 1ns / 1ps

module lambda_calc (
    input  wire [5:0]         qp,
    output reg  [27:0]        lambda_mode,
    output reg  [17:0]        lambda_motion,
    output reg  [27:0]        lambda_chroma
);

    always @(*) begin
        case (qp)
            6'd 0: begin lambda_mode = 28'd584; lambda_motion = 18'd387; lambda_chroma = 28'd584; end
            6'd 1: begin lambda_mode = 28'd735; lambda_motion = 18'd434; lambda_chroma = 28'd735; end
            6'd 2: begin lambda_mode = 28'd927; lambda_motion = 18'd487; lambda_chroma = 28'd927; end
            6'd 3: begin lambda_mode = 28'd1167; lambda_motion = 18'd547; lambda_chroma = 28'd1167; end
            6'd 4: begin lambda_mode = 28'd1471; lambda_motion = 18'd614; lambda_chroma = 28'd1471; end
            6'd 5: begin lambda_mode = 28'd1853; lambda_motion = 18'd690; lambda_chroma = 28'd1853; end
            6'd 6: begin lambda_mode = 28'd2335; lambda_motion = 18'd774; lambda_chroma = 28'd2335; end
            6'd 7: begin lambda_mode = 28'd2942; lambda_motion = 18'd869; lambda_chroma = 28'd2942; end
            6'd 8: begin lambda_mode = 28'd3706; lambda_motion = 18'd975; lambda_chroma = 28'd3706; end
            6'd 9: begin lambda_mode = 28'd4669; lambda_motion = 18'd1095; lambda_chroma = 28'd4669; end
            6'd10: begin lambda_mode = 28'd5883; lambda_motion = 18'd1229; lambda_chroma = 28'd5883; end
            6'd11: begin lambda_mode = 28'd7412; lambda_motion = 18'd1379; lambda_chroma = 28'd7412; end
            6'd12: begin lambda_mode = 28'd9339; lambda_motion = 18'd1548; lambda_chroma = 28'd9339; end
            6'd13: begin lambda_mode = 28'd11766; lambda_motion = 18'd1737; lambda_chroma = 28'd11766; end
            6'd14: begin lambda_mode = 28'd14825; lambda_motion = 18'd1950; lambda_chroma = 28'd14825; end
            6'd15: begin lambda_mode = 28'd18678; lambda_motion = 18'd2189; lambda_chroma = 28'd18678; end
            6'd16: begin lambda_mode = 28'd23533; lambda_motion = 18'd2457; lambda_chroma = 28'd23533; end
            6'd17: begin lambda_mode = 28'd29649; lambda_motion = 18'd2758; lambda_chroma = 28'd29649; end
            6'd18: begin lambda_mode = 28'd37356; lambda_motion = 18'd3096; lambda_chroma = 28'd37356; end
            6'd19: begin lambda_mode = 28'd47065; lambda_motion = 18'd3475; lambda_chroma = 28'd47065; end
            6'd20: begin lambda_mode = 28'd59298; lambda_motion = 18'd3900; lambda_chroma = 28'd59298; end
            6'd21: begin lambda_mode = 28'd74711; lambda_motion = 18'd4378; lambda_chroma = 28'd74711; end
            6'd22: begin lambda_mode = 28'd94130; lambda_motion = 18'd4914; lambda_chroma = 28'd94130; end
            6'd23: begin lambda_mode = 28'd118596; lambda_motion = 18'd5515; lambda_chroma = 28'd118596; end
            6'd24: begin lambda_mode = 28'd149422; lambda_motion = 18'd6190; lambda_chroma = 28'd149422; end
            6'd25: begin lambda_mode = 28'd188260; lambda_motion = 18'd6948; lambda_chroma = 28'd188260; end
            6'd26: begin lambda_mode = 28'd237193; lambda_motion = 18'd7798; lambda_chroma = 28'd237193; end
            6'd27: begin lambda_mode = 28'd298844; lambda_motion = 18'd8753; lambda_chroma = 28'd298844; end
            6'd28: begin lambda_mode = 28'd376520; lambda_motion = 18'd9825; lambda_chroma = 28'd376520; end
            6'd29: begin lambda_mode = 28'd474386; lambda_motion = 18'd11029; lambda_chroma = 28'd474386; end
            6'd30: begin lambda_mode = 28'd597688; lambda_motion = 18'd12380; lambda_chroma = 28'd474386; end
            6'd31: begin lambda_mode = 28'd753040; lambda_motion = 18'd13896; lambda_chroma = 28'd597688; end
            6'd32: begin lambda_mode = 28'd948771; lambda_motion = 18'd15598; lambda_chroma = 28'd753040; end
            6'd33: begin lambda_mode = 28'd1195377; lambda_motion = 18'd17508; lambda_chroma = 28'd948771; end
            6'd34: begin lambda_mode = 28'd1506080; lambda_motion = 18'd19652; lambda_chroma = 28'd1195377; end
            6'd35: begin lambda_mode = 28'd1897542; lambda_motion = 18'd22059; lambda_chroma = 28'd1195377; end
            6'd36: begin lambda_mode = 28'd2390753; lambda_motion = 18'd24761; lambda_chroma = 28'd1506080; end
            6'd37: begin lambda_mode = 28'd3012160; lambda_motion = 18'd27793; lambda_chroma = 28'd1506080; end
            6'd38: begin lambda_mode = 28'd3795084; lambda_motion = 18'd31197; lambda_chroma = 28'd1897542; end
            6'd39: begin lambda_mode = 28'd4781507; lambda_motion = 18'd35017; lambda_chroma = 28'd1897542; end
            6'd40: begin lambda_mode = 28'd6024321; lambda_motion = 18'd39306; lambda_chroma = 28'd2390753; end
            6'd41: begin lambda_mode = 28'd7590169; lambda_motion = 18'd44120; lambda_chroma = 28'd2390753; end
            6'd42: begin lambda_mode = 28'd9563013; lambda_motion = 18'd49523; lambda_chroma = 28'd3012160; end
            6'd43: begin lambda_mode = 28'd12048642; lambda_motion = 18'd55588; lambda_chroma = 28'd3012160; end
            6'd44: begin lambda_mode = 28'd15180337; lambda_motion = 18'd62391; lambda_chroma = 28'd3795084; end
            6'd45: begin lambda_mode = 28'd19126026; lambda_motion = 18'd70032; lambda_chroma = 28'd3795084; end
            6'd46: begin lambda_mode = 28'd24097283; lambda_motion = 18'd78609; lambda_chroma = 28'd4781507; end
            6'd47: begin lambda_mode = 28'd30360674; lambda_motion = 18'd88237; lambda_chroma = 28'd4781507; end
            6'd48: begin lambda_mode = 28'd38252052; lambda_motion = 18'd99043; lambda_chroma = 28'd6024321; end
            6'd49: begin lambda_mode = 28'd48194566; lambda_motion = 18'd111172; lambda_chroma = 28'd6024321; end
            6'd50: begin lambda_mode = 28'd60721348; lambda_motion = 18'd124787; lambda_chroma = 28'd7590169; end
            6'd51: begin lambda_mode = 28'd76504105; lambda_motion = 18'd139947; lambda_chroma = 28'd19126026; end
            default: begin lambda_mode = 28'd948771; lambda_motion = 18'd15598; lambda_chroma = 28'd753040; end
        endcase
    end

endmodule
