#!/bin/bash

# ============================================
# NVIDIA GPU 故障日志收集脚本（支持SSH端口）
# 功能：通过跳板机收集远程节点GPU诊断日志
# 使用：./collect_gpu_logs.sh <目标IP>
# ============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
JUMP_HOST=""
REMOTE_USER="root"
REMOTE_PORT="22"          # 目标服务器SSH端口（默认22）
REMOTE_LOG_DIR="/tmp/gpu_log_$$"

# 显示使用帮助
usage() {
    echo "使用方法: $0 [选项] <目标IP地址>"
    echo ""
    echo "示例:"
    echo "  $0 192.168.1.100                        # 默认22端口"
    echo "  $0 -p 2222 192.168.1.100                # 目标端口2222"
    echo "  $0 -j user@jump 192.168.1.100           # 通过跳板机"
    echo "  $0 -p 2222 -j user@jump:2200 192.168.1.100  # 跳板机2200 + 目标2222"
    echo ""
    echo "选项:"
    echo "  -u <用户名>    指定远程用户名 (默认: root)"
    echo "  -p <端口>      指定目标服务器SSH端口 (默认: 22)"
    echo "  -j <跳板机>    指定跳板机 (格式: user@host 或 user@host:port)"
    echo "  -h             显示此帮助信息"
    exit 1
}

# 解析命令行参数
while getopts "u:p:j:h" opt; do
    case $opt in
        u) REMOTE_USER="$OPTARG" ;;
        p) REMOTE_PORT="$OPTARG" ;;
        j) JUMP_HOST="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

shift $((OPTIND-1))

if [ $# -lt 1 ]; then
    echo -e "${RED}错误: 请指定目标IP地址${NC}"
    usage
fi

TARGET_IP="$1"
COLLECT_TIME=$(date '+%Y%m%d_%H%M%S')

# 解析跳板机端口（如果跳板机地址包含端口）
JUMP_SSH_PORT=""
if [ -n "$JUMP_HOST" ] && [[ "$JUMP_HOST" == *:* ]]; then
    JUMP_SSH_PORT="${JUMP_HOST##*:}"
    JUMP_HOST="${JUMP_HOST%:*}"
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   NVIDIA GPU 故障日志收集工具${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "目标IP:     ${GREEN}${TARGET_IP}${NC}"
echo -e "目标端口:   ${GREEN}${REMOTE_PORT}${NC}"
if [ -n "$JUMP_HOST" ]; then
    if [ -n "$JUMP_SSH_PORT" ]; then
        echo -e "跳板机:     ${GREEN}${JUMP_HOST}:${JUMP_SSH_PORT}${NC}"
    else
        echo -e "跳板机:     ${GREEN}${JUMP_HOST}${NC}"
    fi
fi
echo -e "收集时间:   ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# 构建SSH命令
build_ssh_cmd() {
    local cmd="ssh"
    # 跳板机配置
    if [ -n "$JUMP_HOST" ]; then
        if [ -n "$JUMP_SSH_PORT" ]; then
            cmd="$cmd -J ${JUMP_HOST}:${JUMP_SSH_PORT}"
        else
            cmd="$cmd -J ${JUMP_HOST}"
        fi
    fi
    # 目标端口
    cmd="$cmd -p ${REMOTE_PORT}"
    # 连接选项
    cmd="$cmd -o ConnectTimeout=10"
    cmd="$cmd -o StrictHostKeyChecking=no"
    cmd="$cmd -o ServerAliveInterval=3"
    cmd="$cmd -o ServerAliveCountMax=2"
    echo "$cmd"
}

# 构建SCP命令
build_scp_cmd() {
    local cmd="scp"
    # 跳板机配置
    if [ -n "$JUMP_HOST" ]; then
        if [ -n "$JUMP_SSH_PORT" ]; then
            cmd="$cmd -o ProxyJump=${JUMP_HOST}:${JUMP_SSH_PORT}"
        else
            cmd="$cmd -o ProxyJump=${JUMP_HOST}"
        fi
    fi
    # 目标端口（SCP用大写-P）
    cmd="$cmd -P ${REMOTE_PORT}"
    # 连接选项
    cmd="$cmd -o StrictHostKeyChecking=no"
    cmd="$cmd -o ConnectTimeout=10"
    echo "$cmd"
}

SSH_CMD=$(build_ssh_cmd)
SCP_CMD=$(build_scp_cmd)

# 显示实际使用的命令（调试用）
echo -e "${YELLOW}SSH命令: $SSH_CMD${NC}"
echo ""

# 检查SSH连接
echo -e "${YELLOW}[1/4] 检查SSH连接...${NC}"
if ! $SSH_CMD -q -o BatchMode=yes "${REMOTE_USER}@${TARGET_IP}" "echo 'Connected'" > /dev/null 2>&1; then
    echo -e "${RED}错误: 无法连接到 $TARGET_IP:$REMOTE_PORT${NC}"
    echo "请检查："
    echo "  1. IP地址和端口是否正确"
    echo "  2. SSH密钥是否已配置"
    echo "  3. 网络是否可达"
    echo ""
    echo "手动测试命令："
    echo "  $SSH_CMD ${REMOTE_USER}@${TARGET_IP}"
    exit 1
fi
echo -e "${GREEN}✓ SSH连接成功${NC}"

# 获取节点SN（序列号）
echo -e "${YELLOW}[2/4] 获取节点序列号...${NC}"
NODE_SN=$($SSH_CMD "${REMOTE_USER}@${TARGET_IP}" "dmidecode -s system-serial-number 2>/dev/null || echo 'Unknown'")
if [ -z "$NODE_SN" ] || [ "$NODE_SN" = "Unknown" ] || [ "$NODE_SN" = "Not Specified" ]; then
    NODE_SN=$(echo "$TARGET_IP" | tr '.' '_')
    echo -e "${YELLOW}⚠ 无法获取序列号，使用IP: $NODE_SN${NC}"
else
    echo -e "${GREEN}✓ 节点序列号: $NODE_SN${NC}"
fi

# 创建日志目录
LOG_BASE_DIR="./gpu_logs"
mkdir -p "$LOG_BASE_DIR"
NODE_LOG_DIR="${LOG_BASE_DIR}/${NODE_SN}_${COLLECT_TIME}"
mkdir -p "$NODE_LOG_DIR"
echo -e "${GREEN}✓ 日志目录: $NODE_LOG_DIR${NC}"

# 在远程创建临时目录
echo -e "${YELLOW}[3/4] 远程执行日志收集...${NC}"
$SSH_CMD "${REMOTE_USER}@${TARGET_IP}" "mkdir -p $REMOTE_LOG_DIR"

# 生成远程收集脚本
$SSH_CMD "${REMOTE_USER}@${TARGET_IP}" "cat > ${REMOTE_LOG_DIR}/collect.sh << 'EOFSCRIPT'
#!/bin/bash

LOG_DIR=\"${REMOTE_LOG_DIR}\"
echo \"开始收集日志...\"

cd \"\$LOG_DIR\"

# 1. 收集 nvidia-bug-report（核心）
echo \"[1/5] 收集 nvidia-bug-report.sh...\"
if command -v nvidia-bug-report.sh &> /dev/null; then
    timeout 120 nvidia-bug-report.sh --safe-mode --extra-system-data > nvidia-bug-report.log 2>&1
    if [ -f ../nvidia-bug-report.log.gz ]; then
        mv ../nvidia-bug-report.log.gz . 2>/dev/null || true
    fi
    if [ -f /tmp/nvidia-bug-report.log.gz ]; then
        cp /tmp/nvidia-bug-report.log.gz . 2>/dev/null || true
    fi
    if [ -f nvidia-bug-report.log.gz ]; then
        echo \"nvidia-bug-report.log.gz generated\" >> nvidia-bug-report.log
    fi
else
    echo \"nvidia-bug-report.sh not found\" > nvidia-bug-report.log
fi

# 2. 收集 nvidia-smi -a（核心）
echo \"[2/5] 收集 nvidia-smi -a...\"
nvidia-smi -a > nvidia_smi_a.txt 2>&1

# 3. 收集 nvidia-smi 简要信息
echo \"[3/5] 收集 nvidia-smi 摘要...\"
nvidia-smi > nvidia_smi_summary.txt 2>&1

# 4. 收集 PCI 设备信息
echo \"[4/5] 收集 PCI 设备信息...\"
lspci -nn | grep -i nvidia > lspci_nvidia.txt 2>&1
lspci -vvv -s 47:00.0 > pci_47_00_0.txt 2>&1 || echo \"GPU2 not found\" > pci_47_00_0.txt
lspci -vvv -s 4B:00.0 > pci_4B_00_0.txt 2>&1 || echo \"GPU3 not found\" > pci_4B_00_0.txt
lspci -vvv -s 8A:00.0 > pci_8A_00_0.txt 2>&1 || echo \"GPU4 not found\" > pci_8A_00_0.txt
lspci -vvv -s 8F:00.0 > pci_8F_00_0.txt 2>&1 || echo \"GPU5 not found\" > pci_8F_00_0.txt

# 5. 收集内核日志
echo \"[5/5] 收集内核日志...\"
dmesg | grep -i -E 'nvidia|gpu|pci|iommu|bar|reset|fault|error|warning' | tail -500 > dmesg_nvidia.txt 2>&1
journalctl -k -n 500 | grep -i -E 'nvidia|gpu' > journalctl_nvidia.txt 2>&1

# 6. 收集NVML相关错误
nvidia-smi --query-gpu=index,product_name,gpu_uuid,pci.bus_id --format=csv > gpu_basic_info.txt 2>&1

# 7. 收集系统基本信息
uname -a > uname.txt 2>&1
cat /etc/os-release > os_release.txt 2>&1
lsmod | grep nvidia > lsmod_nvidia.txt 2>&1

# 8. 收集GPU状态
echo \"=== GPU2 (0000:47:00.0) Status ===\" > gpu_problem_status.txt 2>&1
nvidia-smi -i 2 >> gpu_problem_status.txt 2>&1 || echo \"GPU2 not accessible\" >> gpu_problem_status.txt
echo \"=== GPU3 (0000:4B:00.0) Status ===\" >> gpu_problem_status.txt 2>&1
nvidia-smi -i 3 >> gpu_problem_status.txt 2>&1 || echo \"GPU3 not accessible\" >> gpu_problem_status.txt

# 9. 收集PCIe错误统计
echo \"=== PCIe AER Statistics ===\" > pci_aer_stats.txt 2>&1
for dev in /sys/bus/pci/devices/*/aer_stats/; do
    if [ -d \"\$dev\" ]; then
        echo \"\$dev:\" >> pci_aer_stats.txt 2>&1
        cat \"\$dev\"/* 2>/dev/null >> pci_aer_stats.txt 2>&1
    fi
done

echo \"收集完成！\"
EOFSCRIPT"

# 执行远程收集脚本
$SSH_CMD "${REMOTE_USER}@${TARGET_IP}" "chmod +x ${REMOTE_LOG_DIR}/collect.sh && ${REMOTE_LOG_DIR}/collect.sh"

# 下载日志
echo -e "${YELLOW}[4/4] 下载日志到本地...${NC}"
$SCP_CMD "${REMOTE_USER}@${TARGET_IP}:${REMOTE_LOG_DIR}/*" "$NODE_LOG_DIR/" 2>/dev/null || true
$SCP_CMD "${REMOTE_USER}@${TARGET_IP}:${REMOTE_LOG_DIR}/nvidia-bug-report.log.gz" "$NODE_LOG_DIR/" 2>/dev/null || true

# 清理远程临时目录
$SSH_CMD "${REMOTE_USER}@${TARGET_IP}" "rm -rf $REMOTE_LOG_DIR"

# 删除本地临时脚本
rm -f "$NODE_LOG_DIR/collect.sh" 2>/dev/null || true

# 显示下载的文件
echo ""
echo -e "${BLUE}已下载文件列表：${NC}"
ls -lh "$NODE_LOG_DIR/" 2>/dev/null | grep -v "collect.sh"

# 打包
echo -e "${YELLOW}正在打包日志...${NC}"
cd "$NODE_LOG_DIR"
tar -czf "${NODE_SN}_${COLLECT_TIME}_logs.tar.gz" * 2>/dev/null || true
cd - > /dev/null

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  日志收集完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "日志目录: ${BLUE}${NODE_LOG_DIR}${NC}"
echo -e "压缩包:   ${BLUE}${NODE_LOG_DIR}/${NODE_SN}_${COLLECT_TIME}_logs.tar.gz${NC}"
