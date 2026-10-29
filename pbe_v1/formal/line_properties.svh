  // Assertions/observers only; prepared copy preserves the original transition logic.
  generate if (FORMAL_CHECKS) begin : formal_stuff_contract
    reg f_past_valid = 0;
    wire f_violation = rst_n && !clear && ts == T_IDLE && rs == R_RUN && sample &&
                       !se0 && rstuff && r_bit != r_exp;
    wire f_idle_end = !pair && a_in;
    reg f_saw_violation = 0;
    reg f_saw_idle_end = 0;
    always @(posedge clk) begin
      f_past_valid <= 1;
      if (f_past_valid && $past(f_violation)) begin
        if (FORMAL_ORIGINAL_STUFF)
          assert(err); // Original unconditional request: deliberately false for idle end.
        else if ($past(f_idle_end))
          assert(frame_end);
        else
          assert(err);
      end
      if (f_violation) f_saw_violation <= 1;
      if (f_violation && f_idle_end) f_saw_idle_end <= 1;
      // A wrong NRZ ones-style stuff bit is necessarily high; on a single
      // wire that is a normal EOF, so err-only would be an impossible goal.
      // Pair mode has no idle exception. The original unconditional-error
      // tasks separately retain counterexamples for every single-wire mode.
      cover(f_saw_violation && (err || (!pair && frame_end)));
    end
  end endgenerate
