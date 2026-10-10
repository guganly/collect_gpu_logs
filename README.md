# collect_gpu_logs.sh

NVIDIA GPU 故障日志一键收集脚本。通过 SSH（支持跳板机和非 22 端口）在远程节点上跑一圈诊断命令，把结果拉回本地按节点序列号归档打包，用于 GPU 掉卡、Xid 报错、PCIe 链路异常之类的现场取证。

## 用法

```bash
chmod +x collect_gpu_logs.sh

./collect_gpu_logs.sh 10.0.0.11                             # 默认 22 端口
./collect_gpu_logs.sh -p 2222 10.0.0.11                     # 目标 2222 端口
./collect_gpu_logs.sh -j ops@jump.host 10.0.0.11            # 走跳板机
./collect_gpu_logs.sh -p 2222 -j ops@jump.host:2200 10.0.0.11  # 跳板 2200 + 目标 2222
./collect_gpu_logs.sh -u admin 10.0.0.11                    # 指定远程用户
```

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `-p` | 目标服务器 SSH 端口 | 22 |
| `-j` | 跳板机，格式 `user@host` 或 `user@host:port` | 不启用 |
| `-u` | 远程用户名 | root |
| `-h` | 帮助 | — |

## 收集内容

- `nvidia-bug-report.log.gz`：官方 bug report（`--safe-mode --extra-system-data`，120s 超时）
- `nvidia_smi_a.txt` / `nvidia_smi_summary.txt`：`nvidia-smi -a` 全量 + 摘要
- `lspci_nvidia.txt` + `pci_<BDF>.txt`：NVIDIA 设备清单和指定槽位的 `lspci -vvv`
- `dmesg_nvidia.txt` / `journalctl_nvidia.txt`：内核日志里 GPU 相关的过滤结果
- `gpu_basic_info.txt`：GPU 索引、型号、UUID、PCI Bus ID（CSV）
- `gpu_problem_status.txt` / `pci_aer_stats.txt`：异常卡状态 + PCIe AER 错误计数
- `uname.txt` / `os_release.txt` / `lsmod_nvidia.txt`：系统版本与驱动模块

## 产出

```
./gpu_logs/<节点SN>_<时间戳>/
./gpu_logs/<节点SN>_<时间戳>/<节点SN>_<时间戳>_logs.tar.gz
```

取不到 SN（无 dmidecode 或非 root）时用 IP 当目录名。远程临时目录在收集完自动删除。

## 前提

- 本机到目标免密 SSH 已配好（脚本用 `BatchMode=yes`，密码登录会直接失败）
- 目标机有 `nvidia-smi`、`lspci`、`dmidecode`，且当前用户有 root 权限
- 目标机 `/tmp` 可写

## 注意

脚本里的 `lspci -vvv -s` 槽位（`47:00.0` / `4B:00.0` / `8A:00.0` / `8F:00.0`）和 `nvidia-smi -i` 的 GPU 索引是针对当时那台机器硬编码的，换机型或换故障卡记得先改这几行，否则只会收到 `not found`。
