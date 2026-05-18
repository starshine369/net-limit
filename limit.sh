# 🚀 Linux 通用双向网络限速面板 (Net-Limit)

![Debian](https://img.shields.io/badge/Debian-Supported-A81D33?logo=debian)
![Ubuntu](https://img.shields.io/badge/Ubuntu-Supported-E95420?logo=ubuntu)
![CentOS](https://img.shields.io/badge/CentOS-Supported-262577?logo=centos)
![Arch](https://img.shields.io/badge/Arch-Supported-1793D1?logo=arch-linux)
![Bash](https://img.shields.io/badge/Language-Bash-green?logo=gnu-bash)

这是一个专为现代 Linux 服务器环境设计的**全交互式网络限速脚本**。完全摒弃了传统的单向限速和粗糙队列，采用现代化的 `HTB` + `FQ` + `IFB` 架构，在精准控制带宽的同时，**完美兼容 BBR 拥塞控制算法**，防 QoS 的同时拒绝断流。

**跨平台兼容：** 只要您的系统基于现代 Linux 内核并使用 `systemd`（涵盖 Debian, Ubuntu, CentOS, RHEL, AlmaLinux, Arch 等），均可完美运行。

---

## ✨ 核心特性

- **🚦 完美双向限速**：支持同时或分别限制 **上传 (Egress)** 和 **下载 (Ingress)** 带宽。
- **🌐 多网卡独立管控**：拥有多个网卡？面板可自动识别并支持为每张网卡配置不同的速率规则。
- **⚡ 无损 BBR 兼容**：底层采用 `HTB` 令牌桶叠加 `FQ` (Fair Queueing) 队列，限速绝不拖垮 TCP BBR 的发包效率，专为跨国网络优化。
- **💾 开机自动恢复**：内置 Systemd 守护进程注册功能，重启服务器后配置自动生效。
- **🗑️ 优雅卸载向导**：提供完整的卸载流程，自由选择是否保留当前规则和配置文件，保证系统纯净无残留。

---

## 🛠️ 安装与运行

本脚本仅需要 `root` 权限，不依赖任何第三方臃肿环境（底层完全依赖 Linux 原生 `iproute2` 和 `tc`）。

```bash
# 1. 下载脚本
wget -O limit.sh [https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh](https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh)

# 2. 赋予执行权限
chmod +x limit.sh

# 3. 运行面板 (必须使用 root 权限)
sudo ./limit.sh