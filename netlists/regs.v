/* Generated by Yosys 0.9 (git sha1 1979e0b) */

module regs(clk, rst, in, out, en);
  wire [31:0] _000_;
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
  wire _134_;
  wire _135_;
  wire _136_;
  wire _137_;
  wire _138_;
  wire _139_;
  wire _140_;
  wire _141_;
  wire _142_;
  wire _143_;
  wire _144_;
  wire _145_;
  wire _146_;
  wire _147_;
  wire _148_;
  wire _149_;
  wire _150_;
  wire _151_;
  wire _152_;
  wire _153_;
  wire _154_;
  wire _155_;
  wire _156_;
  wire _157_;
  wire _158_;
  wire _159_;
  wire _160_;
  wire _161_;
  wire _162_;
  input clk;
  input en;
  input [31:0] in;
  output [31:0] out;
  input rst;
  sky130_fd_sc_hd__clkinv_1 _163_ (
    .A(_130_),
    .Y(_064_)
  );
  sky130_fd_sc_hd__mux2_1 _164_ (
    .A0(_109_),
    .A1(_077_),
    .S(_065_),
    .X(_012_)
  );
  sky130_fd_sc_hd__mux2_1 _165_ (
    .A0(_120_),
    .A1(_088_),
    .S(_065_),
    .X(_023_)
  );
  sky130_fd_sc_hd__mux2_1 _166_ (
    .A0(_123_),
    .A1(_091_),
    .S(_065_),
    .X(_026_)
  );
  sky130_fd_sc_hd__mux2_1 _167_ (
    .A0(_124_),
    .A1(_092_),
    .S(_065_),
    .X(_027_)
  );
  sky130_fd_sc_hd__mux2_1 _168_ (
    .A0(_125_),
    .A1(_093_),
    .S(_065_),
    .X(_028_)
  );
  sky130_fd_sc_hd__mux2_1 _169_ (
    .A0(_126_),
    .A1(_094_),
    .S(_065_),
    .X(_029_)
  );
  sky130_fd_sc_hd__mux2_1 _170_ (
    .A0(_127_),
    .A1(_095_),
    .S(_065_),
    .X(_030_)
  );
  sky130_fd_sc_hd__mux2_1 _171_ (
    .A0(_128_),
    .A1(_096_),
    .S(_065_),
    .X(_031_)
  );
  sky130_fd_sc_hd__mux2_1 _172_ (
    .A0(_129_),
    .A1(_097_),
    .S(_065_),
    .X(_032_)
  );
  sky130_fd_sc_hd__mux2_1 _173_ (
    .A0(_099_),
    .A1(_067_),
    .S(_065_),
    .X(_002_)
  );
  sky130_fd_sc_hd__mux2_1 _174_ (
    .A0(_100_),
    .A1(_068_),
    .S(_065_),
    .X(_003_)
  );
  sky130_fd_sc_hd__mux2_1 _175_ (
    .A0(_101_),
    .A1(_069_),
    .S(_065_),
    .X(_004_)
  );
  sky130_fd_sc_hd__mux2_1 _176_ (
    .A0(_102_),
    .A1(_070_),
    .S(_065_),
    .X(_005_)
  );
  sky130_fd_sc_hd__mux2_1 _177_ (
    .A0(_103_),
    .A1(_071_),
    .S(_065_),
    .X(_006_)
  );
  sky130_fd_sc_hd__mux2_1 _178_ (
    .A0(_104_),
    .A1(_072_),
    .S(_065_),
    .X(_007_)
  );
  sky130_fd_sc_hd__mux2_1 _179_ (
    .A0(_105_),
    .A1(_073_),
    .S(_065_),
    .X(_008_)
  );
  sky130_fd_sc_hd__mux2_1 _180_ (
    .A0(_106_),
    .A1(_074_),
    .S(_065_),
    .X(_009_)
  );
  sky130_fd_sc_hd__mux2_1 _181_ (
    .A0(_107_),
    .A1(_075_),
    .S(_065_),
    .X(_010_)
  );
  sky130_fd_sc_hd__mux2_1 _182_ (
    .A0(_108_),
    .A1(_076_),
    .S(_065_),
    .X(_011_)
  );
  sky130_fd_sc_hd__mux2_1 _183_ (
    .A0(_110_),
    .A1(_078_),
    .S(_065_),
    .X(_013_)
  );
  sky130_fd_sc_hd__mux2_1 _184_ (
    .A0(_111_),
    .A1(_079_),
    .S(_065_),
    .X(_014_)
  );
  sky130_fd_sc_hd__mux2_1 _185_ (
    .A0(_112_),
    .A1(_080_),
    .S(_065_),
    .X(_015_)
  );
  sky130_fd_sc_hd__mux2_1 _186_ (
    .A0(_113_),
    .A1(_081_),
    .S(_065_),
    .X(_016_)
  );
  sky130_fd_sc_hd__mux2_1 _187_ (
    .A0(_114_),
    .A1(_082_),
    .S(_065_),
    .X(_017_)
  );
  sky130_fd_sc_hd__mux2_1 _188_ (
    .A0(_115_),
    .A1(_083_),
    .S(_065_),
    .X(_018_)
  );
  sky130_fd_sc_hd__mux2_1 _189_ (
    .A0(_116_),
    .A1(_084_),
    .S(_065_),
    .X(_019_)
  );
  sky130_fd_sc_hd__mux2_1 _190_ (
    .A0(_117_),
    .A1(_085_),
    .S(_065_),
    .X(_020_)
  );
  sky130_fd_sc_hd__mux2_1 _191_ (
    .A0(_118_),
    .A1(_086_),
    .S(_065_),
    .X(_021_)
  );
  sky130_fd_sc_hd__mux2_1 _192_ (
    .A0(_119_),
    .A1(_087_),
    .S(_065_),
    .X(_022_)
  );
  sky130_fd_sc_hd__mux2_1 _193_ (
    .A0(_121_),
    .A1(_089_),
    .S(_065_),
    .X(_024_)
  );
  sky130_fd_sc_hd__mux2_1 _194_ (
    .A0(_122_),
    .A1(_090_),
    .S(_065_),
    .X(_025_)
  );
  sky130_fd_sc_hd__mux2_1 _195_ (
    .A0(_098_),
    .A1(_066_),
    .S(_065_),
    .X(_001_)
  );
  sky130_fd_sc_hd__clkinv_1 _196_ (
    .A(_130_),
    .Y(_033_)
  );
  sky130_fd_sc_hd__clkinv_1 _197_ (
    .A(_130_),
    .Y(_034_)
  );
  sky130_fd_sc_hd__clkinv_1 _198_ (
    .A(_130_),
    .Y(_035_)
  );
  sky130_fd_sc_hd__clkinv_1 _199_ (
    .A(_130_),
    .Y(_036_)
  );
  sky130_fd_sc_hd__clkinv_1 _200_ (
    .A(_130_),
    .Y(_037_)
  );
  sky130_fd_sc_hd__clkinv_1 _201_ (
    .A(_130_),
    .Y(_038_)
  );
  sky130_fd_sc_hd__clkinv_1 _202_ (
    .A(_130_),
    .Y(_039_)
  );
  sky130_fd_sc_hd__clkinv_1 _203_ (
    .A(_130_),
    .Y(_040_)
  );
  sky130_fd_sc_hd__clkinv_1 _204_ (
    .A(_130_),
    .Y(_041_)
  );
  sky130_fd_sc_hd__clkinv_1 _205_ (
    .A(_130_),
    .Y(_042_)
  );
  sky130_fd_sc_hd__clkinv_1 _206_ (
    .A(_130_),
    .Y(_043_)
  );
  sky130_fd_sc_hd__clkinv_1 _207_ (
    .A(_130_),
    .Y(_044_)
  );
  sky130_fd_sc_hd__clkinv_1 _208_ (
    .A(_130_),
    .Y(_045_)
  );
  sky130_fd_sc_hd__clkinv_1 _209_ (
    .A(_130_),
    .Y(_046_)
  );
  sky130_fd_sc_hd__clkinv_1 _210_ (
    .A(_130_),
    .Y(_047_)
  );
  sky130_fd_sc_hd__clkinv_1 _211_ (
    .A(_130_),
    .Y(_048_)
  );
  sky130_fd_sc_hd__clkinv_1 _212_ (
    .A(_130_),
    .Y(_049_)
  );
  sky130_fd_sc_hd__clkinv_1 _213_ (
    .A(_130_),
    .Y(_050_)
  );
  sky130_fd_sc_hd__clkinv_1 _214_ (
    .A(_130_),
    .Y(_051_)
  );
  sky130_fd_sc_hd__clkinv_1 _215_ (
    .A(_130_),
    .Y(_052_)
  );
  sky130_fd_sc_hd__clkinv_1 _216_ (
    .A(_130_),
    .Y(_053_)
  );
  sky130_fd_sc_hd__clkinv_1 _217_ (
    .A(_130_),
    .Y(_054_)
  );
  sky130_fd_sc_hd__clkinv_1 _218_ (
    .A(_130_),
    .Y(_055_)
  );
  sky130_fd_sc_hd__clkinv_1 _219_ (
    .A(_130_),
    .Y(_056_)
  );
  sky130_fd_sc_hd__clkinv_1 _220_ (
    .A(_130_),
    .Y(_057_)
  );
  sky130_fd_sc_hd__clkinv_1 _221_ (
    .A(_130_),
    .Y(_058_)
  );
  sky130_fd_sc_hd__clkinv_1 _222_ (
    .A(_130_),
    .Y(_059_)
  );
  sky130_fd_sc_hd__clkinv_1 _223_ (
    .A(_130_),
    .Y(_060_)
  );
  sky130_fd_sc_hd__clkinv_1 _224_ (
    .A(_130_),
    .Y(_061_)
  );
  sky130_fd_sc_hd__clkinv_1 _225_ (
    .A(_130_),
    .Y(_062_)
  );
  sky130_fd_sc_hd__clkinv_1 _226_ (
    .A(_130_),
    .Y(_063_)
  );
  sky130_fd_sc_hd__dfrtp_1 _227_ (
    .CLK(clk),
    .D(_000_[19]),
    .Q(out[19]),
    .RESET_B(_131_)
  );
  sky130_fd_sc_hd__dfrtp_1 _228_ (
    .CLK(clk),
    .D(_000_[20]),
    .Q(out[20]),
    .RESET_B(_132_)
  );
  sky130_fd_sc_hd__dfrtp_1 _229_ (
    .CLK(clk),
    .D(_000_[21]),
    .Q(out[21]),
    .RESET_B(_133_)
  );
  sky130_fd_sc_hd__dfrtp_1 _230_ (
    .CLK(clk),
    .D(_000_[22]),
    .Q(out[22]),
    .RESET_B(_134_)
  );
  sky130_fd_sc_hd__dfrtp_1 _231_ (
    .CLK(clk),
    .D(_000_[23]),
    .Q(out[23]),
    .RESET_B(_135_)
  );
  sky130_fd_sc_hd__dfrtp_1 _232_ (
    .CLK(clk),
    .D(_000_[24]),
    .Q(out[24]),
    .RESET_B(_136_)
  );
  sky130_fd_sc_hd__dfrtp_1 _233_ (
    .CLK(clk),
    .D(_000_[25]),
    .Q(out[25]),
    .RESET_B(_137_)
  );
  sky130_fd_sc_hd__dfrtp_1 _234_ (
    .CLK(clk),
    .D(_000_[26]),
    .Q(out[26]),
    .RESET_B(_138_)
  );
  sky130_fd_sc_hd__dfrtp_1 _235_ (
    .CLK(clk),
    .D(_000_[27]),
    .Q(out[27]),
    .RESET_B(_139_)
  );
  sky130_fd_sc_hd__dfrtp_1 _236_ (
    .CLK(clk),
    .D(_000_[28]),
    .Q(out[28]),
    .RESET_B(_140_)
  );
  sky130_fd_sc_hd__dfrtp_1 _237_ (
    .CLK(clk),
    .D(_000_[29]),
    .Q(out[29]),
    .RESET_B(_141_)
  );
  sky130_fd_sc_hd__dfrtp_1 _238_ (
    .CLK(clk),
    .D(_000_[30]),
    .Q(out[30]),
    .RESET_B(_142_)
  );
  sky130_fd_sc_hd__dfrtp_1 _239_ (
    .CLK(clk),
    .D(_000_[31]),
    .Q(out[31]),
    .RESET_B(_143_)
  );
  sky130_fd_sc_hd__dfrtp_1 _240_ (
    .CLK(clk),
    .D(_000_[0]),
    .Q(out[0]),
    .RESET_B(_144_)
  );
  sky130_fd_sc_hd__dfrtp_1 _241_ (
    .CLK(clk),
    .D(_000_[1]),
    .Q(out[1]),
    .RESET_B(_145_)
  );
  sky130_fd_sc_hd__dfrtp_1 _242_ (
    .CLK(clk),
    .D(_000_[2]),
    .Q(out[2]),
    .RESET_B(_146_)
  );
  sky130_fd_sc_hd__dfrtp_1 _243_ (
    .CLK(clk),
    .D(_000_[3]),
    .Q(out[3]),
    .RESET_B(_147_)
  );
  sky130_fd_sc_hd__dfrtp_1 _244_ (
    .CLK(clk),
    .D(_000_[4]),
    .Q(out[4]),
    .RESET_B(_148_)
  );
  sky130_fd_sc_hd__dfrtp_1 _245_ (
    .CLK(clk),
    .D(_000_[5]),
    .Q(out[5]),
    .RESET_B(_149_)
  );
  sky130_fd_sc_hd__dfrtp_1 _246_ (
    .CLK(clk),
    .D(_000_[6]),
    .Q(out[6]),
    .RESET_B(_150_)
  );
  sky130_fd_sc_hd__dfrtp_1 _247_ (
    .CLK(clk),
    .D(_000_[7]),
    .Q(out[7]),
    .RESET_B(_151_)
  );
  sky130_fd_sc_hd__dfrtp_1 _248_ (
    .CLK(clk),
    .D(_000_[8]),
    .Q(out[8]),
    .RESET_B(_152_)
  );
  sky130_fd_sc_hd__dfrtp_1 _249_ (
    .CLK(clk),
    .D(_000_[9]),
    .Q(out[9]),
    .RESET_B(_153_)
  );
  sky130_fd_sc_hd__dfrtp_1 _250_ (
    .CLK(clk),
    .D(_000_[10]),
    .Q(out[10]),
    .RESET_B(_154_)
  );
  sky130_fd_sc_hd__dfrtp_1 _251_ (
    .CLK(clk),
    .D(_000_[11]),
    .Q(out[11]),
    .RESET_B(_155_)
  );
  sky130_fd_sc_hd__dfrtp_1 _252_ (
    .CLK(clk),
    .D(_000_[12]),
    .Q(out[12]),
    .RESET_B(_156_)
  );
  sky130_fd_sc_hd__dfrtp_1 _253_ (
    .CLK(clk),
    .D(_000_[13]),
    .Q(out[13]),
    .RESET_B(_157_)
  );
  sky130_fd_sc_hd__dfrtp_1 _254_ (
    .CLK(clk),
    .D(_000_[14]),
    .Q(out[14]),
    .RESET_B(_158_)
  );
  sky130_fd_sc_hd__dfrtp_1 _255_ (
    .CLK(clk),
    .D(_000_[15]),
    .Q(out[15]),
    .RESET_B(_159_)
  );
  sky130_fd_sc_hd__dfrtp_1 _256_ (
    .CLK(clk),
    .D(_000_[16]),
    .Q(out[16]),
    .RESET_B(_160_)
  );
  sky130_fd_sc_hd__dfrtp_1 _257_ (
    .CLK(clk),
    .D(_000_[17]),
    .Q(out[17]),
    .RESET_B(_161_)
  );
  sky130_fd_sc_hd__dfrtp_1 _258_ (
    .CLK(clk),
    .D(_000_[18]),
    .Q(out[18]),
    .RESET_B(_162_)
  );
  assign _130_ = rst;
  assign _162_ = _064_;
  assign _109_ = out[1];
  assign _077_ = in[1];
  assign _065_ = en;
  assign _000_[1] = _012_;
  assign _120_ = out[2];
  assign _088_ = in[2];
  assign _000_[2] = _023_;
  assign _123_ = out[3];
  assign _091_ = in[3];
  assign _000_[3] = _026_;
  assign _124_ = out[4];
  assign _092_ = in[4];
  assign _000_[4] = _027_;
  assign _125_ = out[5];
  assign _093_ = in[5];
  assign _000_[5] = _028_;
  assign _126_ = out[6];
  assign _094_ = in[6];
  assign _000_[6] = _029_;
  assign _127_ = out[7];
  assign _095_ = in[7];
  assign _000_[7] = _030_;
  assign _128_ = out[8];
  assign _096_ = in[8];
  assign _000_[8] = _031_;
  assign _129_ = out[9];
  assign _097_ = in[9];
  assign _000_[9] = _032_;
  assign _099_ = out[10];
  assign _067_ = in[10];
  assign _000_[10] = _002_;
  assign _100_ = out[11];
  assign _068_ = in[11];
  assign _000_[11] = _003_;
  assign _101_ = out[12];
  assign _069_ = in[12];
  assign _000_[12] = _004_;
  assign _102_ = out[13];
  assign _070_ = in[13];
  assign _000_[13] = _005_;
  assign _103_ = out[14];
  assign _071_ = in[14];
  assign _000_[14] = _006_;
  assign _104_ = out[15];
  assign _072_ = in[15];
  assign _000_[15] = _007_;
  assign _105_ = out[16];
  assign _073_ = in[16];
  assign _000_[16] = _008_;
  assign _106_ = out[17];
  assign _074_ = in[17];
  assign _000_[17] = _009_;
  assign _107_ = out[18];
  assign _075_ = in[18];
  assign _000_[18] = _010_;
  assign _108_ = out[19];
  assign _076_ = in[19];
  assign _000_[19] = _011_;
  assign _110_ = out[20];
  assign _078_ = in[20];
  assign _000_[20] = _013_;
  assign _111_ = out[21];
  assign _079_ = in[21];
  assign _000_[21] = _014_;
  assign _112_ = out[22];
  assign _080_ = in[22];
  assign _000_[22] = _015_;
  assign _113_ = out[23];
  assign _081_ = in[23];
  assign _000_[23] = _016_;
  assign _114_ = out[24];
  assign _082_ = in[24];
  assign _000_[24] = _017_;
  assign _115_ = out[25];
  assign _083_ = in[25];
  assign _000_[25] = _018_;
  assign _116_ = out[26];
  assign _084_ = in[26];
  assign _000_[26] = _019_;
  assign _117_ = out[27];
  assign _085_ = in[27];
  assign _000_[27] = _020_;
  assign _118_ = out[28];
  assign _086_ = in[28];
  assign _000_[28] = _021_;
  assign _119_ = out[29];
  assign _087_ = in[29];
  assign _000_[29] = _022_;
  assign _121_ = out[30];
  assign _089_ = in[30];
  assign _000_[30] = _024_;
  assign _122_ = out[31];
  assign _090_ = in[31];
  assign _000_[31] = _025_;
  assign _098_ = out[0];
  assign _066_ = in[0];
  assign _000_[0] = _001_;
  assign _131_ = _033_;
  assign _132_ = _034_;
  assign _133_ = _035_;
  assign _134_ = _036_;
  assign _135_ = _037_;
  assign _136_ = _038_;
  assign _137_ = _039_;
  assign _138_ = _040_;
  assign _139_ = _041_;
  assign _140_ = _042_;
  assign _141_ = _043_;
  assign _142_ = _044_;
  assign _143_ = _045_;
  assign _144_ = _046_;
  assign _145_ = _047_;
  assign _146_ = _048_;
  assign _147_ = _049_;
  assign _148_ = _050_;
  assign _149_ = _051_;
  assign _150_ = _052_;
  assign _151_ = _053_;
  assign _152_ = _054_;
  assign _153_ = _055_;
  assign _154_ = _056_;
  assign _155_ = _057_;
  assign _156_ = _058_;
  assign _157_ = _059_;
  assign _158_ = _060_;
  assign _159_ = _061_;
  assign _160_ = _062_;
  assign _161_ = _063_;
endmodule
