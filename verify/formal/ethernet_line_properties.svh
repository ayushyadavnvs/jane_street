// Observation-only D94 properties. No extra assumptions about RTL state.
  reg e_past=0;
  always @(posedge clk) begin
    e_past<=1;
    if(e_past && rst_n) begin
      if($past(!rst_n || clear)) assert(!ns_mode && !q_ns && !tns);
      else begin
        if($past(ctl && ctl_param[4] && ctl_param[1])) assert(!ns_mode);
        else if($past(ctl && ctl_param[4] && ctl_param[0])) assert(ns_mode);
        if($past(tx_put && !tx_end)) assert(q_ns==$past(ns_mode));
        if($past(ts==T_RUN && (boundary || kick) && n_load)) assert(tns==$past(q_ns));
        if($past(!manch && ts==T_RUN && (boundary || kick) && tstuff && ones)) begin
          if($past(nrzi)) assert(a_out != $past(level));
          else assert(!a_out);
        end
        if($past(flagd && !pair && ts==T_IDLE && rs==R_RUN && sample && rstuff && r_bit!=r_exp)) begin
          assert(frame_end);assert(rs==R_RUN);assert(rrun==0);
        end
        if($past(frame_end)) assert(!rx_valid);
      end
    end
  end

`ifdef ETH_TAGS
  always @(posedge clk) if(e_past && rst_n && !clear) begin
    cover(tx_put && !tx_end && ns_mode);
    cover(ts==T_RUN && q_valid && q_ns && !tns);
    cover(ts==T_RUN && tstuff && q_valid && q_ns);
  end
`endif
`ifdef ETH_FLAGS
  always @(posedge clk) if(e_past && rst_n && !clear)
    cover($past(flagd && !pair && ts==T_IDLE && rs==R_RUN && sample &&
                rstuff && r_bit!=r_exp && !a_in) && frame_end);
`endif

`ifdef ETH_TIMER
  always @(posedge clk) if(e_past && rst_n) begin
    // D101: 7/8 of each error stays, so mcnt > -56 x CLKDIV; up to ~96 x CLKDIV with a pending edge
    assert($signed(mcnt)>=-24'sd3800000 && $signed(mcnt)<=24'sd6400000);
    // p_tau is mcnt (or 4 or 12 less); m_b' averages mcnt values: the same range (induction)
    assert($signed(p_tau)>=-24'sd3800016 && $signed(p_tau)<=24'sd6400000);
    assert($signed(m_b)>=-24'sd3800000 && $signed(m_b)<=24'sd6400000);
    assert(!m_8p[23] && !m_16p[23] && !m_end[23] && !m_5n[23]);
  end
`endif
