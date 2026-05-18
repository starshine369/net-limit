#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# 项目：Linux 通用双向网络限速面板 (HTB+FQ+IFB 架构)
# 仓库：https://github.com/starshine369/net-limit
# 兼容：Debian / Ubuntu / CentOS / RHEL / Arch 等基于 Systemd 的系统
# 特性：支持下载+上传双向限速、多网卡独立配置、BBR兼容、开机自动恢复
# =========================================================

CONFIG_FILE="/etc/network-limit.conf"
INSTALL_PATH="/usr/local/bin/net-limit"
SERVICE_PATH="/etc/systemd/system/net-limit.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}[错误]${NC} 请使用 root 权限运行此脚本。"
    exit 1
  fi
}

need_cmd() {
  local missing=0
  for cmd in tc ip awk grep sed rm chmod systemctl modprobe curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo -e "${RED}[错误]${NC} 缺少必备命令：$cmd"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    echo -e "${YELLOW}[提示]${NC} 请根据您的系统包管理器安装必备依赖："
    echo "Debian/Ubuntu: apt update && apt install -y iproute2 systemd gawk grep sed coreutils kmod curl"
    echo "CentOS/RHEL:   yum install -y iproute systemd gawk grep sed coreutils kmod curl"
    exit 1
  fi
}

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    touch "$CONFIG_FILE"
  fi
}

# 加载 ifb 内核模块（用于下载限速重定向）
ensure_ifb() {
  modprobe ifb 2>/dev/null || true
}

list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' | grep -v '^ifb'
}

get_saved_limit() {
  local iface="$1"
  grep "^${iface} " "$CONFIG_FILE" 2>/dev/null || true
}

save_limit_config() {
  local iface="$1"
  local up="$2"
  local down="$3"
  ensure_config
  sed -i "/^${iface} /d" "$CONFIG_FILE"
  echo "${iface} ${up} ${down}" >> "$CONFIG_FILE"
}

remove_limit_config() {
  local iface="$1"
  ensure_config
  sed -i "/^${iface} /d" "$CONFIG_FILE"
}

apply_limit() {
  local iface="$1"
  local up_mbit="$2"
  local down_mbit="$3"
  local ifb_dev="ifb_${iface}"

  # 1. 清理旧规则
  clear_limit_silent "$iface"

  # 2. 上传限速 (Egress -> 直接在物理网卡 root 处理)
  if [[ "$up_mbit" -gt 0 ]]; then
    tc qdisc add dev "$iface" root handle 1: htb default 10
    tc class add dev "$iface" parent 1: classid 1:10 htb rate "${up_mbit}mbit" burst 32k
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq
  fi

  # 3. 下载限速 (Ingress -> 重定向到虚拟 ifb 网卡处理)
  if [[ "$down_mbit" -gt 0 ]]; then
    ip link add name "$ifb_dev" type ifb 2>/dev/null || true
    ip link set dev "$ifb_dev" up
    
    tc qdisc add dev "$iface" handle ffff: ingress
    tc filter add dev "$iface" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$ifb_dev"
    
    tc qdisc add dev "$ifb_dev" root handle 1: htb default 10
    tc class add dev "$ifb_dev" parent 1: classid 1:10 htb rate "${down_mbit}mbit" burst 32k
    tc qdisc add dev "$ifb_dev" parent 1:10 handle 10: fq
  fi

  save_limit_config "$iface" "$up_mbit" "$down_mbit"
}

clear_limit_silent() {
  local iface="$1"
  local ifb_dev="ifb_${iface}"
  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc del dev "$iface" ingress 2>/dev/null || true
  ip link delete dev "$ifb_dev" 2>/dev/null || true
}

clear_limit() {
  local iface="$1"
  clear_limit_silent "$iface"
  remove_limit_config "$iface"
  echo -e "${GREEN}[成功]${NC} 已解除网卡 ${iface} 的所有双向限速！"
}

show_all_status() {
  echo -e "${CYAN}=== 当前网卡限速概览 ===${NC}"
  local ifaces
  mapfile -t ifaces < <(list_ifaces)
  
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo "未检测到可用物理网卡。"
    return
  fi

  printf "%-15s %-15s %-15s\n" "网卡名称" "上传限制" "下载限制"
  echo "----------------------------------------------"
  for iface in "${ifaces[@]}"; do
    local saved up down
    saved=$(get_saved_limit "$iface")
    if [[ -n "$saved" ]]; then
      up=$(echo "$saved" | awk '{print $2}')
      down=$(echo "$saved" | awk '{print $3}')
      [[ "$up" == "0" ]] && up="无限制" || up="${up} Mbps"
      [[ "$down" == "0" ]] && down="无限制" || down="${down} Mbps"
      printf "%-15s %-15s %-15s\n" "$iface" "$up" "$down"
    else
      printf "%-15s %-15s %-15s\n" "$iface" "无限制" "无限制"
    fi
  done
  echo "----------------------------------------------"
}

interactive_set_limit() {
  local ifaces choice idx iface
  mapfile -t ifaces < <(list_ifaces)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo -e "${RED}[错误]${NC} 未检测到可用网卡。"
    return
  fi

  echo -e "${CYAN}请选择要设置限速的网卡：${NC}"
  for idx in "${!ifaces[@]}"; do
    echo "$((idx+1)). ${ifaces[$idx]}"
  done
  echo "0. 取消并返回"
  read -r -p "请输入序号: " choice

  if [[ "$choice" == "0" ]]; then return; fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
    iface="${ifaces[$((choice-1))]}"
    
    echo -e "\n您选择了网卡: ${YELLOW}${iface}${NC}"
    echo "提示：输入 0 表示不限制。"
    
    local up_rate down_rate
    read -r -p "1. 请输入【上传】限速值 (单位 Mbps): " up_rate
    if ! [[ "$up_rate" =~ ^[0-9]+$ ]]; then echo -e "${RED}错误：必须输入非负整数。${NC}"; return; fi
    
    read -r -p "2. 请输入【下载】限速值 (单位 Mbps): " down_rate
    if ! [[ "$down_rate" =~ ^[0-9]+$ ]]; then echo -e "${RED}错误：必须输入非负整数。${NC}"; return; fi

    if [[ "$up_rate" -eq 0 ]] && [[ "$down_rate" -eq 0 ]]; then
      clear_limit "$iface"
    else
      apply_limit "$iface" "$up_rate" "$down_rate"
      echo -e "${GREEN}[成功]${NC} 网卡 ${iface} 已生效: 上传 ${up_rate}Mbps / 下载 ${down_rate}Mbps"
    fi
  else
    echo -e "${RED}[错误]${NC} 无效的序号。"
  fi
}

interactive_clear_limit() {
  local ifaces choice idx iface
  mapfile -t ifaces < <(list_ifaces)
  
  echo -e "${CYAN}请选择要解除限速的网卡：${NC}"
  for idx in "${!ifaces[@]}"; do
    echo "$((idx+1)). ${ifaces[$idx]}"
  done
  echo "99. 解除所有网卡的限速"
  echo "0. 取消并返回"
  read -r -p "请输入序号: " choice

  if [[ "$choice" == "0" ]]; then return; fi

  if [[ "$choice" == "99" ]]; then
    for i in "${ifaces[@]}"; do
      clear_limit "$i"
    done
    echo -e "${GREEN}[成功]${NC} 所有网卡限速已解除。"
    return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
    iface="${ifaces[$((choice-1))]}"
    clear_limit "$iface"
  else
    echo -e "${RED}[错误]${NC} 无效的序号。"
  fi
}

auto_apply_saved_limit() {
  ensure_ifb
  ensure_config
  while read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    local iface up down
    iface=$(echo "$line" | awk '{print $1}')
    up=$(echo "$line" | awk '{print $2}')
    down=$(echo "$line" | awk '{print $3}')
    
    if ip link show "$iface" >/dev/null 2>&1; then
      apply_limit "$iface" "$up" "$down"
      echo "已恢复: $iface (上传: ${up}Mbps, 下载: ${down}Mbps)"
    fi
  done < "$CONFIG_FILE"
}

install_service() {
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Linux Network Limit Auto-Restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --apply-saved
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable net-limit.service >/dev/null
  echo -e "${GREEN}[成功]${NC} 已部署防重启断网护城河！每次开机会自动恢复您的限速规则。"
}

uninstall_panel() {
  echo -e "${YELLOW}警告：您即将彻底卸载此限速面板及相关服务。${NC}"
  
  read -r -p "是否同时【清除当前正在生效的限速规则】？(y/n，默认 y 清除): " clear_rules
  if [[ ! "$clear_rules" =~ ^[Nn]$ ]]; then
    local ifaces
    mapfile -t ifaces < <(list_ifaces)
    for i in "${ifaces[@]}"; do
      clear_limit_silent "$i"
    done
    echo -e "${GREEN}[成功]${NC} 已拔除底层所有限速阀门，网络恢复满速。"
  else
    echo -e "${CYAN}[提示]${NC} 已保留当前限速规则（将在下次重启服务器后失效）。"
  fi

  if [[ -f "$SERVICE_PATH" ]]; then
    systemctl disable net-limit.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    echo -e "${GREEN}[成功]${NC} 已移除开机自启服务。"
  fi

  if [[ -f "$INSTALL_PATH" ]]; then
    rm -f "$INSTALL_PATH"
    echo -e "${GREEN}[成功]${NC} 已删除全局快捷命令 (net-limit)。"
  fi

  read -r -p "是否删除历史限速配置文件 ($CONFIG_FILE)？(y/n，默认 y 删除): " rm_conf
  if [[ ! "$rm_conf" =~ ^[Nn]$ ]]; then
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}[成功]${NC} 已销毁配置文件。"
  fi

  echo -e "${GREEN}卸载完成！感谢您的使用。${NC}"
  exit 0
}

pause_wait() {
  echo ""
  read -r -p "按回车键继续主菜单.." _
}

menu() {
  clear || true
  echo -e "${YELLOW}========================================${NC}"
  echo -e "${CYAN}        Linux 通用双向限速面板          ${NC}"
  echo -e "${YELLOW}========================================${NC}"
  echo " 1. 查看所有网卡限速概览"
  echo " 2. 设置/修改网卡限速 (自定义速率)"
  echo " 3. 解除网卡限速"
  echo " ---------------------------------------"
  echo " 4. 开启/更新 开机自动恢复配置"
  echo " 5. 彻底卸载面板及服务"
  echo " 0. 退出面板"
  echo -e "${YELLOW}========================================${NC}"
}

main() {
  need_root
  need_cmd
  ensure_ifb
  ensure_config

  # 🚀 核心优化：静默自举安装机制
  # 当用户通过 bash <(curl...) 纯内存运行时，脚本会自动把最新版拉取到系统全局目录
  if [[ ! -f "$INSTALL_PATH" ]]; then
    curl -sL https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh -o "$INSTALL_PATH" 2>/dev/null || true
    chmod +x "$INSTALL_PATH" 2>/dev/null || true
  fi

  # 开机自启入口
  if [[ "${1:-}" == "--apply-saved" ]]; then
    auto_apply_saved_limit
    exit 0
  fi

  local choice
  while true; do
    menu
    read -r -p "请输入对应的数字 [0-5]: " choice
    case "$choice" in
      1) show_all_status; pause_wait ;;
      2) interactive_set_limit; pause_wait ;;
      3) interactive_clear_limit; pause_wait ;;
      4) install_service; pause_wait ;;
      5) uninstall_panel ;;
      0) echo "已退出。"; exit 0 ;;
      *) echo -e "${RED}[错误]${NC} 请输入有效的数字。"; sleep 1 ;;
    esac
  done
}

main "$@"