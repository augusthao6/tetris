module cla8(A, B, Cin, S, P, G, Cout);
    input [7:0] A, B;
    input Cin;

    output [7:0] S;
    output Cout, P, G;

    wire [7:0] p, g;
    wire [8:0] c;

    assign c[0] = Cin;

    //G
    and g0(g[0], A[0], B[0]);
    and g1(g[1], A[1], B[1]);
    and g2(g[2], A[2], B[2]);
    and g3(g[3], A[3], B[3]);
    and g4(g[4], A[4], B[4]);
    and g5(g[5], A[5], B[5]);
    and g6(g[6], A[6], B[6]);
    and g7(g[7], A[7], B[7]);

    //P
    or p0(p[0], A[0], B[0]);
    or p1(p[1], A[1], B[1]);
    or p2(p[2], A[2], B[2]);
    or p3(p[3], A[3], B[3]);
    or p4(p[4], A[4], B[4]);
    or p5(p[5], A[5], B[5]);
    or p6(p[6], A[6], B[6]);
    or p7(p[7], A[7], B[7]);
    
    //C
    wire [7:0] w;
    and(w[0], p[0], c[0]);
    or c1(c[1], g[0], w[0]);
    and(w[1], p[1], c[1]);
    or c2(c[2], g[1], w[1]);
    and(w[2], p[2], c[2]);
    or c3(c[3], g[2], w[2]);
    and(w[3], p[3], c[3]);
    or c4(c[4], g[3], w[3]);
    and(w[4], p[4], c[4]);
    or c5(c[5], g[4], w[4]);
    and(w[5], p[5], c[5]);
    or c6(c[6], g[5], w[5]);
    and(w[6], p[6], c[6]);
    or c7(c[7], g[6], w[6]);
    and(w[7], p[7], c[7]);
    or c8(c[8], g[7], w[7]);
    
    //S A^B^Cin
    wire [7:0] axorb;
    xor ax0(axorb[0], A[0], B[0]);
    xor ax1(axorb[1], A[1], B[1]);
    xor ax2(axorb[2], A[2], B[2]);
    xor ax3(axorb[3], A[3], B[3]);
    xor ax4(axorb[4], A[4], B[4]);
    xor ax5(axorb[5], A[5], B[5]);
    xor ax6(axorb[6], A[6], B[6]);
    xor ax7(axorb[7], A[7], B[7]);
    xor s0(S[0], axorb[0], c[0]);
    xor s1(S[1], axorb[1], c[1]);
    xor s2(S[2], axorb[2], c[2]);
    xor s3(S[3], axorb[3], c[3]);
    xor s4(S[4], axorb[4], c[4]);
    xor s5(S[5], axorb[5], c[5]);
    xor s6(S[6], axorb[6], c[6]);
    xor s7(S[7], axorb[7], c[7]);

    //P block
    and (P, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    //G block
    wire [6:0] x;
    and(x[0], p[7], g[6]);
    and(x[1], p[7], p[6], g[5]);
    and(x[2], p[7], p[6], p[5], g[4]);
    and(x[3], p[7], p[6], p[5], p[4], g[3]);
    and(x[4], p[7], p[6], p[5], p[4], p[3], g[2]);
    and(x[5], p[7], p[6], p[5], p[4], p[3], p[2], g[1]);
    and(x[6], p[7], p[6], p[5], p[4], p[3], p[2], p[1], g[0]);

    or (G, g[7], x[0], x[1], x[2], x[3], x[4], x[5], x[6]);
    assign Cout = c[8];
endmodule