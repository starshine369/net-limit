#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# 项目：Linux 通用双向网络限速面板 (HTB+FQ+IFB 架构)
# 仓库：https://github.com/starshine369/net-limit
# 兼容：Debian / Ubuntu / CentOS / RHEL / Arch 等基于 Systemd 的系统
# 特性：支持下载+上传双向限速、多网卡独立配置、MTU限制、BBR兼容、开机自动恢复
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
  for cmd in tc ip awk grep sed rm chmod systemctl modprobe curl mktemp mv cat sleep; do
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
  ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | awk '$0 != "lo" && $0 !~ /^ifb/'
}

iface_exists() {
  local iface="$1"
  [[ -d "/sys/class/net/${iface}" ]]
}

is_nonneg_int() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]]
}

validate_rate_value() {
  local value="$1"
  is_nonneg_int "$value"
}

validate_mtu_value() {
  local mtu="$1"
  if ! is_nonneg_int "$mtu"; then
    return 1
  fi
  if [[ "$mtu" -eq 0 ]]; then
    return 0
  fi
  [[ "$mtu" -ge 576 && "$mtu" -le 9000 ]]
}

get_current_mtu() {
  local iface="$1"
  local mtu_file="/sys/class/net/${iface}/mtu"
  local mtu

  if [[ ! -r "$mtu_file" ]]; then
    return 1
  fi

  mtu=$(<"$mtu_file")
  if [[ "$mtu" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$mtu"
    return 0
  fi

  return 1
}

format_rate() {
  local value="${1:-0}"
  if [[ "$value" == "0" ]]; then
    printf '无限制'
  else
    printf '%s Mbps' "$value"
  fi
}

format_mtu() {
  local value="${1:-0}"
  if [[ "$value" == "0" ]]; then
    printf '无限制'
  else
    printf '%s' "$value"
  fi
}

# 读取指定网卡的保存配置，并统一输出 5 列：iface up down mtu original_mtu
# 兼容旧版 3 列配置：iface up down
get_saved_limit() {
  local iface="$1"
  ensure_config
  awk -v target="$iface" '
    $0 ~ /^[[:space:]]*$/ || $1 ~ /^#/ { next }
    $1 == target {
      up = ($2 == "" ? "0" : $2)
      down = ($3 == "" ? "0" : $3)
      mtu = ($4 == "" ? "0" : $4)
      original_mtu = ($5 == "" ? "0" : $5)
      print $1, up, down, mtu, original_mtu
      exit
    }
  ' "$CONFIG_FILE" 2>/dev/null || true
}

save_limit_config() {
  local iface="$1"
  local up="$2"
  local down="$3"
  local mtu="${4:-0}"
  local original_mtu="${5:-0}"
  local tmp

  ensure_config
  tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")

  # 用 awk 按第一列精确匹配网卡名，避免 sed 正则误伤 eth0.100 等名字。
  if ! awk -v target="$iface" 'NF == 0 || $1 != target { print }' "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}[错误]${NC} 写入配置前清理旧记录失败：$CONFIG_FILE"
    return 1
  fi

  printf '%s %s %s %s %s\n' "$iface" "$up" "$down" "$mtu" "$original_mtu" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

remove_limit_config() {
  local iface="$1"
  local tmp

  ensure_config
  tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")

  if ! awk -v target="$iface" 'NF == 0 || $1 != target { print }' "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}[错误]${NC} 删除配置记录失败：$CONFIG_FILE"
    return 1
  fi

  mv "$tmp" "$CONFIG_FILE"
}

restore_mtu_if_needed() {
  local iface="$1"
  local saved_mtu="${2:-0}"
  local original_mtu="${3:-0}"
  local current_mtu=""

  if ! validate_mtu_value "$saved_mtu" || ! validate_mtu_value "$original_mtu"; then
    echo -e "${YELLOW}[警告]${NC} ${iface} 的 MTU 配置不合法，跳过自动恢复。"
    return 0
  fi

  if [[ "$saved_mtu" -eq 0 || "$original_mtu" -eq 0 ]]; then
    return 0
  fi

  if ! iface_exists "$iface"; then
    echo -e "${YELLOW}[警告]${NC} 网卡 ${iface} 不存在，无法恢复 MTU 到 ${original_mtu}。"
    return 0
  fi

  current_mtu=$(get_current_mtu "$iface" 2>/dev/null || true)
  if [[ "$current_mtu" == "$original_mtu" ]]; then
    echo -e "${CYAN}[提示]${NC} 网卡 ${iface} 当前 MTU 已是 ${original_mtu}，无需恢复。"
    return 0
  fi

  if ip link set dev "$iface" mtu "$original_mtu"; then
    echo -e "${GREEN}[成功]${NC} 已将网卡 ${iface} 的 MTU 恢复为 ${original_mtu}。"
    return 0
  fi

  echo -e "${RED}[错误]${NC} 网卡 ${iface} MTU 恢复失败，请手动执行：ip link set dev ${iface} mtu ${original_mtu}"
  return 1
}

wait_iface_ready() {
  local iface="$1"
  local attempt

  for attempt in 1 2 3; do
    if iface_exists "$iface"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

apply_limit() {
  local iface="$1"
  local up_mbit="$2"
  local down_mbit="$3"
  local mtu="${4:-0}"
  local original_mtu="${5:-0}"
  local should_save="${6:-1}"
  local ifb_dev="ifb_${iface}"
  local mtu_to_save="$mtu"
  local original_mtu_to_save="$original_mtu"

  if ! iface_exists "$iface"; then
    echo -e "${RED}[错误]${NC} 网卡 ${iface} 不存在，无法应用规则。"
    return 1
  fi

  if ! validate_rate_value "$up_mbit" || ! validate_rate_value "$down_mbit"; then
    echo -e "${RED}[错误]${NC} 上传/下载限速必须是非负整数。"
    return 1
  fi

  if ! validate_mtu_value "$mtu"; then
    echo -e "${RED}[错误]${NC} MTU 必须为 0 或 576-9000 之间的整数。"
    return 1
  fi

  if [[ "$original_mtu_to_save" != "0" ]] && ! validate_mtu_value "$original_mtu_to_save"; then
    echo -e "${YELLOW}[警告]${NC} 原始 MTU 记录不合法，已重置为 0。"
    original_mtu_to_save="0"
  fi

  # 1. 清理旧 tc/ifb 规则。MTU 恢复由 clear_limit 显式处理，避免重建规则时产生副作用。
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

  # 4. MTU 限制。首次启用时记录设置前的原始 MTU，后续修改限制值时不覆盖原始值。
  if [[ "$mtu" -gt 0 ]]; then
    if [[ "$original_mtu_to_save" -eq 0 ]]; then
      if ! original_mtu_to_save=$(get_current_mtu "$iface"); then
        echo -e "${RED}[错误]${NC} 无法读取网卡 ${iface} 当前 MTU，跳过 MTU 限制。"
        mtu_to_save="0"
        original_mtu_to_save="0"
      fi
    fi

    if [[ "$mtu_to_save" -gt 0 ]]; then
      if ip link set dev "$iface" mtu "$mtu"; then
        echo -e "${GREEN}[成功]${NC} 网卡 ${iface} MTU 已设置为 ${mtu}（原始 MTU: ${original_mtu_to_save}）。"
      else
        echo -e "${RED}[错误]${NC} 网卡 ${iface} MTU 设置失败，未保存 MTU 限制。"
        mtu_to_save="0"
        original_mtu_to_save="0"
      fi
    fi
  else
    original_mtu_to_save="0"
  fi

  if [[ "$should_save" == "1" ]]; then
    save_limit_config "$iface" "$up_mbit" "$down_mbit" "$mtu_to_save" "$original_mtu_to_save"
  fi
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
  local saved=""
  local saved_iface=""
  local up="0"
  local down="0"
  local saved_mtu="0"
  local original_mtu="0"

  saved=$(get_saved_limit "$iface")
  if [[ -n "$saved" ]]; then
    read -r saved_iface up down saved_mtu original_mtu <<< "$saved"
  fi

  clear_limit_silent "$iface"
  if ! restore_mtu_if_needed "$iface" "$saved_mtu" "$original_mtu"; then
    echo -e "${YELLOW}[警告]${NC} ${iface} 的限速配置仍会删除，请按上方提示手动确认 MTU。"
  fi
  remove_limit_config "$iface"
  echo -e "${GREEN}[成功]${NC} 已解除网卡 ${iface} 的限速/MTU 配置！"
}

print_status_row() {
  local iface="$1"
  local up="$2"
  local down="$3"
  local mtu="$4"
  local original_mtu="$5"
  local current_mtu="$6"
  local state="$7"

  printf "%-15s %-15s %-15s %-12s %-12s %-12s %-18s\n" \
    "$iface" "$(format_rate "$up")" "$(format_rate "$down")" "$(format_mtu "$mtu")" \
    "$(format_mtu "$original_mtu")" "$current_mtu" "$state"
}

show_all_status() {
  echo -e "${CYAN}=== 当前网卡限速 / MTU 概览 ===${NC}"
  local ifaces
  mapfile -t ifaces < <(list_ifaces)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo "未检测到可用物理网卡。"
  fi

  printf "%-15s %-15s %-15s %-12s %-12s %-12s %-18s\n" "网卡名称" "上传限制" "下载限制" "MTU限制" "原始MTU" "当前MTU" "状态"
  echo "------------------------------------------------------------------------------------------------"

  local iface saved saved_iface up down mtu original_mtu current_mtu state
  declare -A shown=()

  for iface in "${ifaces[@]}"; do
    shown["$iface"]=1
    up="0"
    down="0"
    mtu="0"
    original_mtu="0"
    state="无限制"
    current_mtu=$(get_current_mtu "$iface" 2>/dev/null || printf '未知')

    saved=$(get_saved_limit "$iface")
    if [[ -n "$saved" ]]; then
      read -r saved_iface up down mtu original_mtu <<< "$saved"
      if [[ "$mtu" -gt 0 && "$current_mtu" != "$mtu" ]]; then
        state="MTU已变更"
      elif [[ "$up" -gt 0 || "$down" -gt 0 || "$mtu" -gt 0 ]]; then
        state="已配置"
      fi
    fi

    print_status_row "$iface" "$up" "$down" "$mtu" "$original_mtu" "$current_mtu" "$state"
  done

  # 额外展示配置文件里仍存在、但当前系统未检测到的网卡，方便清理旧配置。
  while read -r iface up down mtu original_mtu _; do
    [[ -z "${iface:-}" || "$iface" == \#* ]] && continue
    mtu="${mtu:-0}"
    original_mtu="${original_mtu:-0}"
    if [[ -z "${shown[$iface]+x}" ]]; then
      print_status_row "$iface" "${up:-0}" "${down:-0}" "$mtu" "$original_mtu" "不存在" "网卡不存在"
    fi
  done < "$CONFIG_FILE"

  echo "------------------------------------------------------------------------------------------------"
}

interactive_set_limit() {
  local ifaces choice idx iface
  mapfile -t ifaces < <(list_ifaces)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo -e "${RED}[错误]${NC} 未检测到可用网卡。"
    return
  fi

  echo -e "${CYAN}请选择要设置限速/MTU的网卡：${NC}"
  for idx in "${!ifaces[@]}"; do
    echo "$((idx+1)). ${ifaces[$idx]}"
  done
  echo "0. 取消并返回"
  read -r -p "请输入序号: " choice

  if [[ "$choice" == "0" ]]; then return; fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
    iface="${ifaces[$((choice-1))]}"

    echo -e "\n您选择了网卡: ${YELLOW}${iface}${NC}"
    echo "提示：上传/下载输入 0 表示不限制；MTU 输入 0 表示不限制或恢复原始 MTU。"

    local saved saved_iface saved_up saved_down saved_mtu original_mtu current_mtu
    local up_rate down_rate mtu_value confirm base_mtu
    saved_up="0"
    saved_down="0"
    saved_mtu="0"
    original_mtu="0"
    current_mtu=$(get_current_mtu "$iface" 2>/dev/null || printf '未知')

    saved=$(get_saved_limit "$iface")
    if [[ -n "$saved" ]]; then
      read -r saved_iface saved_up saved_down saved_mtu original_mtu <<< "$saved"
    fi

    echo "当前 MTU: ${current_mtu}；已保存 MTU 限制: $(format_mtu "$saved_mtu")"

    read -r -p "1. 请输入【上传】限速值 (单位 Mbps): " up_rate
    if ! validate_rate_value "$up_rate"; then echo -e "${RED}错误：必须输入非负整数。${NC}"; return; fi

    read -r -p "2. 请输入【下载】限速值 (单位 Mbps): " down_rate
    if ! validate_rate_value "$down_rate"; then echo -e "${RED}错误：必须输入非负整数。${NC}"; return; fi

    read -r -p "3. 请输入【MTU】限制值 (0 表示不限制/恢复原始 MTU，建议 1280-1500): " mtu_value
    if ! validate_mtu_value "$mtu_value"; then
      echo -e "${RED}错误：MTU 必须为 0 或 576-9000 之间的整数。${NC}"
      return
    fi

    if [[ "$mtu_value" -gt 0 && "$mtu_value" -lt 1280 ]]; then
      read -r -p "警告：MTU 低于 1280 可能影响 IPv6，确认继续？(y/N): " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}[提示]${NC} 已取消本次设置。"
        return
      fi
    fi

    base_mtu="$original_mtu"
    if [[ "$base_mtu" == "0" && "$current_mtu" =~ ^[0-9]+$ ]]; then
      base_mtu="$current_mtu"
    fi
    if [[ "$mtu_value" -gt 0 && "$base_mtu" =~ ^[0-9]+$ && "$base_mtu" -gt 0 && "$mtu_value" -gt "$base_mtu" ]]; then
      read -r -p "警告：输入 MTU 大于当前/原始 MTU (${base_mtu})，这不是降低 MTU，确认继续？(y/N): " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}[提示]${NC} 已取消本次设置。"
        return
      fi
    fi

    if [[ "$up_rate" -eq 0 && "$down_rate" -eq 0 && "$mtu_value" -eq 0 ]]; then
      clear_limit "$iface"
    else
      if [[ "$mtu_value" -eq 0 && "$saved_mtu" -gt 0 ]]; then
        if ! restore_mtu_if_needed "$iface" "$saved_mtu" "$original_mtu"; then
          echo -e "${YELLOW}[警告]${NC} MTU 恢复失败，仍继续保存带宽限速配置。"
        fi
        original_mtu="0"
      fi
      apply_limit "$iface" "$up_rate" "$down_rate" "$mtu_value" "$original_mtu" "1"
      echo -e "${GREEN}[成功]${NC} 网卡 ${iface} 已生效: 上传 ${up_rate}Mbps / 下载 ${down_rate}Mbps / MTU $(format_mtu "$mtu_value")"
    fi
  else
    echo -e "${RED}[错误]${NC} 无效的序号。"
  fi
}

interactive_clear_limit() {
  local ifaces choice idx iface
  mapfile -t ifaces < <(list_ifaces)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    echo -e "${RED}[错误]${NC} 未检测到可用网卡。"
    return
  fi

  echo -e "${CYAN}请选择要解除限速/MTU配置的网卡：${NC}"
  for idx in "${!ifaces[@]}"; do
    echo "$((idx+1)). ${ifaces[$idx]}"
  done
  echo "99. 解除所有网卡的限速/MTU配置"
  echo "0. 取消并返回"
  read -r -p "请输入序号: " choice

  if [[ "$choice" == "0" ]]; then return; fi

  if [[ "$choice" == "99" ]]; then
    for iface in "${ifaces[@]}"; do
      clear_limit "$iface"
    done
    echo -e "${GREEN}[成功]${NC} 所有已检测网卡的限速/MTU配置已解除。"
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

  local line iface up down mtu original_mtu extra
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    read -r iface up down mtu original_mtu extra <<< "$line"
    mtu="${mtu:-0}"
    original_mtu="${original_mtu:-0}"

    if [[ -n "${extra:-}" ]]; then
      echo "[警告] ${iface} 配置存在多余字段，已忽略。"
    fi

    if ! validate_rate_value "${up:-}" || ! validate_rate_value "${down:-}" || ! validate_mtu_value "$mtu"; then
      echo "[警告] 跳过非法配置行：$line"
      continue
    fi

    if wait_iface_ready "$iface"; then
      if apply_limit "$iface" "$up" "$down" "$mtu" "$original_mtu" "0"; then
        echo "已恢复: $iface (上传: ${up}Mbps, 下载: ${down}Mbps, MTU: $(format_mtu "$mtu"))"
      else
        echo "[警告] $iface 规则恢复失败，请手动检查。"
      fi
    else
      echo "[警告] 网卡 $iface 不存在，已跳过。"
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
  echo -e "${GREEN}[成功]${NC} 已部署防重启断网护城河！每次开机会自动恢复您的限速/MTU规则。"
}

uninstall_panel() {
  echo -e "${YELLOW}警告：您即将彻底卸载此限速面板及相关服务。${NC}"

  read -r -p "是否同时【清除当前正在生效的限速规则并恢复 MTU】？(y/n，默认 y 清除): " clear_rules
  if [[ ! "$clear_rules" =~ ^[Nn]$ ]]; then
    local ifaces i line iface up down mtu original_mtu
    mapfile -t ifaces < <(list_ifaces)
    for i in "${ifaces[@]}"; do
      clear_limit_silent "$i"
    done

    if [[ -f "$CONFIG_FILE" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        read -r iface up down mtu original_mtu _ <<< "$line"
        restore_mtu_if_needed "$iface" "${mtu:-0}" "${original_mtu:-0}" || true
      done < "$CONFIG_FILE"
    fi

    echo -e "${GREEN}[成功]${NC} 已清理底层限速阀门，并尝试恢复已保存的 MTU。"
  else
    echo -e "${CYAN}[提示]${NC} 已保留当前限速/MTU规则（tc 规则将在下次重启服务器后失效，MTU 可能继续保持当前值）。"
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

  read -r -p "是否删除历史限速/MTU配置文件 ($CONFIG_FILE)？(y/n，默认 y 删除): " rm_conf
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
  echo -e "${CYAN}      Linux 通用限速 / MTU 面板        ${NC}"
  echo -e "${YELLOW}========================================${NC}"
  echo " 1. 查看所有网卡限速 / MTU 概览"
  echo " 2. 设置/修改网卡限速与 MTU"
  echo " 3. 解除网卡限速 / MTU 配置"
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
