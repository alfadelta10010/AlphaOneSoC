/* Generated by Yosys 0.32+66 (git sha1 b168ff99d, gcc 11.4.0-1ubuntu1~22.04 -fPIC -Os) */

module signExt(opcode, instIn, immOut);
  wire _0_;
  wire _10_;
  wire _11_;
  wire _12_;
  wire _13_;
  wire _14_;
  wire _15_;
  wire _16_;
  wire _17_;
  wire _18_;
  wire _19_;
  wire _1_;
  wire _20_;
  wire _21_;
  wire _22_;
  wire _23_;
  wire _24_;
  wire _25_;
  wire _26_;
  wire _27_;
  wire _28_;
  wire _29_;
  wire _2_;
  wire _30_;
  wire _31_;
  wire _32_;
  wire _33_;
  wire _34_;
  wire _35_;
  wire _36_;
  wire _37_;
  wire _38_;
  wire _39_;
  wire _3_;
  wire _40_;
  wire _41_;
  wire _42_;
  wire _43_;
  wire _44_;
  wire _45_;
  wire _46_;
  wire _47_;
  wire _48_;
  wire _49_;
  wire _4_;
  wire _50_;
  wire _51_;
  wire _52_;
  wire _53_;
  wire _54_;
  wire _55_;
  wire _56_;
  wire _57_;
  wire _58_;
  wire _59_;
  wire _5_;
  wire _60_;
  wire _61_;
  wire _62_;
  wire _63_;
  wire _64_;
  wire _65_;
  wire _66_;
  wire _67_;
  wire _68_;
  wire _69_;
  wire _6_;
  wire _7_;
  wire _8_;
  wire _9_;
  output [31:0] immOut;
  wire [31:0] immOut;
  input [31:0] instIn;
  wire [31:0] instIn;
  input [6:0] opcode;
  wire [6:0] opcode;
  sky130_fd_sc_hd__o22ai_1 _100_ (
    .A1(_7_),
    .A2(_5_),
    .B1(_14_),
    .B2(_13_),
    .Y(_19_)
  );
  sky130_fd_sc_hd__o21ai_0 _101_ (
    .A1(_7_),
    .A2(_13_),
    .B1(_11_),
    .Y(_20_)
  );
  sky130_fd_sc_hd__o21ai_0 _102_ (
    .A1(_20_),
    .A2(_19_),
    .B1(instIn[31]),
    .Y(_21_)
  );
  sky130_fd_sc_hd__nand3_1 _103_ (
    .A(_21_),
    .B(_16_),
    .C(_18_),
    .Y(immOut[12])
  );
  sky130_fd_sc_hd__nand2_1 _104_ (
    .A(_17_),
    .B(instIn[13]),
    .Y(_22_)
  );
  sky130_fd_sc_hd__nand3_1 _105_ (
    .A(_21_),
    .B(_16_),
    .C(_22_),
    .Y(immOut[13])
  );
  sky130_fd_sc_hd__nand2_1 _106_ (
    .A(_17_),
    .B(instIn[14]),
    .Y(_23_)
  );
  sky130_fd_sc_hd__nand3_1 _107_ (
    .A(_21_),
    .B(_16_),
    .C(_23_),
    .Y(immOut[14])
  );
  sky130_fd_sc_hd__nand2_1 _108_ (
    .A(_17_),
    .B(instIn[15]),
    .Y(_24_)
  );
  sky130_fd_sc_hd__nand3_1 _109_ (
    .A(_21_),
    .B(_16_),
    .C(_24_),
    .Y(immOut[15])
  );
  sky130_fd_sc_hd__nand2_1 _110_ (
    .A(_17_),
    .B(instIn[16]),
    .Y(_25_)
  );
  sky130_fd_sc_hd__nand3_1 _111_ (
    .A(_21_),
    .B(_16_),
    .C(_25_),
    .Y(immOut[16])
  );
  sky130_fd_sc_hd__nand2_1 _112_ (
    .A(_17_),
    .B(instIn[17]),
    .Y(_26_)
  );
  sky130_fd_sc_hd__nand3_1 _113_ (
    .A(_21_),
    .B(_16_),
    .C(_26_),
    .Y(immOut[17])
  );
  sky130_fd_sc_hd__nand2_1 _114_ (
    .A(_17_),
    .B(instIn[18]),
    .Y(_27_)
  );
  sky130_fd_sc_hd__nand3_1 _115_ (
    .A(_21_),
    .B(_16_),
    .C(_27_),
    .Y(immOut[18])
  );
  sky130_fd_sc_hd__nand2_1 _116_ (
    .A(_17_),
    .B(instIn[19]),
    .Y(_28_)
  );
  sky130_fd_sc_hd__nand3_1 _117_ (
    .A(_21_),
    .B(_16_),
    .C(_28_),
    .Y(immOut[19])
  );
  sky130_fd_sc_hd__clkinv_1 _118_ (
    .A(instIn[7]),
    .Y(_29_)
  );
  sky130_fd_sc_hd__nand3_1 _119_ (
    .A(_54_),
    .B(_44_),
    .C(_59_),
    .Y(_30_)
  );
  sky130_fd_sc_hd__nand2_1 _120_ (
    .A(_47_),
    .B(_51_),
    .Y(_31_)
  );
  sky130_fd_sc_hd__nand2_1 _121_ (
    .A(_54_),
    .B(_56_),
    .Y(_32_)
  );
  sky130_fd_sc_hd__nand3_1 _122_ (
    .A(_31_),
    .B(_11_),
    .C(_32_),
    .Y(_33_)
  );
  sky130_fd_sc_hd__nand2_1 _123_ (
    .A(_33_),
    .B(instIn[20]),
    .Y(_34_)
  );
  sky130_fd_sc_hd__o21ai_0 _124_ (
    .A1(_29_),
    .A2(_30_),
    .B1(_34_),
    .Y(immOut[0])
  );
  sky130_fd_sc_hd__clkinv_1 _125_ (
    .A(instIn[8]),
    .Y(_35_)
  );
  sky130_fd_sc_hd__nand3_1 _126_ (
    .A(_53_),
    .B(_11_),
    .C(_32_),
    .Y(_36_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _127_ (
    .A1_N(instIn[21]),
    .A2_N(_36_),
    .B1(_35_),
    .B2(_15_),
    .Y(immOut[1])
  );
  sky130_fd_sc_hd__clkinv_1 _128_ (
    .A(instIn[9]),
    .Y(_37_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _129_ (
    .A1_N(instIn[22]),
    .A2_N(_36_),
    .B1(_37_),
    .B2(_15_),
    .Y(immOut[2])
  );
  sky130_fd_sc_hd__clkinv_1 _130_ (
    .A(instIn[10]),
    .Y(_38_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _131_ (
    .A1_N(instIn[23]),
    .A2_N(_36_),
    .B1(_38_),
    .B2(_15_),
    .Y(immOut[3])
  );
  sky130_fd_sc_hd__clkinv_1 _132_ (
    .A(instIn[11]),
    .Y(_39_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _133_ (
    .A1_N(instIn[24]),
    .A2_N(_36_),
    .B1(_39_),
    .B2(_15_),
    .Y(immOut[4])
  );
  sky130_fd_sc_hd__a31oi_1 _134_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_67_),
    .Y(immOut[5])
  );
  sky130_fd_sc_hd__a31oi_1 _135_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_68_),
    .Y(immOut[6])
  );
  sky130_fd_sc_hd__a31oi_1 _136_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_69_),
    .Y(immOut[7])
  );
  sky130_fd_sc_hd__a31oi_1 _137_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_0_),
    .Y(immOut[8])
  );
  sky130_fd_sc_hd__a31oi_1 _138_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_1_),
    .Y(immOut[9])
  );
  sky130_fd_sc_hd__a31oi_1 _139_ (
    .A1(_12_),
    .A2(_15_),
    .A3(_58_),
    .B1(_2_),
    .Y(immOut[10])
  );
  sky130_fd_sc_hd__nand3_1 _140_ (
    .A(_31_),
    .B(_30_),
    .C(_11_),
    .Y(_40_)
  );
  sky130_fd_sc_hd__nand2_1 _141_ (
    .A(_40_),
    .B(instIn[31]),
    .Y(_41_)
  );
  sky130_fd_sc_hd__o22a_2 _142_ (
    .A1(_43_),
    .A2(_9_),
    .B1(_29_),
    .B2(_55_),
    .X(_42_)
  );
  sky130_fd_sc_hd__nand3_1 _143_ (
    .A(_41_),
    .B(_16_),
    .C(_42_),
    .Y(immOut[11])
  );
  sky130_fd_sc_hd__clkinv_1 _144_ (
    .A(instIn[20]),
    .Y(_43_)
  );
  sky130_fd_sc_hd__clkinv_1 _145_ (
    .A(opcode[6]),
    .Y(_44_)
  );
  sky130_fd_sc_hd__clkinv_1 _146_ (
    .A(opcode[2]),
    .Y(_45_)
  );
  sky130_fd_sc_hd__nand2_1 _147_ (
    .A(opcode[1]),
    .B(opcode[0]),
    .Y(_46_)
  );
  sky130_fd_sc_hd__nor3_1 _148_ (
    .A(opcode[3]),
    .B(_45_),
    .C(_46_),
    .Y(_47_)
  );
  sky130_fd_sc_hd__nand3_1 _149_ (
    .A(_47_),
    .B(opcode[4]),
    .C(_44_),
    .Y(_48_)
  );
  sky130_fd_sc_hd__and2_2 _150_ (
    .A(opcode[1]),
    .B(opcode[0]),
    .X(_49_)
  );
  sky130_fd_sc_hd__lpflow_inputiso0p_1 _151_ (
    .A(opcode[2]),
    .SLEEP(opcode[3]),
    .X(_50_)
  );
  sky130_fd_sc_hd__and3b_2 _152_ (
    .A_N(opcode[4]),
    .B(opcode[5]),
    .C(opcode[6]),
    .X(_51_)
  );
  sky130_fd_sc_hd__and2_2 _153_ (
    .A(opcode[3]),
    .B(opcode[2]),
    .X(_52_)
  );
  sky130_fd_sc_hd__o211ai_1 _154_ (
    .A1(_52_),
    .A2(_50_),
    .B1(_49_),
    .C1(_51_),
    .Y(_53_)
  );
  sky130_fd_sc_hd__nor3_1 _155_ (
    .A(opcode[3]),
    .B(opcode[2]),
    .C(_46_),
    .Y(_54_)
  );
  sky130_fd_sc_hd__nand2_1 _156_ (
    .A(_51_),
    .B(_54_),
    .Y(_55_)
  );
  sky130_fd_sc_hd__nor3b_1 _157_ (
    .A(opcode[5]),
    .B(opcode[6]),
    .C_N(opcode[4]),
    .Y(_56_)
  );
  sky130_fd_sc_hd__nand3b_1 _158_ (
    .A_N(instIn[13]),
    .B(instIn[12]),
    .C(instIn[14]),
    .Y(_57_)
  );
  sky130_fd_sc_hd__nand3_1 _159_ (
    .A(_54_),
    .B(_56_),
    .C(_57_),
    .Y(_58_)
  );
  sky130_fd_sc_hd__and2b_2 _160_ (
    .A_N(opcode[4]),
    .B(opcode[5]),
    .X(_59_)
  );
  sky130_fd_sc_hd__nor2_1 _161_ (
    .A(opcode[4]),
    .B(opcode[5]),
    .Y(_60_)
  );
  sky130_fd_sc_hd__o211ai_1 _162_ (
    .A1(_60_),
    .A2(_59_),
    .B1(_44_),
    .C1(_54_),
    .Y(_61_)
  );
  sky130_fd_sc_hd__nand4_1 _163_ (
    .A(_53_),
    .B(_61_),
    .C(_55_),
    .D(_58_),
    .Y(_62_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _164_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_43_),
    .B2(_48_),
    .Y(immOut[20])
  );
  sky130_fd_sc_hd__clkinv_1 _165_ (
    .A(instIn[21]),
    .Y(_63_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _166_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_63_),
    .B2(_48_),
    .Y(immOut[21])
  );
  sky130_fd_sc_hd__clkinv_1 _167_ (
    .A(instIn[22]),
    .Y(_64_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _168_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_64_),
    .B2(_48_),
    .Y(immOut[22])
  );
  sky130_fd_sc_hd__clkinv_1 _169_ (
    .A(instIn[23]),
    .Y(_65_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _170_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_65_),
    .B2(_48_),
    .Y(immOut[23])
  );
  sky130_fd_sc_hd__clkinv_1 _171_ (
    .A(instIn[24]),
    .Y(_66_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _70_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_66_),
    .B2(_48_),
    .Y(immOut[24])
  );
  sky130_fd_sc_hd__clkinv_1 _71_ (
    .A(instIn[25]),
    .Y(_67_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _72_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_67_),
    .B2(_48_),
    .Y(immOut[25])
  );
  sky130_fd_sc_hd__clkinv_1 _73_ (
    .A(instIn[26]),
    .Y(_68_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _74_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_68_),
    .B2(_48_),
    .Y(immOut[26])
  );
  sky130_fd_sc_hd__clkinv_1 _75_ (
    .A(instIn[27]),
    .Y(_69_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _76_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_69_),
    .B2(_48_),
    .Y(immOut[27])
  );
  sky130_fd_sc_hd__clkinv_1 _77_ (
    .A(instIn[28]),
    .Y(_0_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _78_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_0_),
    .B2(_48_),
    .Y(immOut[28])
  );
  sky130_fd_sc_hd__clkinv_1 _79_ (
    .A(instIn[29]),
    .Y(_1_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _80_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_1_),
    .B2(_48_),
    .Y(immOut[29])
  );
  sky130_fd_sc_hd__clkinv_1 _81_ (
    .A(instIn[30]),
    .Y(_2_)
  );
  sky130_fd_sc_hd__o2bb2ai_1 _82_ (
    .A1_N(instIn[31]),
    .A2_N(_62_),
    .B1(_2_),
    .B2(_48_),
    .Y(immOut[30])
  );
  sky130_fd_sc_hd__clkinv_1 _83_ (
    .A(instIn[31]),
    .Y(_3_)
  );
  sky130_fd_sc_hd__clkinv_1 _84_ (
    .A(opcode[3]),
    .Y(_4_)
  );
  sky130_fd_sc_hd__nand4_1 _85_ (
    .A(_4_),
    .B(opcode[1]),
    .C(opcode[0]),
    .D(opcode[2]),
    .Y(_5_)
  );
  sky130_fd_sc_hd__clkinv_1 _86_ (
    .A(opcode[4]),
    .Y(_6_)
  );
  sky130_fd_sc_hd__nand3_1 _87_ (
    .A(_6_),
    .B(opcode[5]),
    .C(opcode[6]),
    .Y(_7_)
  );
  sky130_fd_sc_hd__nand4_1 _88_ (
    .A(opcode[1]),
    .B(opcode[0]),
    .C(opcode[3]),
    .D(opcode[2]),
    .Y(_8_)
  );
  sky130_fd_sc_hd__nand3b_1 _89_ (
    .A_N(_8_),
    .B(opcode[6]),
    .C(_59_),
    .Y(_9_)
  );
  sky130_fd_sc_hd__nor2_1 _90_ (
    .A(opcode[3]),
    .B(opcode[2]),
    .Y(_10_)
  );
  sky130_fd_sc_hd__nand4_1 _91_ (
    .A(_49_),
    .B(_44_),
    .C(_10_),
    .D(_60_),
    .Y(_11_)
  );
  sky130_fd_sc_hd__o211a_1 _92_ (
    .A1(_5_),
    .A2(_7_),
    .B1(_11_),
    .C1(_9_),
    .X(_12_)
  );
  sky130_fd_sc_hd__nand3_1 _93_ (
    .A(_10_),
    .B(opcode[1]),
    .C(opcode[0]),
    .Y(_13_)
  );
  sky130_fd_sc_hd__nand3_1 _94_ (
    .A(_6_),
    .B(_44_),
    .C(opcode[5]),
    .Y(_14_)
  );
  sky130_fd_sc_hd__a21o_2 _95_ (
    .A1(_14_),
    .A2(_7_),
    .B1(_13_),
    .X(_15_)
  );
  sky130_fd_sc_hd__a41oi_1 _96_ (
    .A1(_12_),
    .A2(_48_),
    .A3(_15_),
    .A4(_58_),
    .B1(_3_),
    .Y(immOut[31])
  );
  sky130_fd_sc_hd__nand4_1 _97_ (
    .A(_54_),
    .B(instIn[31]),
    .C(_56_),
    .D(_57_),
    .Y(_16_)
  );
  sky130_fd_sc_hd__o31ai_1 _98_ (
    .A1(_6_),
    .A2(opcode[6]),
    .A3(_5_),
    .B1(_9_),
    .Y(_17_)
  );
  sky130_fd_sc_hd__nand2_1 _99_ (
    .A(_17_),
    .B(instIn[12]),
    .Y(_18_)
  );
endmodule
