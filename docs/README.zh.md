# Turbo Optimizer：免费的 Windows 10/11 优化、清理与修复工具

[English](../README.md) | [العربية](README.ar.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt.md) | [Русский](README.ru.md) | **简体中文** | [हिन्दी](README.hi.md) | [Türkçe](README.tr.md)

用 PowerShell 编写的开源工具，用于**优化、清理和修复 Windows**。它会扫描你的电脑，说明问题，并且只修复你选择的项目：开机慢、C 盘已满、Windows 更新错误、缺少 DLL 文件、驱动问题、Wi-Fi 和蓝牙经常断开。每一项更改都会被记录，可以**撤销**。

无需安装，无广告，无遥测。在 PowerShell 中粘贴一行：它会下载工具，在浏览器的现代窗口中打开，并询问你想做什么。

![医生结果](ui-doctor-ar.png)

## 功能

- **医生：** 扫描更新、驱动、DLL、磁盘健康、安全设置和事件日志，并修复你选择的项目。
- **电脑清理：** 临时文件、更新缓存和浏览器缓存、空间分析、SSD 的 TRIM、移除预装应用。
- **加速 Windows：** 高性能电源计划、启动项管理、可选服务。
- **更新与修复：** 通过 winget 更新应用、SFC 和 DISM、驱动备份与还原。
- **网络：** Wi-Fi 和蓝牙修复、DNS 测速、hosts 文件和 Wi-Fi 信道检查。
- **安全：** 防火墙、SMBv1、远程桌面、UAC，以及可撤销的 Defender 开关。
- **安全第一：** 试运行模式、还原点、撤销日志。

## 常见问题

- **Windows 10 蓝牙已连接但没有声音：** 蓝牙无声修复。
- **Wi-Fi 断线或卡住：** Wi-Fi 快速重置，停止省电。
- **C 盘已满、电脑变慢：** 清理文件、释放空间、启动程序。
- **Windows 更新卡住**或**缺少 DLL**（d3dx9 等）：由“医生”修复。
- **移除预装软件（bloatware）**，并可撤销地关闭或开启 Windows Defender。

## 快速开始

```powershell
irm https://raw.githubusercontent.com/Ebnhussein/TurboOpt/main/install.ps1 | iex
```

打开 PowerShell 并粘贴这一行。它会下载工具，在浏览器中打开，并询问你想做什么（包括自动维护：每周清理或每日监控）。先试试**试运行**。
