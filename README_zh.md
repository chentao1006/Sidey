# Sidey - 你的智能 macOS 助手

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Sidey Logo">
</p>

[English](README.md) | **简体中文**

---

**Sidey** 是一款专为 macOS 设计的轻量级、场景感知 AI 助手。它能实时理解你正在使用的应用程序，并根据当前环境提供定制化的 AI 建议。

### ✨ 核心功能

- **场景感知**：自动检测当前前台应用，并推荐与之关联的助手指令。
- **自定义助手**：为特定应用创建不同的 AI 角色或任务（例如：为 Xcode 设置“代码审查”，为 Safari 设置“内容总结”）。
- **全局快捷键**：通过可自定义的快捷键，随时随地唤醒你的 AI 助手。
- **智能剪贴板**：唤醒时自动贴入剪贴板内容，并提供“一键撤销”功能以找回原有输入。
- **Markdown 支持**：完美的 Markdown 渲染，让 AI 响应清晰易读。
- **多端同步**：支持通过 iCloud 或自定义同步目录（如 Dropbox、iCloud Drive 文件夹）同步助手指令和设置。
- **应用切换**：在助手中快速切换回最近使用的应用或查看正在运行的程序。

![Sidey 截图](Resources/Screenshot.jpg)

### 🚀 快速上手

#### 系统要求
- macOS 13.0 或更高版本。
- OpenAI 或其兼容服务的 API Key。

#### 安装步骤
1. 下载最新发行版，或使用内置的 `build_app.sh` 脚本进行编译。
2. 将 **Sidey.app** 移动到 `/Applications`（应用程序）文件夹。
3. 启动应用，前往 **设置 > API** 输入你的 API 密钥和接口地址 (Base URL)。

#### 源码编译
```bash
git clone https://github.com/chentao1006/sidey.git
cd sidey
./build_app.sh
```

---

### 📄 许可证

本项目采用 MIT 许可证 - 详情请参阅 [LICENSE](LICENSE) 文件。

---

<p align="center">
为 macOS 资深用户精心打造 ❤️
</p>
