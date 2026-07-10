# Codex 背景注入工具

> 🪟 仅支持 **Windows 10 1607+ / Win11** | 需要 PowerShell 7 + OpenAI Codex 桌面版（Codex++ 可选）

给 [OpenAI Codex](https://openai.com/codex/) 桌面应用注入自定义背景：支持**图片和视频**、目录随机、图片视频 1:1 混合轮换、运行时定时换背景、图片/视频分别设透明度。

本工具支持两种启动方式：**装了 Codex++ 时走 Codex++** 启动 Codex（获得 Codex++ 全部增强功能）；**没装 Codex++ 时自动回退**到直接激活 Codex（仅背景功能）。

---

## 🚀 快速开始

**前置**：已安装 Codex 桌面版（必需）。如装了 Codex++（可选，推荐），请在 Codex++ 设置里关闭「背景图覆盖」（避免双层背景叠加）。

**三步搞定**：

1. 克隆或下载本仓库到固定位置（不要解压后又移动）
2. 用 PowerShell 7 安装（自动探测环境，用包内示例素材）：

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\install-codex-background-shortcut.ps1
   ```

3. 双击桌面的「Codex Background」快捷方式启动

工具会自动选择最优启动方式（有 Codex++ 走 Codex++，没有则直接激活 Codex），用 `assets\` 里的示例图片视频做 `random` 模式混合随机，每 60 分钟换一个。

> ⚠️ 如果 Codex 已经在跑且 CDP 端口 9229 已开，则直接注入（不重启 Codex），不打断会话。

> 💡 想用自己的壁纸库？安装时加 `-MediaDirectory "E:\你的壁纸库"`，图片视频可混放。

---

## 工作原理

Codex 桌面应用本身不开放背景配置，也不自带 CDP 调试端口。本工具依赖 **Codex++** 提供的启动入口：

1. **启动**（自动选择最优路径）：
   - 检测到 CDP 端口 9229 已开（Codex++ 或之前启动留下的）→ **直接注入，不重启 Codex**。
   - 装了 Codex++ → 通过 `codex-plus-plus.exe` 启动 Codex（Codex++ 附加 `--remote-debugging-port=9229` + 注入增强功能）。
   - 没装 Codex++ → 直接用 COM `IApplicationActivationManager` 激活 Codex MSIX 并附加 `--remote-debugging-port=9229`（**会重启 Codex，中断当前会话**，但无需任何第三方工具）。
2. **注入**：工具连上 `http://127.0.0.1:9229`，通过 CDP 向 Codex 主窗口页面注入一段 JS，创建一个全屏 `<img>`/`<video>` 覆盖层作为背景。
3. **媒体传输**（绕开 CSP 的关键）：Codex 页面有严格的 Content-Security-Policy，且实际运行时会拒绝 `file:` 与本地 HTTP 媒体 URL；但允许 `blob:` 作为媒体源。因此所有图片和视频都走同一条流式路径：
   - **PowerShell**：用 `FileStream` 每次读取 384 KiB 原始字节，编码为一个 512 KiB Base64 块后立即通过 CDP 推送；不会把整份媒体文件读入或编码为完整字符串。
   - **页面端**：每收到一块就立即 `atob` 解码为 `Uint8Array`，只保留原始字节块；全部到齐后创建 `Blob` 和 `blob:` URL，作为 `<img>` 或 `<video>` 的媒体源。
   - **资源回收**：新媒体先作为透明候选层加载。图片加载成功、或视频拿到可播放帧并完成静音播放后才替换旧背景；旧元素会停止、清空 `src`、移除，并调用 `URL.revokeObjectURL`。传输、解码或加载失败时，旧背景继续显示。
4. **轮换**：PowerShell 端定时随机选新媒体，以流式分块方式通过 CDP 调用页面里的 `window.__codexBgRotator` 更换背景；中断的传输会显式释放未完成分块。
5. **生命周期**：工具进程常驻，等 Codex 退出后自动结束，不留孤儿进程。

> 💡 视频较大时，分块传输与视频初始化需要数秒到十几秒（取决于文件大小）；旧背景会保持到新视频就绪，避免轮换期间空白。

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

## 修改配置

安装后所有配置保存在项目目录的 `config.json`。**想改背景/透明度/轮换间隔，编辑这个文件即可**，不用重新安装，也**不要手动改快捷方式属性**（Windows 保存时会截断参数）。

```json
{
  "BackgroundMode": "random",
  "MediaDirectory": "E:\\wallpapervideo",
  "RotateInterval": 3600,
  "Opacity": 0.15,
  "VideoOpacity": 0.2
}
```

改完保存，重启快捷方式生效。命令行参数优先级高于 config.json（临时覆盖用 `-MediaDirectory "..."` 等）。

---

## 参数说明

安装时传给 install 脚本，或安装后改快捷方式「目标」栏：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-CodexPlusLauncherPath` | 自动探测 | codex-plus-plus.exe 路径；不传则自动探测。找不到时自动回退 MSIX 自激活（无需 Codex++） |
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
| `-DebugPort` | `9229` | Codex CDP 端口（Codex++ 或自激活附加的） |
| `-VideoPath` | 无 | image 模式下直接放单个视频 |
| `-NoLaunch` | 关 | 不启动 Codex++/Codex，只连已在跑的 9229 注入 |
| `-CodexAumid` | 自动探测 | Codex MSIX 的 AUMID（无 Codex++ 时用于自激活）；默认用 Get-AppxPackage 自动取 |
| `-ValidateOnly` | 关 | 只校验参数和资源，不连接/启动 Codex，也不干扰正在运行的背景实例 |

**透明度参考**：图片默认 `0.15`（温和），视频默认 `0.2`（动态内容更明显）。混合轮换时两者自动按类型切换。

**轮换说明**：`-RotateInterval > 0` 时背景定时自动换（**不重启 Codex**），仅 `random`/`video` 模式生效。

---

## 与 Codex++ 协作

本工具走 Codex++ 的 launcher 启动 Codex，因此 **Codex++ 的全部增强功能（插件市场解锁、模型白名单、会话管理、菜单等）都保留**。

关于背景图：**Codex++ 自带一个静态背景图功能**（id `codex-plus-image-overlay`）。为避免与本工具的轮换层叠加显示（双层半透明图会很乱），请：

- **推荐**：在 Codex++ 设置里关闭「背景图覆盖」。本工具默认不开启压制，保持 JS 精简。
- **保险**：万一 Codex++ 升级或配置被重置导致背景图「诈尸」，安装时加 `-SuppressCodexPlus`，工具会用 `MutationObserver` 持续清除 Codex++ 的背景层：

  ```powershell
  pwsh -ExecutionPolicy Bypass -File .\install-codex-background-shortcut.ps1 -SuppressCodexPlus
  ```

---

## 常见问题

| 问题 | 解决 |
|---|---|
| 没装 Codex++ 能用吗 | 能。工具自动回退到直接激活 Codex（会重启 Codex 一次开启调试端口），仅少了 Codex++ 的增强功能 |
| 报「等待 Codex CDP 页面超时」 | 确认 Codex 桌面版已装；手动打开 Codex 后，用 `-NoLaunch` 重试 |
| 背景没出现 | `pwsh -File .\codex-background.ps1 -ValidateOnly` 验证参数；在 Codex 里 `Ctrl+Shift+I` 看 Console |
| 出现双层背景图 | 在 Codex++ 设置里关闭背景图覆盖；或安装时加 `-SuppressCodexPlus` |
| 视频背景几秒后才出现 | 正常现象：大视频需流式传输和初始化；旧背景会保留到新视频可播放 |
| 视频空白不播放 | 多半格式问题（mkv/avi），转成 mp4 H.264；4K/超大视频加载更久，耐心等待 |
| 卸载 | 删快捷方式 + 删仓库目录，Codex 与 Codex++ 不受影响 |

---

## 技术细节（给开发者）

- **核心脚本** `codex-background.ps1`：CDP 注入 + 流式传输 + 轮换逻辑
  - `New-OverlayJavaScript`：生成注入 JS（覆盖层 id `codex-bg-rotator-overlay`、统一 `blob:` 媒体源、双透明度、候选层原子换源、`begin/append/finalize/abort/dispose` 分块接口、旧 Blob 回收、可选 Codex++ 压制）
  - `Send-MediaToPage`：`FileStream` 按 384 KiB 原始块读取，逐块 Base64 编码并调用 `begin/append*/finalize`；失败时调用 `abort` 回收页面端缓冲
  - `Get-RandomMediaFromDirectory`：1:1 比例抽取（先抛硬币选类型再选文件）
  - `Find-CodexPlusLauncher` / `Start-CodexViaLauncher`：方案 C 启动链路
  - `Test-CdpAvailable`：探测 9229，已开则直接注入不重启
- **启动器** `codex-background-launcher.cs`：~113 行 C#，无控制台拉起 pwsh，改源码后安装脚本自动重编译
- **安全**：CDP 只绑 `127.0.0.1`；不修改 Codex/Codex++ 任何文件；不依赖本地 HTTP 服务（媒体最终以 `blob:` 注入，绕开 CSP）

---

## 致谢

- 工具版本：1.0
- 依赖：[OpenAI Codex](https://openai.com/codex/) 桌面版（必需）；[Codex++](https://github.com/BigPizzaV3/CodexPlusPlus)（可选，提供增强功能）
- 参考项目：[codex-background-lite](https://github.com/killosky/codex-background-lite)（killosky，印证了 CSP 约束与 dataURL 方案）
- 示例素材：背景图来自游民星空（gamersky），示例视频为赛博朋克风格（MoeWalls），仅作演示，商用请替换为自有素材
