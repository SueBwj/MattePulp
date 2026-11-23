# 柔纸

**中文** | [English](README.en.md)

<p align="center">
  <img src="assets/app-icon.png" width="128" alt="柔纸图标：深蓝底上两张交叠的半透明纸">
</p>

**柔纸在屏幕上铺一层生成的纸纹，让发亮的显示看起来像一张哑光纸。**

英文产品名是 MattePulp。仓库、Windows 可执行文件和 Mac 应用包仍叫 sue-paper，已有的下载地址、设置目录和纹理编号都不变。Windows 版是免安装的托盘程序。Mac 版是 Apple Silicon 上的原生菜单栏程序。两边共用同一套纹理算法。

<p align="center">
  <img src="assets/showcase1.png" width="32%" alt="阅读页面上的纸纹。页面文字是第三方作品。">
  <img src="assets/showcase2.png" width="32%" alt="同一阅读页面，其中一段被高亮。这些文字不属于柔纸。">
  <img src="assets/showcase3.png" width="32%" alt="阅读视图的后一页，纸纹仍盖在页面上。">
</p>

图里的正文是第三方作品。柔纸只加上纸纹，不主张这些文字或阅读应用的权利。

## 下载

先下载已发布的安装包。下面的源码功能还没有打进这些安装包。

| 系统 | 版本 | 文件 |
|---|---|---|
| Windows x64 | [v0.1.0](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.0) 稳定版 | [sue-paper-v0.1.0-windows-x64.zip](https://github.com/SueBwj/sue-paper/releases/download/v0.1.0/sue-paper-v0.1.0-windows-x64.zip) |
| Mac Apple Silicon | [v0.1.1-macos.1](https://github.com/SueBwj/sue-paper/releases/tag/v0.1.1-macos.1) 预发布 | [Sue-Paper-macOS-arm64-local-d9fb2c7.dmg](https://github.com/SueBwj/sue-paper/releases/download/v0.1.1-macos.1/Sue-Paper-macOS-arm64-local-d9fb2c7.dmg) |

Windows v0.1.0 对应提交 `53b266a`。那个包里的程序名叫 Sue-Paper，托盘图标来自当时的 `assets/logo-s-64.bgra`，没有语言菜单，也没有现在这张半透明纸图标。

Mac 预发布对应提交 `d9fb2c7`，只含 Apple Silicon。磁盘镜像里已经是这张半透明纸图标。菜单仍把中文和英文写在同一项上，没有单独的语言选择，也没有公证。Gatekeeper 可能拦住从网络下载的副本。

当前源码里的 Windows 托盘会显示柔纸或 MattePulp，并提供语言菜单。这套界面还没有新的 Windows 安装包。Mac 源码菜单仍与上述预发布相同。

## 使用

纸纹盖住每块屏幕，鼠标和键盘直接穿过，不拿焦点，也不出现在窗口切换里。Mac 的显示范围见 [Mac 说明](macos/README.md#display-behavior)。

四种纹理由分形噪声生成，可以无缝平铺。Windows 强度仍是 15%、20%、25%、30% 四档。设置里的纹理编号不变。

| 设置编号 | 英文菜单 | 中文菜单 | 观感 |
|---|---|---|---|
| ClassicMatte | Classic Matte | 经典哑光 | 干净、柔和，适合阅读 |
| WhisperWeave | Whisper Weave | 织物纹理 | 细密织纹，压住刺眼的亮色 |
| Parchment | Sunbaked Parchment | 羊皮纸 | 暖色，颗粒更重 |
| VellumMist | Vellum Mist | 薄纱雾面 | 很轻的一层雾 |

![四种纹理盖在同一组横线上](showcase/textures.png)

**Windows。** 解压稳定包后运行 `sue-paper.exe`。从这棵源码编译时，右键托盘图标。菜单每次打开都按同一种语言重建：

- 启用纸张纹理
- 纹理、强度、打盹（暂停 5 分钟或 15 分钟）
- 排除当前应用。排除项是前台进程的文件名，例如 `photos.exe`
- 语言：中文或 English
- 退出

托盘提示和隐藏窗口标题在中文下是「柔纸」，在英文下是 MattePulp。选择语言后提示立即更换，下一次打开的菜单整份换成该语言。语言名本身保持「中文」和 English，方便从另一份菜单里找回来。

没有 `language` 字段的旧设置仍可打开。这时跟随 Windows 界面语言：`zh-Hans`、`zh-CN`、`zh-SG`、`zh-CHS` 用简体中文，繁体中文和其他语言用英文。选定后写入 `language`，值为 `zh-Hans` 或 `en`，下次启动继续用它。设置文件仍在 `%APPDATA%\Sue-Paper\settings.json`。

**Mac。** 打开预发布磁盘镜像或自行构建的 `Sue-Paper.app`，点菜单栏上的 **S**。当前菜单把两种语言写在一起，例如「启用 Enabled」「打盹 5 分钟 / Snooze 5 minutes」「退出 Quit Sue-Paper」。强度同样是四档。打盹中会多出「恢复 Resume now」。排除项使用 bundle identifier，没有标识时用可执行文件 URL。不需要辅助功能或屏幕录制权限。设置仍在 `~/Library/Application Support/Sue-Paper/settings.json`。

## 兼容性

- Windows 已发布包是 64 位。旧的 `settings.json` 没有语言字段也能加载。强度档位没有改。
- Mac 已发布包是 Apple Silicon，系统要求 macOS 12 或更新版本。v0.1.1-macos.1 只做了 ad-hoc 签名，没有公证。
- 包标识仍是 `com.suebwj.sue-paper`。Mac 可执行文件名仍是 `Sue-Paper`。Windows 可执行文件名仍是 `sue-paper.exe`。
- 运行时大约占用 22–27 MB 内存。纹理静止时不再耗 CPU，只有切换时重画。多显示器在显示变化时重建覆盖层。这是既有 Windows 程序的占用情况。

## 构建与测试

### Windows

需要 Rust stable（`stable-x86_64-pc-windows-gnu` 或 MSVC）：

```sh
./build-release.ps1
```

脚本生成 `target/release/sue-paper.exe`，把 `assets/sue-paper.ico` 写进可执行文件的图标资源，并把仓库根目录的 `LICENSE` 复制到可执行文件旁边。分发时请带上这个 `LICENSE`，不要把整个 `target\release` 目录打进去。托盘像素来自编译期内嵌的 `assets/app-icon-64.bgra`。这三份图标都是当前的半透明纸图，不是 v0.1.0 里的旧图标。

Windows 上的格式、静态检查和测试：

```sh
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

`windows` crate 固定为 0.58，使用 `windows-targets` 里预编译的导入库。0.60 及以后改为构建时用 `windows-link` 调用 dlltool，GNU 工具链还要额外配置 PATH，因此没有升级。

### macOS（Apple Silicon）

需要 macOS 12 或更新版本、Rust stable，以及 Xcode 16 或更新版本，并且 `xcrun` 能找到 Swift 6 和 `swift-format`：

```sh
./build-macos.sh /tmp/sue-paper-build
./test-macos.sh /tmp/sue-paper-build
open /tmp/sue-paper-build/Sue-Paper.app
```

每次构建使用新的输出目录。产物是 `Sue-Paper.app` 和 `sue-paper-macos-arm64.zip`。脚本把 `LICENSE` 放进 `Contents/Resources`，再做 ad-hoc 签名。运行应用不需要 Rust。从 **S** 菜单退出。测试只用临时设置和合成窗口，会短暂进入全屏并自动关掉，不截取桌面。已验证的环境和显示器、Spaces 的边界见 [Mac 构建与验证说明](macos/README.md)。

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
