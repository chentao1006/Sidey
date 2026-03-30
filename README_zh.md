# 旁白 - 你的智能 macOS 助手

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Sidey Logo">
</p>

[English](README.md) | **简体中文**

---

**旁白** 是一款专为 macOS 设计的轻量级、场景感知 AI 助手。它能实时理解你正在使用的应用程序，并根据当前环境提供定制化的 AI 建议。

[![App Store 下载](https://developer.apple.com/app-store/marketing/guidelines/images/badge-download-on-the-mac-app-store.svg)](https://apps.apple.com/app/sidey/id6760834274)

[![下载最新安装包](https://img.shields.io/badge/下载最新安装包-Latest%20Release-blue?style=for-the-badge&logo=apple)](https://github.com/chentao1006/Sidey/releases/latest)

### ✨ 核心功能

- **场景感知**：自动检测当前前台应用（包括应用名称、图标及 Bundle ID），为您智能推荐最相关的助手指令。
- **深度上下文抓取**：采用多维度文本捕获系统，确保精准获取有效内容：
  - **辅助功能检索**：直接访问应用程序 UI 树，秒级提取当前焦点元素的选中文本。
  - **专属应用优化**：针对 Safari、Finder 等应用通过 AppleScript 进行深度内容读取。
  - **智能剪贴板回退**：对非标准应用提供模拟 Command+C 捕获，并自动恢复原有剪贴板，全程无感、稳定。
- **视觉文字识别 (OCR)**：内置 Vision 视觉引擎，可自动扫描当前应用窗口或全屏画面，提取图片、PDF 或特殊 UI 片段中原本“无法选中”的文字作为 AI 上下文。
- **上下文延续**：在切换不同助手指令或应用时，自动保留已有的屏幕上下文和附件，助你保持思维连贯。
- **自定义助手**：为特定应用创建不同的 AI 角色或任务（例如：为 Xcode 设置“代码审查”，为 Safari 设置“内容总结”）。
- **自动生成助手**：AI 会根据您当前正在使用的应用，通过“严肃型”或“活泼型”两种风格，为您自动设计最贴切的专属助手角色。
- **公共 AI 服务**：内置公共 AI 服务，无需 API Key 即可立即开始使用。
- **全局快捷键**：通过可自定义的快捷键，随时随地唤醒你的 AI 助手。
- **Markdown 支持**：完美的 Markdown 渲染，让 AI 响应清晰易读。
- **iCloud 同步**：通过 Apple ID 在您的多台 Mac 设备之间自动同步助手指令和个性化设置。
- **体验优化**：精读附件全文、优化输入框比例，为 macOS 用户带来更极致的使用体验。
- **应用切换**：在助手中快速切换回最近使用的应用。

![Sidey 截图](Resources/Screenshot.jpg)

### 🚀 快速上手

#### 系统要求
- macOS 13.0 或更高版本。
- OpenAI 或其兼容服务的 API Key（可选 —— 内置公共服务可供即时使用）。

#### 安装步骤
1. 下载最新发行版，或使用内置的 `build_app.sh` 脚本进行编译。
2. 将 **旁白** (Sidey.app) 移动到 `/Applications`（应用程序）文件夹。
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
