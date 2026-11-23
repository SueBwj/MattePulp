# MattePulp

**中文** | [English](README.en.md)

<p align="center">
  <img src="assets/app-icon.png" width="128" alt="MattePulp 图标：深蓝底上两张交叠的半透明纸">
</p>

**MattePulp（柔纸）在屏幕上铺一层生成的纸纹，让发亮的显示看起来像一张哑光纸。**

<p align="center">
  <img src="assets/showcase1.png" width="32%" alt="纸纹盖在阅读页面上">
  <img src="assets/showcase2.png" width="32%" alt="同一阅读页面上有一段高亮选区，纸纹不变">
  <img src="assets/showcase3.png" width="32%" alt="阅读视图翻到后一页，纸纹仍覆盖整屏">
</p>

## 下载

先下载已发布的安装包。当前源码里的双语菜单还没有打进这些安装包。

| 系统 | 版本 | 文件 |
|---|---|---|
| Windows x64 | [v0.1.0](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.0) 稳定版 | [sue-paper-v0.1.0-windows-x64.zip](https://github.com/SueBwj/sue-paper/releases/download/v0.1.0/sue-paper-v0.1.0-windows-x64.zip) |
| Mac Apple Silicon | [v0.1.1-macos.1](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.1-macos.1) 预发布 | [Sue-Paper-macOS-arm64-local-d9fb2c7.dmg](https://github.com/SueBwj/sue-paper/releases/download/v0.1.1-macos.1/Sue-Paper-macOS-arm64-local-d9fb2c7.dmg) |

Windows v0.1.0（`53b266a`）仍是旧托盘图标和单一界面，没有语言菜单。Mac 预发布（`d9fb2c7`，仅 Apple Silicon）已用当前半透明纸图标，但菜单仍是中英混排、无单独语言项；镜像只做 ad-hoc 签名、未公证，从网络下载时 Gatekeeper 可能拦截。旧版 `settings.json` 没有 `language` 字段也能继续用。

## 使用

纸纹盖住每块屏幕，鼠标和键盘直接穿过，不拿焦点，也不出现在窗口切换里。Mac 的显示范围见 [Mac 说明](macos/README.md#display-behavior)。

四种纹理由分形噪声生成，可无缝平铺；强度与纹理编号与已发布包一致（见下表）。

| 设置编号 | 英文菜单 | 中文菜单 | 观感 |
|---|---|---|---|
| ClassicMatte | Classic Matte | 经典哑光 | 干净、柔和，适合阅读 |
| WhisperWeave | Whisper Weave | 织物纹理 | 细密织纹，压住刺眼的亮色 |
| Parchment | Sunbaked Parchment | 羊皮纸 | 暖色，颗粒更重 |
| VellumMist | Vellum Mist | 薄纱雾面 | 很轻的一层雾 |

![四种纹理盖在同一组横线上](showcase/textures.png)

**Windows。** 解压稳定包后运行 `sue-paper.exe`。从源码运行时右键托盘图标：启用纹理、纹理/强度/打盹、排除当前应用、语言（中文或 English）、退出。托盘提示在中文下是「柔纸」，英文下是 MattePulp。设置文件在 `%APPDATA%\Sue-Paper\settings.json`。

**Mac。** 已发布镜像仍是混排菜单。从源码构建 `Sue-Paper.app` 后点菜单栏 **S**：整份菜单只用一种语言，并可单独选语言。Finder 显示名是 MattePulp，可执行文件仍是 `Sue-Paper`；设置在 `~/Library/Application Support/Sue-Paper/settings.json`。不需要辅助功能或屏幕录制权限。

未保存语言时，菜单跟随系统界面语言；选定后写入 `language`（`zh-Hans` 或 `en`），Windows 与 Mac 规则相同。

## 构建与测试

### Windows

需要 Rust stable（`stable-x86_64-pc-windows-gnu` 或 MSVC）：

```sh
./build-release.ps1
```

脚本生成 `target/release/sue-paper.exe`，嵌入 `assets/sue-paper.ico`，并把根目录 `LICENSE` 复制到可执行文件旁。分发时请只带上 `sue-paper.exe` 与同目录 `LICENSE`，不要打包整个 `target\release`。

```sh
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

### macOS（Apple Silicon）

需要 macOS 12+、Rust stable、Xcode 16+（`xcrun` 能找到 Swift 6 与 `swift-format`）：

```sh
./build-macos.sh /tmp/mattepulp-build
./test-macos.sh /tmp/mattepulp-build
open /tmp/mattepulp-build/Sue-Paper.app
```

每次构建使用新的输出目录。产物为 `Sue-Paper.app` 与 `sue-paper-macos-arm64.zip`；`LICENSE` 在 `Contents/Resources`，构建为 ad-hoc 签名。测试用临时设置与合成窗口，不截取桌面。细节见 [Mac 构建与验证说明](macos/README.md)。

| 文件 | 职责 |
|---|---|
| `src/main.rs` | 入口、隐藏控制窗口、消息循环、菜单命令 |
| `src/locale.rs` | 简体中文和英文菜单，以及系统语言判断 |
| `src/overlay.rs` | 每屏一个分层窗口，并用 `UpdateLayeredWindow` 上屏 |
| `src/texture.rs` | 分形噪声和四种纹理 |
| `src/tray.rs` | 托盘图标和右键菜单 |
| `src/settings.rs` | `%APPDATA%/Sue-Paper/settings.json` |
| `assets/app-icon.png` | 图标原图 |
| `assets/app-icon-64.bgra` | 编进托盘图标的像素 |
| `assets/sue-paper.ico` | 写进 Windows 可执行文件的多尺寸图标 |
| `macos/` | AppKit 菜单栏、覆盖层、设置和测试 |

## 反馈

问题请开到 [GitHub Issues](https://github.com/SueBwj/sue-paper/issues)。源码仓库是 [SueBwj/sue-paper](https://github.com/SueBwj/sue-paper)。

## 致谢

- 数字哑光表面这个想法来自 [Paperman](https://paperman.cc)。
- 程序由 SueBwj 与编程助手一起写成。

## 许可

仓库里的源码和文档使用 MIT 许可，版权行为 `Copyright (c) 2026 SueBwj`。全文见 [LICENSE](LICENSE)。

这次许可不覆盖截图、应用图标、产品标识和其他媒体，也不改变第三方依赖自带的许可。`windows`、`serde` 和 `serde_json` 仍使用它们各自发布的许可。

再分发程序时，请保留上述版权声明和许可声明。Windows 构建脚本把 `LICENSE` 放在 `sue-paper.exe` 旁边。Mac 构建脚本把它放进应用包的 `Contents/Resources`。
