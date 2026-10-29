
参考设计文件目录：

├─bench                                                      //仿真test bench
├─docs                                                        //参考设计文档
├─ip                                                            //设计调用的相关IP
├─pnr                                                          //工程目录
│  ├─pango_pcie_top.fdc                             //工程约束参考文件
│  ├─pg2l_pcie_dma.pds                              //PDS工程文件
├─simulation                                               //仿真工程目录
│  ├─pango_pcie_top_filelist.f                       //设计file list
│  ├─rt_bridge_top_sim_v1_3_vpAll.vp           //TLP解包组包仿真文件
│  ├─sim.bat                                                //仿真.bat
│  ├─pango_pcie_top_sim.do                        //仿真TCL脚本
│  └─pango_pcie_top_wave.do                     //仿真波形脚本
├─src                                                           //设计实例包含的RTL文件
│  ├─pango_pcie_dma_top.v                         //参考设计顶层文件	
│        │  ├─rt_pcie_dma.v                              //顶层文件
│                │  ├─rt_dma.v                               //dma控制器顶层
│                │  ├─rt_bridge_top_v1_3_vpAll.vp   //tlp解包组包设计文件
│
│
├─linux		//linux驱动文件以及使用说明