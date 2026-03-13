# Sidey - Your Intelligent macOS Sidekick

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Sidey Logo">
</p>

**English** | [简体中文](README_zh.md)

---

**Sidey** is a lightweight, context-aware AI assistant designed specifically for macOS. It stays by your side, understanding which application you are currently using and providing tailored AI assistance through customizable prompts.

### ✨ Key Features

- **Context Awareness**: Automatically detects the frontmost application and suggests relevant prompts.
- **Customizable Prompts**: Create and manage different AI personas or tasks for specific apps (e.g., "Code Review" for Xcode, "Summarize" for Safari).
- **Global Hotkey**: Summon your assistant instantly from anywhere with a customizable keyboard shortcut.
- **Smart Clipboard**: Automatically paste clipboard content when activated, with a one-click "Undo" to restore your previous input.
- **Markdown Support**: Beautifully rendered AI responses with full Markdown support.
- **iCloud & File Sync**: Keep your prompts and settings synced across devices via iCloud or a custom sync folder (Dropbox, iCloud Drive, etc.).
- **App Switcher**: Quickly switch back to your recently used applications or explore running apps directly from the assistant.

![Sidey Screenshot](Resources/Screenshot-en.jpg)

### 🚀 Getting Started

#### Prerequisites
- macOS 13.0 or later.
- An OpenAI-compatible API Key.

#### Installation
1. Download the latest release or build from source using the provided `build_app.sh` script.
2. Move **Sidey.app** to your `/Applications` folder.
3. Launch the app and go to **Settings > API** to enter your API Key and Base URL.

#### Building from Source
```bash
git clone https://github.com/chentao1006/sidey.git
cd sidey
./build_app.sh
```

---

### 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">
Made with ❤️ for macOS power users.
</p>
