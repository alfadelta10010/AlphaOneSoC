/* Generated by Yosys 0.9 (git sha1 1979e0b) */

module branchCtrl(bCtrl, r1, r2, bSel);
  wire _000_;
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
  wire _163_;
  wire _164_;
  wire _165_;
  wire _166_;
  wire _167_;
  wire _168_;
  wire _169_;
  wire _170_;
  wire _171_;
  wire _172_;
  wire _173_;
  wire _174_;
  wire _175_;
  wire _176_;
  wire _177_;
  input [2:0] bCtrl;
  output bSel;
  input [31:0] r1;
  input [31:0] r2;
  sky130_fd_sc_hd__clkinv_1 _178_ (
    .A(r2[29]),
    .Y(_147_)
  );
  sky130_fd_sc_hd__clkinv_1 _179_ (
    .A(r1[25]),
    .Y(_148_)
  );
  sky130_fd_sc_hd__clkinv_1 _180_ (
    .A(r1[24]),
    .Y(_149_)
  );
  sky130_fd_sc_hd__clkinv_1 _181_ (
    .A(r2[22]),
    .Y(_150_)
  );
  sky130_fd_sc_hd__clkinv_1 _182_ (
    .A(r1[18]),
    .Y(_151_)
  );
  sky130_fd_sc_hd__clkinv_1 _183_ (
    .A(r1[13]),
    .Y(_152_)
  );
  sky130_fd_sc_hd__clkinv_1 _184_ (
    .A(r1[12]),
    .Y(_153_)
  );
  sky130_fd_sc_hd__clkinv_1 _185_ (
    .A(r2[11]),
    .Y(_154_)
  );
  sky130_fd_sc_hd__clkinv_1 _186_ (
    .A(r1[8]),
    .Y(_155_)
  );
  sky130_fd_sc_hd__clkinv_1 _187_ (
    .A(r2[7]),
    .Y(_156_)
  );
  sky130_fd_sc_hd__clkinv_1 _188_ (
    .A(r1[6]),
    .Y(_157_)
  );
  sky130_fd_sc_hd__clkinv_1 _189_ (
    .A(r1[5]),
    .Y(_158_)
  );
  sky130_fd_sc_hd__clkinv_1 _190_ (
    .A(r1[4]),
    .Y(_159_)
  );
  sky130_fd_sc_hd__clkinv_1 _191_ (
    .A(r1[3]),
    .Y(_160_)
  );
  sky130_fd_sc_hd__clkinv_1 _192_ (
    .A(r1[2]),
    .Y(_161_)
  );
  sky130_fd_sc_hd__clkinv_1 _193_ (
    .A(r1[1]),
    .Y(_162_)
  );
  sky130_fd_sc_hd__clkinv_1 _194_ (
    .A(r1[0]),
    .Y(_163_)
  );
  sky130_fd_sc_hd__nand2b_1 _195_ (
    .A_N(r2[30]),
    .B(r1[30]),
    .Y(_164_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _196_ (
    .A(r2[27]),
    .SLEEP(r1[27]),
    .X(_165_)
  );
  sky130_fd_sc_hd__nand2b_1 _197_ (
    .A_N(r1[26]),
    .B(r2[26]),
    .Y(_166_)
  );
  sky130_fd_sc_hd__nand2_1 _198_ (
    .A(_148_),
    .B(r2[25]),
    .Y(_167_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _199_ (
    .A(r2[24]),
    .SLEEP(r1[24]),
    .X(_168_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _200_ (
    .A(r2[23]),
    .SLEEP(r1[23]),
    .X(_169_)
  );
  sky130_fd_sc_hd__nand2_1 _201_ (
    .A(_150_),
    .B(r1[22]),
    .Y(_170_)
  );
  sky130_fd_sc_hd__xor2_1 _202_ (
    .A(r2[22]),
    .B(r1[22]),
    .X(_171_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _203_ (
    .A(r1[21]),
    .SLEEP(r2[21]),
    .X(_172_)
  );
  sky130_fd_sc_hd__nand2b_1 _204_ (
    .A_N(r2[20]),
    .B(r1[20]),
    .Y(_173_)
  );
  sky130_fd_sc_hd__nor2b_1 _205_ (
    .A(_172_),
    .B_N(_173_),
    .Y(_174_)
  );
  sky130_fd_sc_hd__nand2b_1 _206_ (
    .A_N(r1[19]),
    .B(r2[19]),
    .Y(_175_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _207_ (
    .A(r2[18]),
    .SLEEP(r1[18]),
    .X(_176_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _208_ (
    .A(r2[17]),
    .SLEEP(r1[17]),
    .X(_177_)
  );
  sky130_fd_sc_hd__nand2b_1 _209_ (
    .A_N(r1[16]),
    .B(r2[16]),
    .Y(_000_)
  );
  sky130_fd_sc_hd__nand2b_1 _210_ (
    .A_N(r1[15]),
    .B(r2[15]),
    .Y(_001_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _211_ (
    .A(r2[14]),
    .SLEEP(r1[14]),
    .X(_002_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _212_ (
    .A(r2[13]),
    .SLEEP(r1[13]),
    .X(_003_)
  );
  sky130_fd_sc_hd__nand2_1 _213_ (
    .A(r2[12]),
    .B(_153_),
    .Y(_004_)
  );
  sky130_fd_sc_hd__nand2b_1 _214_ (
    .A_N(r2[9]),
    .B(r1[9]),
    .Y(_005_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _215_ (
    .A(r2[9]),
    .SLEEP(r1[9]),
    .X(_006_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _216_ (
    .A(_005_),
    .SLEEP(_006_),
    .X(_007_)
  );
  sky130_fd_sc_hd__xor2_1 _217_ (
    .A(r2[5]),
    .B(r1[5]),
    .X(_008_)
  );
  sky130_fd_sc_hd__xnor2_1 _218_ (
    .A(r2[3]),
    .B(r1[3]),
    .Y(_009_)
  );
  sky130_fd_sc_hd__xor2_1 _219_ (
    .A(r2[2]),
    .B(r1[2]),
    .X(_010_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _220_ (
    .A(r2[0]),
    .SLEEP(r1[0]),
    .X(_011_)
  );
  sky130_fd_sc_hd__maj3_1 _221_ (
    .A(r2[1]),
    .B(_162_),
    .C(_011_),
    .X(_012_)
  );
  sky130_fd_sc_hd__maj3_1 _222_ (
    .A(r2[2]),
    .B(_161_),
    .C(_012_),
    .X(_013_)
  );
  sky130_fd_sc_hd__maj3_1 _223_ (
    .A(r2[3]),
    .B(_160_),
    .C(_013_),
    .X(_014_)
  );
  sky130_fd_sc_hd__xor2_1 _224_ (
    .A(r2[4]),
    .B(r1[4]),
    .X(_015_)
  );
  sky130_fd_sc_hd__maj3_1 _225_ (
    .A(r2[4]),
    .B(_159_),
    .C(_014_),
    .X(_016_)
  );
  sky130_fd_sc_hd__maj3_1 _226_ (
    .A(r2[5]),
    .B(_158_),
    .C(_016_),
    .X(_017_)
  );
  sky130_fd_sc_hd__nor2_1 _227_ (
    .A(_156_),
    .B(r1[7]),
    .Y(_018_)
  );
  sky130_fd_sc_hd__xnor2_1 _228_ (
    .A(r2[7]),
    .B(r1[7]),
    .Y(_019_)
  );
  sky130_fd_sc_hd__a2bb2oi_1 _229_ (
    .A1_N(_157_),
    .A2_N(r2[6]),
    .B1(r1[7]),
    .B2(_156_),
    .Y(_020_)
  );
  sky130_fd_sc_hd__o21ai_0 _230_ (
    .A1(r2[6]),
    .A2(_157_),
    .B1(_019_),
    .Y(_021_)
  );
  sky130_fd_sc_hd__a21o_1 _231_ (
    .A1(r2[6]),
    .A2(_157_),
    .B1(_021_),
    .X(_022_)
  );
  sky130_fd_sc_hd__o22a_1 _232_ (
    .A1(_018_),
    .A2(_020_),
    .B1(_022_),
    .B2(_017_),
    .X(_023_)
  );
  sky130_fd_sc_hd__xnor2_1 _233_ (
    .A(r2[8]),
    .B(r1[8]),
    .Y(_024_)
  );
  sky130_fd_sc_hd__maj3_1 _234_ (
    .A(r2[8]),
    .B(_155_),
    .C(_023_),
    .X(_025_)
  );
  sky130_fd_sc_hd__o21ai_0 _235_ (
    .A1(_006_),
    .A2(_025_),
    .B1(_005_),
    .Y(_026_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _236_ (
    .A(r1[10]),
    .SLEEP(r2[10]),
    .X(_027_)
  );
  sky130_fd_sc_hd__xor2_1 _237_ (
    .A(r2[11]),
    .B(r1[11]),
    .X(_028_)
  );
  sky130_fd_sc_hd__nor2_1 _238_ (
    .A(_027_),
    .B(_028_),
    .Y(_029_)
  );
  sky130_fd_sc_hd__nand2b_1 _239_ (
    .A_N(r1[10]),
    .B(r2[10]),
    .Y(_030_)
  );
  sky130_fd_sc_hd__maj3_1 _240_ (
    .A(_154_),
    .B(r1[11]),
    .C(_027_),
    .X(_031_)
  );
  sky130_fd_sc_hd__a31o_1 _241_ (
    .A1(_026_),
    .A2(_029_),
    .A3(_030_),
    .B1(_031_),
    .X(_032_)
  );
  sky130_fd_sc_hd__o22ai_1 _242_ (
    .A1(r2[13]),
    .A2(_152_),
    .B1(r2[12]),
    .B2(_153_),
    .Y(_033_)
  );
  sky130_fd_sc_hd__a21oi_1 _243_ (
    .A1(_004_),
    .A2(_032_),
    .B1(_033_),
    .Y(_034_)
  );
  sky130_fd_sc_hd__nor2_1 _244_ (
    .A(_003_),
    .B(_034_),
    .Y(_035_)
  );
  sky130_fd_sc_hd__nor3_1 _245_ (
    .A(_002_),
    .B(_003_),
    .C(_034_),
    .Y(_036_)
  );
  sky130_fd_sc_hd__nand2b_1 _246_ (
    .A_N(r2[15]),
    .B(r1[15]),
    .Y(_037_)
  );
  sky130_fd_sc_hd__nand2b_1 _247_ (
    .A_N(r2[14]),
    .B(r1[14]),
    .Y(_038_)
  );
  sky130_fd_sc_hd__o311ai_0 _248_ (
    .A1(_002_),
    .A2(_003_),
    .A3(_034_),
    .B1(_037_),
    .C1(_038_),
    .Y(_039_)
  );
  sky130_fd_sc_hd__nand2_1 _249_ (
    .A(_001_),
    .B(_039_),
    .Y(_040_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _250_ (
    .A(r1[17]),
    .SLEEP(r2[17]),
    .X(_041_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _251_ (
    .A(r1[16]),
    .SLEEP(r2[16]),
    .X(_042_)
  );
  sky130_fd_sc_hd__nand2b_1 _252_ (
    .A_N(r2[16]),
    .B(r1[16]),
    .Y(_043_)
  );
  sky130_fd_sc_hd__a311o_1 _253_ (
    .A1(_000_),
    .A2(_001_),
    .A3(_039_),
    .B1(_041_),
    .C1(_042_),
    .X(_044_)
  );
  sky130_fd_sc_hd__nand2b_1 _254_ (
    .A_N(_177_),
    .B(_044_),
    .Y(_045_)
  );
  sky130_fd_sc_hd__nor3b_1 _255_ (
    .A(_176_),
    .B(_177_),
    .C_N(_044_),
    .Y(_046_)
  );
  sky130_fd_sc_hd__nand2b_1 _256_ (
    .A_N(r2[19]),
    .B(r1[19]),
    .Y(_047_)
  );
  sky130_fd_sc_hd__o21ai_0 _257_ (
    .A1(r2[18]),
    .A2(_151_),
    .B1(_047_),
    .Y(_048_)
  );
  sky130_fd_sc_hd__o21ai_0 _258_ (
    .A1(_046_),
    .A2(_048_),
    .B1(_175_),
    .Y(_049_)
  );
  sky130_fd_sc_hd__a21oi_1 _259_ (
    .A1(_174_),
    .A2(_049_),
    .B1(_171_),
    .Y(_050_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _260_ (
    .A(r2[21]),
    .SLEEP(r1[21]),
    .X(_051_)
  );
  sky130_fd_sc_hd__nand2b_1 _261_ (
    .A_N(r1[20]),
    .B(r2[20]),
    .Y(_052_)
  );
  sky130_fd_sc_hd__o211ai_1 _262_ (
    .A1(_046_),
    .A2(_048_),
    .B1(_052_),
    .C1(_175_),
    .Y(_053_)
  );
  sky130_fd_sc_hd__a211o_1 _263_ (
    .A1(_174_),
    .A2(_053_),
    .B1(_051_),
    .C1(_171_),
    .X(_054_)
  );
  sky130_fd_sc_hd__nand2b_1 _264_ (
    .A_N(r2[23]),
    .B(r1[23]),
    .Y(_055_)
  );
  sky130_fd_sc_hd__a31o_1 _265_ (
    .A1(_170_),
    .A2(_054_),
    .A3(_055_),
    .B1(_169_),
    .X(_056_)
  );
  sky130_fd_sc_hd__a311oi_1 _266_ (
    .A1(_170_),
    .A2(_054_),
    .A3(_055_),
    .B1(_169_),
    .C1(_168_),
    .Y(_057_)
  );
  sky130_fd_sc_hd__o22ai_1 _267_ (
    .A1(_148_),
    .A2(r2[25]),
    .B1(r2[24]),
    .B2(_149_),
    .Y(_058_)
  );
  sky130_fd_sc_hd__o21ai_0 _268_ (
    .A1(_057_),
    .A2(_058_),
    .B1(_167_),
    .Y(_059_)
  );
  sky130_fd_sc_hd__o211ai_1 _269_ (
    .A1(_057_),
    .A2(_058_),
    .B1(_166_),
    .C1(_167_),
    .Y(_060_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _270_ (
    .A(r1[27]),
    .SLEEP(r2[27]),
    .X(_061_)
  );
  sky130_fd_sc_hd__nand2b_1 _271_ (
    .A_N(r2[26]),
    .B(r1[26]),
    .Y(_062_)
  );
  sky130_fd_sc_hd__nor2b_1 _272_ (
    .A(_061_),
    .B_N(_062_),
    .Y(_063_)
  );
  sky130_fd_sc_hd__a21oi_1 _273_ (
    .A1(_060_),
    .A2(_063_),
    .B1(_165_),
    .Y(_064_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _274_ (
    .A(r1[28]),
    .SLEEP(r2[28]),
    .X(_065_)
  );
  sky130_fd_sc_hd__xor2_1 _275_ (
    .A(r1[29]),
    .B(r2[29]),
    .X(_066_)
  );
  sky130_fd_sc_hd__lpflow_inputiso1p_1 _276_ (
    .A(_065_),
    .SLEEP(_066_),
    .X(_067_)
  );
  sky130_fd_sc_hd__clkinv_1 _277_ (
    .A(_067_),
    .Y(_068_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _278_ (
    .A(r2[28]),
    .SLEEP(r1[28]),
    .X(_069_)
  );
  sky130_fd_sc_hd__a2111oi_0 _279_ (
    .A1(_060_),
    .A2(_063_),
    .B1(_067_),
    .C1(_069_),
    .D1(_165_),
    .Y(_070_)
  );
  sky130_fd_sc_hd__maj3_1 _280_ (
    .A(r1[29]),
    .B(_147_),
    .C(_065_),
    .X(_071_)
  );
  sky130_fd_sc_hd__xnor2_1 _281_ (
    .A(r1[30]),
    .B(r2[30]),
    .Y(_072_)
  );
  sky130_fd_sc_hd__o21ai_0 _282_ (
    .A1(_070_),
    .A2(_071_),
    .B1(_072_),
    .Y(_073_)
  );
  sky130_fd_sc_hd__nand2_1 _283_ (
    .A(_164_),
    .B(_073_),
    .Y(_074_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _284_ (
    .A(r1[31]),
    .SLEEP(r2[31]),
    .X(_075_)
  );
  sky130_fd_sc_hd__nand2b_1 _285_ (
    .A_N(r1[31]),
    .B(r2[31]),
    .Y(_076_)
  );
  sky130_fd_sc_hd__nor2b_1 _286_ (
    .A(_075_),
    .B_N(_076_),
    .Y(_077_)
  );
  sky130_fd_sc_hd__and3_1 _287_ (
    .A(_164_),
    .B(_073_),
    .C(_077_),
    .X(_078_)
  );
  sky130_fd_sc_hd__a21oi_1 _288_ (
    .A1(_164_),
    .A2(_073_),
    .B1(_077_),
    .Y(_079_)
  );
  sky130_fd_sc_hd__nor3_1 _289_ (
    .A(_070_),
    .B(_071_),
    .C(_072_),
    .Y(_080_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _290_ (
    .A(_073_),
    .SLEEP(_080_),
    .X(_081_)
  );
  sky130_fd_sc_hd__o21bai_1 _291_ (
    .A1(_064_),
    .A2(_066_),
    .B1_N(_069_),
    .Y(_082_)
  );
  sky130_fd_sc_hd__a21oi_1 _292_ (
    .A1(_166_),
    .A2(_062_),
    .B1(_059_),
    .Y(_083_)
  );
  sky130_fd_sc_hd__xnor2_1 _293_ (
    .A(r1[25]),
    .B(r2[25]),
    .Y(_084_)
  );
  sky130_fd_sc_hd__nor2_1 _294_ (
    .A(_168_),
    .B(_084_),
    .Y(_085_)
  );
  sky130_fd_sc_hd__o21ai_0 _295_ (
    .A1(r2[24]),
    .A2(_149_),
    .B1(_084_),
    .Y(_086_)
  );
  sky130_fd_sc_hd__a211oi_1 _296_ (
    .A1(_056_),
    .A2(_086_),
    .B1(_085_),
    .C1(_057_),
    .Y(_087_)
  );
  sky130_fd_sc_hd__o21ai_0 _297_ (
    .A1(_057_),
    .A2(_085_),
    .B1(_086_),
    .Y(_088_)
  );
  sky130_fd_sc_hd__a21oi_1 _298_ (
    .A1(_173_),
    .A2(_052_),
    .B1(_049_),
    .Y(_089_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _299_ (
    .A(_175_),
    .SLEEP(_048_),
    .X(_090_)
  );
  sky130_fd_sc_hd__a21oi_1 _300_ (
    .A1(_175_),
    .A2(_047_),
    .B1(_176_),
    .Y(_091_)
  );
  sky130_fd_sc_hd__nor2_1 _301_ (
    .A(_090_),
    .B(_091_),
    .Y(_092_)
  );
  sky130_fd_sc_hd__a21oi_1 _302_ (
    .A1(_045_),
    .A2(_092_),
    .B1(_046_),
    .Y(_093_)
  );
  sky130_fd_sc_hd__a21oi_1 _303_ (
    .A1(_000_),
    .A2(_043_),
    .B1(_040_),
    .Y(_094_)
  );
  sky130_fd_sc_hd__and2_0 _304_ (
    .A(_001_),
    .B(_037_),
    .X(_095_)
  );
  sky130_fd_sc_hd__a21oi_1 _305_ (
    .A1(_038_),
    .A2(_095_),
    .B1(_035_),
    .Y(_096_)
  );
  sky130_fd_sc_hd__a21oi_1 _306_ (
    .A1(_036_),
    .A2(_038_),
    .B1(_096_),
    .Y(_097_)
  );
  sky130_fd_sc_hd__xor2_1 _307_ (
    .A(r2[13]),
    .B(r1[13]),
    .X(_098_)
  );
  sky130_fd_sc_hd__o21ai_0 _308_ (
    .A1(_032_),
    .A2(_098_),
    .B1(_004_),
    .Y(_099_)
  );
  sky130_fd_sc_hd__nor2_1 _309_ (
    .A(_003_),
    .B(_033_),
    .Y(_100_)
  );
  sky130_fd_sc_hd__o21ai_0 _310_ (
    .A1(_032_),
    .A2(_100_),
    .B1(_099_),
    .Y(_101_)
  );
  sky130_fd_sc_hd__a211oi_1 _311_ (
    .A1(_028_),
    .A2(_030_),
    .B1(_029_),
    .C1(_026_),
    .Y(_102_)
  );
  sky130_fd_sc_hd__a31o_1 _312_ (
    .A1(_026_),
    .A2(_029_),
    .A3(_030_),
    .B1(_102_),
    .X(_103_)
  );
  sky130_fd_sc_hd__xnor2_1 _313_ (
    .A(_007_),
    .B(_025_),
    .Y(_104_)
  );
  sky130_fd_sc_hd__xnor2_1 _314_ (
    .A(_023_),
    .B(_024_),
    .Y(_105_)
  );
  sky130_fd_sc_hd__a22oi_1 _315_ (
    .A1(r2[6]),
    .A2(_157_),
    .B1(_017_),
    .B2(_019_),
    .Y(_106_)
  );
  sky130_fd_sc_hd__a21oi_1 _316_ (
    .A1(_017_),
    .A2(_021_),
    .B1(_106_),
    .Y(_107_)
  );
  sky130_fd_sc_hd__nand2_1 _317_ (
    .A(_021_),
    .B(_106_),
    .Y(_108_)
  );
  sky130_fd_sc_hd__xnor2_1 _318_ (
    .A(_008_),
    .B(_016_),
    .Y(_109_)
  );
  sky130_fd_sc_hd__xnor2_1 _319_ (
    .A(_014_),
    .B(_015_),
    .Y(_110_)
  );
  sky130_fd_sc_hd__xnor2_1 _320_ (
    .A(_009_),
    .B(_013_),
    .Y(_111_)
  );
  sky130_fd_sc_hd__o21ai_0 _321_ (
    .A1(_166_),
    .A2(_068_),
    .B1(_165_),
    .Y(_112_)
  );
  sky130_fd_sc_hd__o21ai_0 _322_ (
    .A1(_177_),
    .A2(_041_),
    .B1(_000_),
    .Y(_113_)
  );
  sky130_fd_sc_hd__nand2b_1 _323_ (
    .A_N(_169_),
    .B(_055_),
    .Y(_114_)
  );
  sky130_fd_sc_hd__o21ai_0 _324_ (
    .A1(_150_),
    .A2(r1[22]),
    .B1(_114_),
    .Y(_115_)
  );
  sky130_fd_sc_hd__nand2_1 _325_ (
    .A(_170_),
    .B(_051_),
    .Y(_116_)
  );
  sky130_fd_sc_hd__o211ai_1 _326_ (
    .A1(_114_),
    .A2(_116_),
    .B1(_115_),
    .C1(_113_),
    .Y(_117_)
  );
  sky130_fd_sc_hd__o22ai_1 _327_ (
    .A1(r2[1]),
    .A2(_162_),
    .B1(r2[0]),
    .B2(_163_),
    .Y(_118_)
  );
  sky130_fd_sc_hd__a211oi_1 _328_ (
    .A1(r2[1]),
    .A2(_162_),
    .B1(_011_),
    .C1(_118_),
    .Y(_119_)
  );
  sky130_fd_sc_hd__a21oi_1 _329_ (
    .A1(_166_),
    .A2(_061_),
    .B1(_010_),
    .Y(_120_)
  );
  sky130_fd_sc_hd__o21ai_0 _330_ (
    .A1(_172_),
    .A2(_051_),
    .B1(_052_),
    .Y(_121_)
  );
  sky130_fd_sc_hd__o2111ai_1 _331_ (
    .A1(_002_),
    .A2(_095_),
    .B1(_119_),
    .C1(_120_),
    .D1(_121_),
    .Y(_122_)
  );
  sky130_fd_sc_hd__nor4b_1 _332_ (
    .A(_111_),
    .B(_117_),
    .C(_122_),
    .D_N(_112_),
    .Y(_123_)
  );
  sky130_fd_sc_hd__nand4_1 _333_ (
    .A(_108_),
    .B(_109_),
    .C(_110_),
    .D(_123_),
    .Y(_124_)
  );
  sky130_fd_sc_hd__nor4_1 _334_ (
    .A(_104_),
    .B(_105_),
    .C(_107_),
    .D(_124_),
    .Y(_125_)
  );
  sky130_fd_sc_hd__o2111ai_1 _335_ (
    .A1(_099_),
    .A2(_100_),
    .B1(_101_),
    .C1(_103_),
    .D1(_125_),
    .Y(_126_)
  );
  sky130_fd_sc_hd__nor4_1 _336_ (
    .A(_093_),
    .B(_094_),
    .C(_097_),
    .D(_126_),
    .Y(_127_)
  );
  sky130_fd_sc_hd__o31ai_1 _337_ (
    .A1(_176_),
    .A2(_045_),
    .A3(_090_),
    .B1(_127_),
    .Y(_128_)
  );
  sky130_fd_sc_hd__nor2_1 _338_ (
    .A(_089_),
    .B(_128_),
    .Y(_129_)
  );
  sky130_fd_sc_hd__o21ai_0 _339_ (
    .A1(_050_),
    .A2(_051_),
    .B1(_129_),
    .Y(_130_)
  );
  sky130_fd_sc_hd__nor4b_1 _340_ (
    .A(_083_),
    .B(_087_),
    .C(_130_),
    .D_N(_088_),
    .Y(_131_)
  );
  sky130_fd_sc_hd__a21oi_1 _341_ (
    .A1(_059_),
    .A2(_063_),
    .B1(_069_),
    .Y(_132_)
  );
  sky130_fd_sc_hd__o221ai_1 _342_ (
    .A1(_068_),
    .A2(_082_),
    .B1(_132_),
    .B2(_165_),
    .C1(_131_),
    .Y(_133_)
  );
  sky130_fd_sc_hd__nor4_1 _343_ (
    .A(_078_),
    .B(_079_),
    .C(_081_),
    .D(_133_),
    .Y(_134_)
  );
  sky130_fd_sc_hd__o21a_1 _344_ (
    .A1(bCtrl[0]),
    .A2(bCtrl[1]),
    .B1(_134_),
    .X(_135_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _345_ (
    .A(bCtrl[0]),
    .SLEEP(bCtrl[1]),
    .X(_136_)
  );
  sky130_fd_sc_hd__nor2_1 _346_ (
    .A(_134_),
    .B(_136_),
    .Y(_137_)
  );
  sky130_fd_sc_hd__lpflow_isobufsrc_1 _347_ (
    .A(bCtrl[1]),
    .SLEEP(bCtrl[2]),
    .X(_138_)
  );
  sky130_fd_sc_hd__a21oi_1 _348_ (
    .A1(_074_),
    .A2(_076_),
    .B1(_075_),
    .Y(_139_)
  );
  sky130_fd_sc_hd__nand2b_1 _349_ (
    .A_N(bCtrl[1]),
    .B(bCtrl[2]),
    .Y(_140_)
  );
  sky130_fd_sc_hd__nand2_1 _350_ (
    .A(bCtrl[2]),
    .B(_136_),
    .Y(_141_)
  );
  sky130_fd_sc_hd__nand2_1 _351_ (
    .A(bCtrl[0]),
    .B(_138_),
    .Y(_142_)
  );
  sky130_fd_sc_hd__mux2_1 _352_ (
    .A0(_141_),
    .A1(_142_),
    .S(_139_),
    .X(_143_)
  );
  sky130_fd_sc_hd__a31oi_1 _353_ (
    .A1(_164_),
    .A2(_073_),
    .A3(_076_),
    .B1(_075_),
    .Y(_144_)
  );
  sky130_fd_sc_hd__a21oi_1 _354_ (
    .A1(_140_),
    .A2(_144_),
    .B1(bCtrl[0]),
    .Y(_145_)
  );
  sky130_fd_sc_hd__o21ai_0 _355_ (
    .A1(_138_),
    .A2(_144_),
    .B1(_145_),
    .Y(_146_)
  );
  sky130_fd_sc_hd__o311ai_0 _356_ (
    .A1(bCtrl[2]),
    .A2(_135_),
    .A3(_137_),
    .B1(_143_),
    .C1(_146_),
    .Y(bSel)
  );
endmodule
