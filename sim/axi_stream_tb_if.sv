// axi_stream_if.sv
interface axi_stream_tb_if #(parameter DATA_WIDTH = 16)(input logic clk, input logic reset);

    logic [DATA_WIDTH-1:0] tdata;
    logic                  tvalid;
    logic                  tready;
    logic                  tlast;

    modport master_mp (
        output tdata, tvalid, tlast,
        input  tready, clk, reset
    );

    modport slave_mp (
        input  tdata, tvalid, tlast, clk, reset,
        output tready
    );

endinterface
