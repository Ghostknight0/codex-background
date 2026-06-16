# Codex 背景注入工具

> 🪟 仅支持 **Windows 10 1607+ / Win11** | 需要 PowerShell 7 + [Codex++](https://github.com/BigPizzaV3/CodexPlusPlus) + OpenAI Codex 桌面版

给 [OpenAI Codex](https://openai.com/codex/) 桌面应用注入自定义背景：支持**图片和视频**、目录随机、图片视频 1:1 混合轮换、运行时定时换背景、图片/视频分别设透明度。

本工具**通过 Codex++ 启动 Codex**（获得 Codex++ 的全部增强功能），并额外注入一个背景覆盖层。与 Codex++ 协作共存。

---

## 🚀 快速开始

​```powershell
# 0. 前置：已安装 Codex 桌面版 与 Codex++（本工具走 Codex++ 的 launcher 启动 Codex）
#       并在 Codex++ 设置里关闭「背景图覆盖」（避免双层背景叠加）

# 1. 克隆或下载本仓库到固定位置（不要解压后又移动）
cd D:\zbg\codex-background   # 或你放置的目录

# 2. 用 PowerShell 7 一行安装（自动探测 Codex++，用包内示例素材）
pwsh -ExecutionPolicy Bypass -File .\install-codex-background-shortcut.ps1

# 3. 双击桌面的「Codex Background」快捷方式启动
​```

就这三步。工具会自动找到 Codex++，用 Codex++ 启动 Codex（开启 CDP 调试端口），再用 `assets\` 里的示例图片视频做 `random` 模式混合随机，每 60 分钟换一个。

> ⚠️ 如果 Codex 已经在跑且 CDP 端口 9229 已开，则直接注入（不重启 Codex），不打断会话。

---

## 工作原理

Codex 桌面应用本身不开放背景配置，也不自带 CDP 调试端口。本工具依赖 **Codex++** 提供的启动入口：

1. **启动**：通过 `codex-plus-plus.exe`（Codex++ launcher）激活 Codex。Codex++ 在激活时会附加 `--remote-debugging-port=9229`，开启 Chrome DevTools Protocol。
2. **注入**：工具连上 `http://127.0.0.1:9229`，通过 CDP 向 Codex 主窗口页面注入一段 JS，创建一个全屏 `<img>`/`<video>` 覆盖层作为背景。
3. **媒体传输**（绕开 CSP 的关键）：Codex 页面有严格的 Content-Security-Policy（禁止 `http://127.0.0.1`，也禁止 `fetch(data:)`），但允许 `data:` 和 `blob:` 作为媒体源。因此：
   - **图片**：文件读成 base64 **dataURL**，直接作为 `<img src>`（CSP 放行 `data:`）。
   - **视频**：base64 → 页面内 `atob` 解码成二进制 → `Blob` → `URL.createObjectURL` 生成 `blob:` URL → 作为 `<video src>`（CSP 放行 `blob:`）。全程不经网络层，绕开 `connect-src` 限制。
   - **大文件分块**：文件超过 3MB 时，base64 切成 512KB 的块，经多次 CDP 推送到页面缓冲区拼接（`begin/append*/finalize`），避免单次 WebSocket payload 过大卡死通道。这样几十 MB 甚至上百 MB 的视频也能流畅传输。
4. **轮换**：PowerShell 端定时随机选新媒体，转 base64 后通过 CDP 推送（小文件一次性、大文件分块），调用页面里的 `window.__codexBgRotator` 更换背景。
5. **生命周期**：工具进程常驻，等 Codex 退出后自动结束，不留孤儿进程。

> 💡 视频较大时，分块传输 + atob 解码 + 视频初始化需要数秒到十几秒（取决于文件大小），期间背景可能短暂空白，属正常现象。

---

## 三种背景模式

| 模式 | 说明 |
|---|---|
| `random` ⭐ 默认 | 从目录随机抽，**图片视频 1:1 混合**（无论数量比例，各 50% 概率） |
| `image` | 固定一张图片或单个视频 |
| `video` | 从目录随机抽视频 |

## 用自己的媒体库

​```powershell
pwsh -ExecutionPolicy Bypass -File .\install-codex-background-shortcut.ps1 `
    -MediaDirectory "E:\你的壁纸库"
​```

图片视频可混放同一目录。支持格式：图片 `.jpg .jpeg .png .gif .webp .bmp`，视频 `.mp4 .webm .mov .mkv .avi`（推荐 `.mp4 H.264`，加载最快最兼容）。

---

## 参数说明

安装时传给 install 脚本，或安装后改快捷方式「目标」栏：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-CodexPlusLauncherPath` | 自动探测 | codex-plus-plus.exe 路径；不传则自动探测（常见目录→注册表→快捷方式） |
| `-BackgroundMode` | `random` | `image` / `random` / `video` |
| `-MediaDirectory` | `assets\` | 媒体目录（图片视频可混放） |
| `-ImagePath` | `assets\sample-background.jpg` | image 模式固定图 |
| `-Opacity` | `0.15` | 通用透明度兜底值 |
| `-ImageOpacity` | 回退 Opacity（0.15） | 图片专用透明度 |
| `-VideoOpacity` | `0.2` | 视频专用透明度（比图片略高，动态内容更明显） |
| `-RotateInterval` | `3600` | 运行时轮换间隔（秒），`0` = 不轮换 |
| `-SuppressCodexPlus` | 关 | 持续压制 Codex++ 静态背景图（保险开关，见下） |

**仅核心脚本 `codex-background.ps1` 才有的参数**（一般不用直接调）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DebugPort` | `9229` | Codex CDP 端口（Codex++ 附加的） |
| `-VideoPath` | 无 | image 模式下直接放单个视频 |
| `-NoLaunch` | 关 | 不启动 Codex++/Codex，只连已在跑的 9229 注入 |
| `-ValidateOnly` | 关 | 只校验参数和资源，不连接/启动 Codex |

**透明度参考**：图片默认 `0.15`（温和），视频默认 `0.2`（动态内容更明显）。混合轮换时两者自动按类型切换。

**轮换说明**：`-RotateInterval > 0` 时背景定时自动换（**不重启 Codex**），仅 `random`/`video` 模式生效。

---

## 与 Codex++ 协作

本工具走 Codex++ 的 launcher 启动 Codex，因此 **Codex++ 的全部增强功能（插件市场解锁、模型白名单、会话管理、菜单等）都保留**。

关于背景图：**Codex++ 自带一个静态背景图功能**（id `codex-plus-image-overlay`）。为避免与本工具的轮换层叠加显示（双层半透明图会很乱），请：

- **推荐**：在 Codex++ 设置里关闭「背景图覆盖」。本工具默认不开启压制，保持 JS 精简。
- **保险**：万一 Codex++ 升级或配置被重置导致背景图「诈尸」，安装时加 `-SuppressCodexPlus`，工具会用 `MutationObserver` 持续清除 Codex++ 的背景层。

​```powershell
# 安装时一并开启 Codex++ 背景压制（保险）
pwsh -ExecutionPolicy Bypass -File .\install-codex-background-shortcut.ps1 -SuppressCodexPlus
​```

---

## 常见问题

| 问题 | 解决 |
|---|---|
| 报「未找到 Codex++ 主程序」 | 先安装 [Codex++](https://github.com/BigPizzaV3/CodexPlusPlus)，或用 `-CodexPlusLauncherPath` 手动指定 |
| 报「等待 Codex CDP 页面超时」 | 确认 Codex 桌面版已装；手动双击 Codex++ 快捷方式打开 Codex 后，用 `-NoLaunch` 重试 |
| 背景没出现 | `pwsh -File .\codex-background.ps1 -ValidateOnly` 验证参数；在 Codex 里 `Ctrl+Shift+I` 看 Console |
| 出现双层背景图 | 在 Codex++ 设置里关闭背景图覆盖；或安装时加 `-SuppressCodexPlus` |
| 视频背景几秒后才出现 | 正常现象：大视频分块传输 + atob 解码 + 初始化需要数秒（几十 MB 的视频约十秒） |
| 视频空白不播放 | 多半格式问题（mkv/avi），转成 mp4 H.264；4K/超大视频加载更久，耐心等待 |
| 卸载 | 删快捷方式 + 删仓库目录，Codex 与 Codex++ 不受影响 |

---

## 技术细节（给开发者）

- **核心脚本** `codex-background.ps1`：CDP 注入 + 分块传输 + 轮换逻辑
  - `New-OverlayJavaScript`：生成注入 JS（覆盖层 id `codex-bg-rotator-overlay`、图片 dataURL / 视频 atob→blob、双透明度、轮换 `setMedia` 接口、分块 `begin/append/finalize` 接口、`installToken` 防串台、`ensurePlaying` 强制播放、可选 Codex++ 压制）
  - `Send-MediaToPage`：文件 → base64 → 小文件一次性 `setMedia` / 大文件（>3MB）分块 `begin/append*/finalize`
  - `Get-RandomMediaFromDirectory`：1:1 比例抽取（先抛硬币选类型再选文件）
  - `Find-CodexPlusLauncher` / `Start-CodexViaLauncher`：方案 C 启动链路
  - `Test-CdpAvailable`：探测 9229，已开则直接注入不重启
- **启动器** `codex-background-launcher.cs`：~113 行 C#，无控制台拉起 pwsh，改源码后安装脚本自动重编译
- **安全**：CDP 只绑 `127.0.0.1`；不修改 Codex/Codex++ 任何文件；不依赖本地 HTTP 服务（媒体全部以 dataURL/blob 方式注入，绕开 CSP）

---

## 致谢

- 工具版本：1.0
- 依赖：[OpenAI Codex](https://openai.com/codex/) 桌面版 + [Codex++](https://github.com/BigPizzaV3/CodexPlusPlus)（BigPizzaV3）
- 参考项目：[codex-background-lite](https://github.com/killosky/codex-background-lite)（killosky，印证了 CSP 约束与 dataURL 方案）
- 示例素材：背景图来自游民星空（gamersky），示例视频为赛博朋克风格（MoeWalls），仅作演示，商用请替换为自有素材
