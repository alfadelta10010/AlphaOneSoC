/* Generated by Yosys 0.9 (git sha1 1979e0b) */

module PWM(clk, frequency, duty_cycle, pwm_out);
  wire [7:0] _000_;
  wire _001_;
  wire _002_;
  wire _003_;
  wire _004_;
  wire _005_;
  wire _006_;
  wire _007_;
  wire _008_;
  wire _009_;
  wire _010_;
  wire _011_;
  wire _012_;
  wire _013_;
  wire _014_;
  wire _015_;
  wire _016_;
  wire _017_;
  wire _018_;
  wire _019_;
  wire _020_;
  wire _021_;
  wire _022_;
  wire _023_;
  wire _024_;
  wire _025_;
  wire _026_;
  wire _027_;
  wire _028_;
  wire _029_;
  wire _030_;
  wire _031_;
  wire _032_;
  wire _033_;
  wire _034_;
  wire _035_;
  wire _036_;
  wire _037_;
  wire _038_;
  wire _039_;
  wire _040_;
  wire _041_;
  wire _042_;
  wire _043_;
  wire _044_;
  wire _045_;
  wire _046_;
  wire _047_;
  wire _048_;
  wire _049_;
  wire _050_;
  wire _051_;
  wire _052_;
  wire _053_;
  wire _054_;
  wire _055_;
  wire _056_;
  wire _057_;
  wire _058_;
  wire _059_;
  wire _060_;
  wire _061_;
  wire _062_;
  wire _063_;
  wire _064_;
  wire _065_;
  wire _066_;
  wire _067_;
  wire _068_;
  wire _069_;
  wire _070_;
  wire _071_;
  wire _072_;
  wire _073_;
  wire _074_;
  wire _075_;
  wire _076_;
  wire _077_;
  wire _078_;
  wire _079_;
  wire _080_;
  wire _081_;
  wire _082_;
  wire _083_;
  wire _084_;
  wire _085_;
  wire _086_;
  wire _087_;
  wire _088_;
  wire _089_;
  wire _090_;
  wire _091_;
  wire _092_;
  wire _093_;
  wire _094_;
  wire _095_;
  wire _096_;
  wire _097_;
  wire _098_;
  wire _099_;
  wire _100_;
  wire _101_;
  wire _102_;
  wire _103_;
  wire _104_;
  wire _105_;
  wire _106_;
  wire _107_;
  wire _108_;
  wire _109_;
  wire _110_;
  wire _111_;
  wire _112_;
  wire _113_;
  wire _114_;
  wire _115_;
  wire _116_;
  wire _117_;
  wire _118_;
  wire _119_;
  wire _120_;
  wire _121_;
  wire _122_;
  wire _123_;
  wire _124_;
  wire _125_;
  wire _126_;
  wire _127_;
  wire _128_;
  wire _129_;
  wire _130_;
  wire _131_;
  wire _132_;
  wire _133_;
  input clk;
  wire [7:0] counter;
  input [3:0] duty_cycle;
  input [3:0] frequency;
  output pwm_out;
  sky130_fd_sc_hd__clkinv_1 _134_ (
    .A(_097_),
    .Y(_098_)
  );
  sky130_fd_sc_hd__clkinv_1 _135_ (
    .A(_085_),
    .Y(_099_)
  );
  sky130_fd_sc_hd__clkinv_1 _136_ (
    .A(_084_),
    .Y(_100_)
  );
  sky130_fd_sc_hd__clkinv_1 _137_ (
    .A(_083_),
    .Y(_101_)
  );
  sky130_fd_sc_hd__nor2_1 _138_ (
    .A(_095_),
    .B(_094_),
    .Y(_102_)
  );
  sky130_fd_sc_hd__nor3_1 _139_ (
    .A(_096_),
    .B(_095_),
    .C(_094_),
    .Y(_103_)
  );
  sky130_fd_sc_hd__nand2_1 _140_ (
    .A(_098_),
    .B(_103_),
    .Y(_104_)
  );
  sky130_fd_sc_hd__nor4_1 _141_ (
    .A(_088_),
    .B(_089_),
    .C(_086_),
    .D(_087_),
    .Y(_105_)
  );
  sky130_fd_sc_hd__o21ai_0 _142_ (
    .A1(_098_),
    .A2(_103_),
    .B1(_085_),
    .Y(_106_)
  );
  sky130_fd_sc_hd__nand2b_1 _143_ (
    .A_N(_094_),
    .B(_082_),
    .Y(_107_)
  );
  sky130_fd_sc_hd__a31o_1 _144_ (
    .A1(_095_),
    .A2(_101_),
    .A3(_107_),
    .B1(_102_),
    .X(_108_)
  );
  sky130_fd_sc_hd__o21ai_0 _145_ (
    .A1(_095_),
    .A2(_094_),
    .B1(_096_),
    .Y(_109_)
  );
  sky130_fd_sc_hd__nand2b_1 _146_ (
    .A_N(_085_),
    .B(_097_),
    .Y(_110_)
  );
  sky130_fd_sc_hd__nand3_1 _147_ (
    .A(_084_),
    .B(_109_),
    .C(_110_),
    .Y(_111_)
  );
  sky130_fd_sc_hd__nand2_1 _148_ (
    .A(_083_),
    .B(_082_),
    .Y(_112_)
  );
  sky130_fd_sc_hd__and4_1 _149_ (
    .A(_106_),
    .B(_108_),
    .C(_111_),
    .D(_112_),
    .X(_113_)
  );
  sky130_fd_sc_hd__o21a_1 _150_ (
    .A1(_084_),
    .A2(_109_),
    .B1(_110_),
    .X(_114_)
  );
  sky130_fd_sc_hd__a221oi_1 _151_ (
    .A1(_098_),
    .A2(_085_),
    .B1(_084_),
    .B2(_103_),
    .C1(_114_),
    .Y(_115_)
  );
  sky130_fd_sc_hd__o21ai_0 _152_ (
    .A1(_113_),
    .A2(_115_),
    .B1(_105_),
    .Y(_116_)
  );
  sky130_fd_sc_hd__a21oi_1 _153_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_082_),
    .Y(_073_)
  );
  sky130_fd_sc_hd__xnor2_1 _154_ (
    .A(_083_),
    .B(_082_),
    .Y(_117_)
  );
  sky130_fd_sc_hd__a21oi_1 _155_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_117_),
    .Y(_074_)
  );
  sky130_fd_sc_hd__xnor2_1 _156_ (
    .A(_100_),
    .B(_112_),
    .Y(_118_)
  );
  sky130_fd_sc_hd__a21oi_1 _157_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_118_),
    .Y(_075_)
  );
  sky130_fd_sc_hd__o21ai_0 _158_ (
    .A1(_100_),
    .A2(_112_),
    .B1(_099_),
    .Y(_119_)
  );
  sky130_fd_sc_hd__nand4_1 _159_ (
    .A(_085_),
    .B(_084_),
    .C(_083_),
    .D(_082_),
    .Y(_120_)
  );
  sky130_fd_sc_hd__nand2_1 _160_ (
    .A(_119_),
    .B(_120_),
    .Y(_121_)
  );
  sky130_fd_sc_hd__a21oi_1 _161_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_121_),
    .Y(_076_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _162_ (
    .A(_086_),
    .SLEEP(_120_),
    .X(_122_)
  );
  sky130_fd_sc_hd__xor2_1 _163_ (
    .A(_086_),
    .B(_120_),
    .X(_123_)
  );
  sky130_fd_sc_hd__a21oi_1 _164_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_123_),
    .Y(_077_)
  );
  sky130_fd_sc_hd__xnor2_1 _165_ (
    .A(_087_),
    .B(_122_),
    .Y(_124_)
  );
  sky130_fd_sc_hd__a21oi_1 _166_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_124_),
    .Y(_078_)
  );
  sky130_fd_sc_hd__a21oi_1 _167_ (
    .A1(_087_),
    .A2(_122_),
    .B1(_088_),
    .Y(_125_)
  );
  sky130_fd_sc_hd__nand3_1 _168_ (
    .A(_088_),
    .B(_087_),
    .C(_122_),
    .Y(_126_)
  );
  sky130_fd_sc_hd__nand2b_1 _169_ (
    .A_N(_125_),
    .B(_126_),
    .Y(_127_)
  );
  sky130_fd_sc_hd__a21oi_1 _170_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_127_),
    .Y(_079_)
  );
  sky130_fd_sc_hd__xor2_1 _171_ (
    .A(_089_),
    .B(_126_),
    .X(_128_)
  );
  sky130_fd_sc_hd__a21oi_1 _172_ (
    .A1(_104_),
    .A2(_116_),
    .B1(_128_),
    .Y(_080_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _173_ (
    .A(_090_),
    .SLEEP(_082_),
    .X(_129_)
  );
  sky130_fd_sc_hd__maj3_1 _174_ (
    .A(_101_),
    .B(_091_),
    .C(_129_),
    .X(_130_)
  );
  sky130_fd_sc_hd__maj3_1 _175_ (
    .A(_100_),
    .B(_092_),
    .C(_130_),
    .X(_131_)
  );
  sky130_fd_sc_hd__a21oi_1 _176_ (
    .A1(_099_),
    .A2(_093_),
    .B1(_131_),
    .Y(_132_)
  );
  sky130_fd_sc_hd__o21ai_0 _177_ (
    .A1(_099_),
    .A2(_093_),
    .B1(_105_),
    .Y(_133_)
  );
  sky130_fd_sc_hd__nor2_1 _178_ (
    .A(_132_),
    .B(_133_),
    .Y(_081_)
  );
  sky130_fd_sc_hd__dfxtp_1 _179_ (
    .CLK(clk),
    .D(_000_[0]),
    .Q(counter[0])
  );
  sky130_fd_sc_hd__dfxtp_1 _180_ (
    .CLK(clk),
    .D(_000_[1]),
    .Q(counter[1])
  );
  sky130_fd_sc_hd__dfxtp_1 _181_ (
    .CLK(clk),
    .D(_000_[2]),
    .Q(counter[2])
  );
  sky130_fd_sc_hd__dfxtp_1 _182_ (
    .CLK(clk),
    .D(_000_[3]),
    .Q(counter[3])
  );
  sky130_fd_sc_hd__dfxtp_1 _183_ (
    .CLK(clk),
    .D(_000_[4]),
    .Q(counter[4])
  );
  sky130_fd_sc_hd__dfxtp_1 _184_ (
    .CLK(clk),
    .D(_000_[5]),
    .Q(counter[5])
  );
  sky130_fd_sc_hd__dfxtp_1 _185_ (
    .CLK(clk),
    .D(_000_[6]),
    .Q(counter[6])
  );
  sky130_fd_sc_hd__dfxtp_1 _186_ (
    .CLK(clk),
    .D(_000_[7]),
    .Q(counter[7])
  );
  sky130_fd_sc_hd__dfxtp_1 _187_ (
    .CLK(clk),
    .D(_001_),
    .Q(pwm_out)
  );
  assign _097_ = frequency[3];
  assign _096_ = frequency[2];
  assign _095_ = frequency[1];
  assign _094_ = frequency[0];
  assign _088_ = counter[6];
  assign _089_ = counter[7];
  assign _086_ = counter[4];
  assign _087_ = counter[5];
  assign _085_ = counter[3];
  assign _084_ = counter[2];
  assign _083_ = counter[1];
  assign _082_ = counter[0];
  assign _000_[0] = _073_;
  assign _000_[1] = _074_;
  assign _000_[2] = _075_;
  assign _000_[3] = _076_;
  assign _000_[4] = _077_;
  assign _000_[5] = _078_;
  assign _000_[6] = _079_;
  assign _000_[7] = _080_;
  assign _093_ = duty_cycle[3];
  assign _092_ = duty_cycle[2];
  assign _091_ = duty_cycle[1];
  assign _090_ = duty_cycle[0];
  assign _001_ = _081_;
endmodule