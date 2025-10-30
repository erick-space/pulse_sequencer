
package axi_stream_pkg;
    
  // axi_stream_transaction.sv
  class axi_stream_transaction;

      logic [15:0] data;
      logic        last;

      function new(logic [15:0] data = '0, logic last = 0);
          this.data = data;
          this.last = last;
      endfunction

  endclass


  // axi_stream_driver.sv
  class axi_stream_driver;

      virtual axi_stream_tb_if.master_mp axi_if;

      function new(virtual axi_stream_tb_if.master_mp axi_if);
          this.axi_if = axi_if;
      endfunction
 
      task send(axi_stream_transaction trans);
          //@(posedge axi_if.clk);
          axi_if.tdata  <= trans.data;
          axi_if.tlast  <= trans.last;
          axi_if.tvalid <= 1;
          @(posedge axi_if.clk);
          while (!axi_if.tready) @(posedge axi_if.clk);
          axi_if.tvalid <= 0;
      endtask

  endclass

  class axi_stream_monitor;

      // This monitor observes the AXI Stream interface from the slave perspective
      // (i.e., it sees transactions that the driver (master) sends).
      virtual axi_stream_tb_if.slave_mp axi_if;
      mailbox #(axi_stream_transaction) mon_mbx;

      function new(virtual axi_stream_tb_if.slave_mp axi_if);
          this.axi_if = axi_if;
          mon_mbx = new();
      endfunction

      task run();
          axi_stream_transaction trans;
          forever begin
              @(posedge axi_if.clk);
              //if (axi_if.tvalid && axi_if.tready) begin
              if (axi_if.tvalid) begin
                  // Capture a transaction whenever tvalid and tready are both high
                  trans = new();
                  trans.data = axi_if.tdata;
                  trans.last = axi_if.tlast;
                  mon_mbx.put(trans);
              end
          end
      endtask

  endclass
  
    class axi_stream_sequencer;

      // The sequencer holds transactions and provides them to the driver as needed.
      mailbox #(axi_stream_transaction) trans_mbx;

      function new();
          trans_mbx = new();
      endfunction

      // The send task places a transaction into the mailbox.
      // The driver will retrieve and execute these transactions.
      task send(axi_stream_transaction trans);
          trans_mbx.put(trans);
      endtask

  endclass
  

  
endpackage // 

