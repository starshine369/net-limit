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

本脚本完全依赖 Linux 原生环境，无需安装任何第三方臃肿依赖。我们提供了一键极速安装命令：

使用 root 权限运行一键安装/启动脚本
```bash
bash <(curl -sL https://raw.githubusercontent.com/starshine369/net-limit/main/limit.sh)
```


> **💡 终极便捷提示**：第一次通过一键命令运行后，脚本会自动将自身注册到系统中。以后您在任何目录下，直接在终端输入唯一的快捷命令 **`net-limit`**，即可瞬间呼出限速管理面板！

---

## 🕹️ 面板使用指南

运行脚本后，您将看到一个直观的中文交互界面：

```shell
========================================
        Linux 通用双向限速面板          
========================================
 1. 查看所有网卡限速概览
 2. 设置/修改网卡限速 (自定义速率)
 3. 解除网卡限速
 ---------------------------------------
 4. 安装/更新 开机自动恢复服务
 5. 彻底卸载面板及服务
 0. 退出面板
========================================
```

### 💡 核心操作流程：
1. **第一次设置**：选择菜单 `2` -> 选定要限速的物理网卡 -> 分别输入上传和下载速度（输入 0 代表不限制）。
2. **设置开机自启**：配置完成后，务必执行菜单 `4`。这会在系统内生成一个后台服务，保证您服务器重启后，限速阀门依然紧闭，防止流量跑满被机房 QoS。
3. **解除与卸载**：随时可以选择 `3` 一键恢复网卡满速状态，或选择 `5` 彻底清理脚本产生的所有痕迹。

---

## ❓ 原理浅析：它是如何限制下载速度的？

原生 Linux `tc` (Traffic Control) 工具只能对**发出 (Egress)** 的数据包进行排队（因为一旦收到数据，就已经占用物理带宽了）。
本脚本通过智能加载内核的 `ifb`（Intermediate Functional Block）虚拟网卡模块，将物理网卡的**入站 (Ingress)** 流量无缝重定向到虚拟网卡上进行处理，从而实现了极其精准的下载队列整形。

---

## 📜 许可证

本项目基于 [MIT License](LICENSE) 开源，欢迎提交 Issue 和 Pull Request，一起完善这款网络工具！
