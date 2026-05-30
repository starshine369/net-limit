# 🚀 Linux 通用双向网络限速 / MTU 面板 (Net-Limit)

![Debian](https://img.shields.io/badge/Debian-Supported-A81D33?logo=debian)
![Ubuntu](https://img.shields.io/badge/Ubuntu-Supported-E95420?logo=ubuntu)
![CentOS](https://img.shields.io/badge/CentOS-Supported-262577?logo=centos)
![Arch](https://img.shields.io/badge/Arch-Supported-1793D1?logo=arch-linux)
![Bash](https://img.shields.io/badge/Language-Bash-green?logo=gnu-bash)

这是一个专为现代 Linux 服务器环境设计的**全交互式网络限速与 MTU 管控脚本**。带宽控制采用现代化的 `HTB` + `FQ` + `IFB` 架构，在精准控制上传/下载带宽的同时，**兼容 BBR 拥塞控制算法**；MTU 管控则直接按网卡保存和恢复配置，适合 VPN、隧道、PPPoE、跨境链路等需要降低 MTU 的场景。

**跨平台兼容：** 只要您的系统基于现代 Linux 内核并使用 `systemd`（涵盖 Debian, Ubuntu, CentOS, RHEL, AlmaLinux, Arch 等），均可运行。

---

## ✨ 核心特性

- **🚦 完美双向限速**：支持同时或分别限制 **上传 (Egress)** 和 **下载 (Ingress)** 带宽。
- **📏 MTU 独立限制**：支持为指定网卡设置 MTU，并记录原始 MTU，解除限制或卸载时自动尝试恢复。
- **🌐 多网卡独立管控**：拥有多个网卡？面板可自动识别并支持为每张网卡配置不同的速率和 MTU 规则。
- **⚡ 无损 BBR 兼容**：底层采用 `HTB` 令牌桶叠加 `FQ` (Fair Queueing) 队列，限速绝不拖垮 TCP BBR 的发包效率，专为跨国网络优化。
- **💾 开机自动恢复**：内置 Systemd 守护进程注册功能，重启服务器后自动恢复带宽限速和 MTU 配置。
- **🗑️ 优雅卸载向导**：提供完整的卸载流程，可选择是否清除当前规则、恢复 MTU、删除配置文件，保证系统纯净无残留。

---

## 🛠️ 安装与运行

本脚本完全依赖 Linux 原生环境，无需安装任何第三方臃肿依赖。我们提供了一键极速安装命令：

使用 root 权限运行一键安装/启动脚本：

```bash
bash <(curl -sL https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh)
```

国内运行：

```bash
wget -O limit.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh && bash limit.sh
```

> **💡 终极便捷提示**：第一次通过一键命令运行后，脚本会自动将自身注册到系统中。以后您在任何目录下，直接在终端输入唯一的快捷命令 **`net-limit`**，即可瞬间呼出管理面板！

---

## 🕹️ 面板使用指南

运行脚本后，您将看到一个直观的中文交互界面：

```shell
========================================
      Linux 通用限速 / MTU 面板
========================================
 1. 查看所有网卡限速 / MTU 概览
 2. 设置/修改网卡限速与 MTU
 3. 解除网卡限速 / MTU 配置
 ---------------------------------------
 4. 开启/更新 开机自动恢复配置
 5. 彻底卸载面板及服务
 0. 退出面板
========================================
```

### 💡 核心操作流程

1. **第一次设置**：选择菜单 `2` -> 选定要管理的物理网卡 -> 分别输入上传、下载速度和 MTU。
2. **带宽输入规则**：上传/下载输入 `0` 代表该方向不限制。
3. **MTU 输入规则**：MTU 输入 `0` 代表不限制 MTU；如果之前设置过 MTU，会尝试恢复到首次设置前记录的原始 MTU。
4. **设置开机自启**：配置完成后，执行菜单 `4`。这会在系统内生成一个后台服务，保证服务器重启后，带宽限速和 MTU 配置自动恢复。
5. **解除与卸载**：选择 `3` 可解除指定网卡规则并尝试恢复原始 MTU；选择 `5` 可彻底清理脚本产生的服务、命令和配置。

### 📏 常见 MTU 参考值

- `1500`：普通以太网默认值。
- `1492`：PPPoE 常见值。
- `1420`：部分 WireGuard / VPN / 隧道场景常见值。
- `1280`：IPv6 要求的最小链路 MTU。

> **风险提示**：MTU 设置过低可能导致 IPv6、VPN、容器网络或部分网站访问异常。脚本允许 `576-9000` 的 MTU；低于 `1280` 时会额外提示确认。

---

## ⚙️ 配置文件格式

配置文件路径：

```text
/etc/network-limit.conf
```

旧版 3 列格式仍然兼容：

```text
iface up down
```

新版保存为 5 列：

```text
iface up down mtu original_mtu
```

示例：

```text
eth0 100 200 1400 1500
```

含义：

- `eth0`：网卡名。
- `100`：上传限制 100 Mbps，`0` 表示不限制。
- `200`：下载限制 200 Mbps，`0` 表示不限制。
- `1400`：MTU 限制为 1400，`0` 表示不限制。
- `1500`：首次设置 MTU 前记录的原始 MTU，用于恢复。

不建议手动修改 `original_mtu`，否则解除限制或卸载时可能恢复到错误值。

---

## ❓ 原理浅析：它是如何限制下载速度的？

原生 Linux `tc` (Traffic Control) 工具只能对**发出 (Egress)** 的数据包进行排队（因为一旦收到数据，就已经占用物理带宽了）。
本脚本通过智能加载内核的 `ifb`（Intermediate Functional Block）虚拟网卡模块，将物理网卡的**入站 (Ingress)** 流量无缝重定向到虚拟网卡上进行处理，从而实现了极其精准的下载队列整形。

## ❓ MTU 限制是如何工作的？

MTU 是网卡链路层一次能承载的最大包大小，和 `tc` 带宽整形不是同一层能力。本脚本通过：

```bash
ip link set dev <网卡名> mtu <MTU值>
```

直接调整指定网卡的 MTU，并在配置文件中记录首次设置前的原始 MTU。后续解除规则或卸载时，会优先尝试恢复原始 MTU，避免脚本卸载后遗留链路参数。

---

## 📜 许可证

本项目基于 [MIT License](LICENSE) 开源，欢迎提交 Issue 和 Pull Request，一起完善这款网络工具！
