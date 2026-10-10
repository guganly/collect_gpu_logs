# collect_gpu_logs
NVIDIA GPU 故障日志一键收集脚本。通过 SSH（支持跳板机和非 22 端口）在远程节点上跑一圈诊断命令，把结果拉回本地按节点序列号归档打包，用于 GPU 掉卡、Xid 报错、PCIe 链路异常之类的现场取证。
