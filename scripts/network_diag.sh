#!/usr/bin/env bash
# =============================================================
# JetBrains AI API 网络诊断脚本
# 目标: 诊断到 api.jetbrains.ai 的网速与延迟问题
# 环境: Ubuntu 24 ARM（Linux）
# 用法: bash scripts/network_diag.sh
# =============================================================

set -euo pipefail

# ── 颜色定义 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_HOST="api.jetbrains.ai"
TARGET_HTTPS="https://api.jetbrains.ai"
# 配额查询接口（轻量无鉴权即可得到响应，用于测延迟）
PROBE_URL="${TARGET_HTTPS}/user/v5/quota/get"
PING_COUNT=10

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     JetBrains AI API 网络诊断工具                   ║"
echo "║     目标: ${TARGET_HOST}               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 0. 依赖检查 ───────────────────────────────────────────────
echo -e "${BOLD}${BLUE}[0/5] 依赖检查${NC}"
MISSING_PKGS=()

check_cmd() {
    local cmd=$1
    local pkg=${2:-$1}
    if ! command -v "${cmd}" &>/dev/null; then
        echo -e "  ${YELLOW}⚠ 缺少 ${cmd}，将尝试安装 ${pkg}${NC}"
        MISSING_PKGS+=("${pkg}")
    else
        echo -e "  ${GREEN}✓ ${cmd}${NC}"
    fi
}

check_cmd curl curl
check_cmd dig dnsutils
check_cmd ping iputils-ping
check_cmd traceroute traceroute
check_cmd bc bc
check_cmd mtr mtr

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "\n  ${CYAN}正在安装缺失依赖: ${MISSING_PKGS[*]}${NC}"
    if sudo apt-get install -y "${MISSING_PKGS[@]}" -qq 2>/dev/null; then
        echo -e "  ${GREEN}✓ 依赖安装完成${NC}"
    else
        echo -e "  ${YELLOW}⚠ 部分依赖安装失败，诊断将尝试继续${NC}"
    fi
fi
echo ""

# ── 1. 出口 IP ────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}[1/5] 当前服务器出口 IP${NC}"
MY_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "获取失败")
echo -e "  出口 IP: ${GREEN}${MY_IP}${NC}"

# 查询 IP 地理位置
GEO=$(curl -s --max-time 5 "https://ipinfo.io/${MY_IP}/json" 2>/dev/null \
      | grep -E '"city"|"region"|"country"|"org"' \
      | sed 's/[",]//g' | sed 's/^  */  /' || echo "  获取失败")
echo -e "  地理信息:\n${GEO}"
echo ""

# ── 2. DNS 解析 ───────────────────────────────────────────────
echo -e "${BOLD}${BLUE}[2/5] DNS 解析${NC}"
DNS_RESULT=$(dig +short "${TARGET_HOST}" 2>/dev/null \
             || nslookup "${TARGET_HOST}" 2>/dev/null | grep "Address:" | tail -n +2 \
             || echo "DNS解析失败")
echo -e "  ${TARGET_HOST} 解析结果:"
echo "${DNS_RESULT}" | while read -r ip; do
    echo -e "    → ${GREEN}${ip}${NC}"
done
# Linux dig 输出格式兼容
DNS_TIME=$(dig "${TARGET_HOST}" 2>/dev/null | grep "Query time" || echo "  DNS查询时间: 不可用")
echo -e "  ${DNS_TIME}"
echo ""

# ── 3. ICMP Ping ──────────────────────────────────────────────
echo -e "${BOLD}${BLUE}[3/5] ICMP Ping 延迟测试 (${PING_COUNT} 次)${NC}"
# Linux ping: -W 单位为秒（macOS 为毫秒），-c 发包次数，-i 间隔
if ping -c "${PING_COUNT}" -W 3 -i 0.5 "${TARGET_HOST}" 2>/dev/null; then
    echo ""
else
    echo -e "  ${YELLOW}⚠ ICMP 被屏蔽（CloudFront 常见），改用 TCP 探测评估延迟${NC}"
    # 用 curl 模拟 TCP ping（仅连接不发数据）
    echo -e "  ${CYAN}TCP connect 延迟（10次）:${NC}"
    for i in $(seq 1 10); do
        T=$(curl -s -o /dev/null -w "%{time_connect}" \
            --max-time 5 --connect-timeout 5 \
            "${TARGET_HTTPS}" 2>/dev/null)
        MS=$(echo "${T} * 1000" | bc 2>/dev/null | cut -d. -f1)
        echo -e "    第${i}次 TCP connect: ${MS}ms"
    done
fi
echo ""

# ── 4. TCP 连接 + TLS 握手延迟 ───────────────────────────────
echo -e "${BOLD}${BLUE}[4/5] TCP/HTTPS 各阶段耗时分析 (连续 5 次)${NC}"
echo -e "  ${CYAN}指标说明: DNS解析 | TCP连接 | TLS握手 | 首字节(TTFB) | 总耗时${NC}"
echo ""

TTFB_SUM=0
TOTAL_SUM=0

for i in $(seq 1 5); do
    RESULT=$(curl -s -o /dev/null -w \
        "DNS:%{time_namelookup}s  TCP:%{time_connect}s  TLS:%{time_appconnect}s  TTFB:%{time_starttransfer}s  Total:%{time_total}s  HTTP:%{http_code}" \
        --max-time 15 \
        -H "grazie-authenticate-jwt: probe-test" \
        "${PROBE_URL}" 2>/dev/null)

    # Linux GNU grep 支持 -oP
    TTFB=$(echo "${RESULT}"  | grep -oP 'TTFB:\K[0-9.]+')
    TOTAL=$(echo "${RESULT}" | grep -oP 'Total:\K[0-9.]+')

    # TTFB 转毫秒（整数）
    TTFB_MS=$(echo "${TTFB} * 1000" | bc 2>/dev/null | cut -d. -f1)

    if [ "${TTFB_MS:-9999}" -lt 500 ]; then
        COLOR="${GREEN}"
    elif [ "${TTFB_MS:-9999}" -lt 1500 ]; then
        COLOR="${YELLOW}"
    else
        COLOR="${RED}"
    fi

    echo -e "  第${i}次: ${RESULT} ${COLOR}[TTFB ${TTFB_MS}ms]${NC}"

    TTFB_SUM=$(echo "${TTFB_SUM} + ${TTFB_MS:-0}" | bc 2>/dev/null)
    TOTAL_SUM=$(echo "${TOTAL_SUM} + ${TOTAL}"     | bc 2>/dev/null)
done
echo ""

# 计算平均值
AVG_TTFB=$(echo  "scale=0; ${TTFB_SUM} / 5" | bc 2>/dev/null)
AVG_TOTAL=$(echo "scale=2; ${TOTAL_SUM} / 5" | bc 2>/dev/null)
echo -e "  ${BOLD}平均 TTFB: ${AVG_TTFB}ms | 平均总耗时: ${AVG_TOTAL}s${NC}"
echo ""

# ── 5. 路由追踪 ───────────────────────────────────────────────
echo -e "${BOLD}${BLUE}[5/5] 路由追踪${NC}"
echo -e "  ${CYAN}追踪到 ${TARGET_HOST} 的路由路径...${NC}"
if command -v mtr &>/dev/null; then
    echo -e "  ${GREEN}使用 mtr（更精准）${NC}"
    # --report-wide 避免截断 IP；Linux mtr 不需要 sudo
    mtr --report --report-cycles 5 --no-dns --report-wide "${TARGET_HOST}" 2>/dev/null \
        || echo -e "  ${YELLOW}mtr 执行失败${NC}"
elif command -v traceroute &>/dev/null; then
    # Linux traceroute: -m 最大跳数，-w 等待秒数，-n 不反解DNS（加速）
    traceroute -m 20 -w 3 -n "${TARGET_HOST}" 2>/dev/null \
        || echo -e "  ${YELLOW}traceroute 执行失败${NC}"
else
    echo -e "  ${YELLOW}⚠ 未找到路由追踪工具，请安装: sudo apt install mtr${NC}"
fi
echo ""

# ── 综合诊断结论 ──────────────────────────────────────────────
echo -e "${BOLD}${CYAN}══════════════════ 综合诊断结论 ══════════════════${NC}"
if [ "${AVG_TTFB:-9999}" -lt 300 ]; then
    echo -e "${GREEN}✅ 网络状况良好：平均 TTFB ${AVG_TTFB}ms，延迟正常${NC}"
elif [ "${AVG_TTFB:-9999}" -lt 1000 ]; then
    echo -e "${YELLOW}⚠  网络延迟偏高：平均 TTFB ${AVG_TTFB}ms，建议检查路由路径${NC}"
    echo -e "   → 可能原因: 出口IP走了次优路由，或运营商高峰拥堵"
    echo -e "   → TLS握手耗时明显高于TCP连接，可考虑开启连接复用"
else
    echo -e "${RED}❌ 网络延迟严重：平均 TTFB ${AVG_TTFB}ms${NC}"
    echo -e "   → 建议: 1) 查看 traceroute/mtr 中哪一跳延迟暴增"
    echo -e "           2) 尝试更换服务器出口IP或机房地域"
    echo -e "           3) 确认出口IP是否被 JetBrains/CloudFront 限速"
    echo -e "           4) 检查 HTTP 客户端是否复用连接池（避免重复TLS握手）"
fi
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
