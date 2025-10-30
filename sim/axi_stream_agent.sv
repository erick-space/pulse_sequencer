
import axi_stream_pkg::*;

class axi_stream_agent;

  axi_stream_driver    driver;
  axi_stream_sequencer sequencer;
  axi_stream_monitor   monitor;
  virtual axi_stream_tb_if axi_if_master;
  virtual axi_stream_tb_if axi_if_slave;

  function new(virtual axi_stream_tb_if axi_if_master, virtual axi_stream_tb_if axi_if_slave);
      this.axi_if_master = axi_if_master;
      this.axi_if_slave = axi_if_slave;
      driver    = new(axi_if_master.master_mp);
      sequencer = new();
      monitor   = new(axi_if_slave.slave_mp);
  endfunction

  task run();
      fork
          driver_run();
          monitor.run();
      join_none
  endtask
  
  axi_stream_transaction trans;
  task driver_run();
      
      forever begin
          sequencer.trans_mbx.get(trans);
          driver.send(trans);
      end
  endtask

endclass 
