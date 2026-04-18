module cla32(A, B, Cin, S, Cout);
    input [31:0] A, B;
    input Cin;
    output [31:0] S;
    output Cout;

    wire [3:0] P, G;
    wire [3:0] c;
    assign c[0] = Cin;

    cla8 block0(.A(A[7:0]),   .B(B[7:0]),   .Cin(c[0]), .S(S[7:0]),   .P(P[0]), .G(G[0]));
    cla8 block1(.A(A[15:8]),  .B(B[15:8]),  .Cin(c[1]), .S(S[15:8]),  .P(P[1]), .G(G[1]));
    cla8 block2(.A(A[23:16]), .B(B[23:16]), .Cin(c[2]), .S(S[23:16]), .P(P[2]), .G(G[2]));
    cla8 block3(.A(A[31:24]), .B(B[31:24]), .Cin(c[3]), .S(S[31:24]), .P(P[3]), .G(G[3]));

    //c8
    wire w1;
    and(w1, P[0], c[0]);
    or (c[1], G[0], w1);

    //c16
    wire w2, w3;
    and(w2, P[1], G[0]);
    and(w3, P[1], P[0], c[0]);
    or(c[2], G[1], w2, w3);

    //c24
    wire w4, w5, w6;
    and(w4, P[2], G[1]);
    and(w5, P[2], P[1], G[0]);
    and(w6, P[2], P[1], P[0], c[0]);
    or(c[3], G[2], w4, w5, w6);

    //Cout
    wire w7, w8, w9, w10;
    and(w7, P[3], G[2]);
    and(w8, P[3], P[2], G[1]);
    and(w9, P[3], P[2], P[1], G[0]);
    and(w10, P[3], P[2], P[1], P[0], c[0]);
    or(Cout, G[3], w7, w8, w9, w10);
endmodule