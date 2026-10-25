# OpenCode Todo HUD

[English](README.md) | **中文**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D6.svg)](#前置条件)
[![Node.js >= 18](https://img.shields.io/badge/node-%3E%3D18-339933.svg?logo=node.js&logoColor=white)](#前置条件)
[![OpenCode Desktop 2.0.31](https://img.shields.io/badge/OpenCode%20Desktop-2.0.31-6E56CF.svg)](#说明--兼容性)

> ⭐ 献给每个使用 opencode 的朋友，如果喜欢可以点个 star，谢谢您！
>
> ⭐ To every friend using OpenCode — if you like it, please give it a star. Thank you!

一个**贴在 OpenCode 窗口之上**的桌面小窗，实时显示 [OpenCode](https://opencode.ai)
桌面版里 **你当前正在看的那个会话/标签页**的待办清单与进度。

![OpenCode Todo HUD](demo.gif)

## 特性

- **只贴在 OpenCode 之上**（不是全局置顶）：切到浏览器等其它程序时，别的窗口照样盖住它；OpenCode 最小化它会跟着隐藏，OpenCode 关闭它也跟着关闭
- **无边框**窗口，不占任务栏；拖表头移动，拖边缘或四角缩放
- **跟随活动标签页** —— 在 OpenCode 里切换会话，窗口约 0.3 秒内跟着切过去
- 显示 `Todo 完成/总数`、进度条，以及每一条的状态：
  - `[✔]` 绿色 —— 已完成
  - `[>]` 黄色 —— 进行中
  - `[ ]` 灰色 —— 待做
- **文字跟着窗口缩放**：长条目自动折行不溢出，字号按窗口大小自动适配——把窗口拉宽/拉高字就变大填满，条目多字就变小，**所有步骤永远完整可见**；不出现横向滚动条，除非窗口小到连最小可读字号都放不下（此时改为可读字号 + 竖向滚动条，绝不隐藏步骤）
- **步骤文字可以选中复制**：按住拖动选中，`Ctrl+C` 复制；右键「Copy selected / Select all」
- 自动记住窗口大小与位置
- **只读 + 完全离线**：不联网，也绝不写 OpenCode 的任何数据

## 前置条件

| | |
|---|---|
| 系统 | Windows 10 / 11 |
| [Node.js](https://nodejs.org) | 18 及以上（用到内置的 `node:sqlite`） |
| PowerShell | Windows PowerShell 5.1（系统自带）**或** PowerShell 7+（`pwsh`） |
| OpenCode 桌面版 | 已在 **2.0.31** 上验证 |
| 插件 | [`opencode-todolist`](https://www.npmjs.com/package/opencode-todolist) |

> **为什么必须装那个插件？** OpenCode V2 已不再内置 `todowrite` 工具，是
> `opencode-todolist` 插件提供了它（`todowrite` / `todoread`），本 HUD 显示的
> 数据正来自它。该插件也能在 TUI 里画侧栏，但**桌面 GUI 没有插件面板接口**，
> 所以这个 HUD 才是让待办清单在桌面版可见的方式。

## 安装

1. 装插件：
   ```sh
   opencode plugin add opencode-todolist
   ```
2. 把本仓库下载/克隆到一个固定位置。
3. 双击 **`start.cmd`** 即可。想加桌面快捷方式就再跑：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-shortcut.ps1
   ```

## 操作

| 动作 | 方式 |
|---|---|
| 移动 | 拖**表头**（标题 / 进度条那一行） |
| 缩放 | 拖任意边缘或四角（光标会变成缩放箭头） |
| 选中 / 复制某条 | 在列表里按住拖动选中，再按 `Ctrl+C` |
| 复制全部 | 右键列表 → **Select all**（或 `Ctrl+A` 后 `Ctrl+C`） |
| 刷新 / 复位大小 / 关闭 | 右键表头或列表 |
| 让文字适配 | 直接缩放窗口，字号会自动跟着变 |

## 原理

全部只读，来自两个本地 SQLite 库：

- **当前标签页** —— OpenCode 桌面版把标签状态存在
  `%APPDATA%\ai.opencode.desktop\drafts.sqlite` 的 `state` 表，键 `tabs.recent`
- **待办清单** —— 存在 `%USERPROFILE%\.local\share\opencode\opencode.db` 的
  `kv` 表，键形 `plugin:<hex("aiev.todolist")>:todos/<会话ID>`

一个小 Node 取数进程监听这两个文件并写出 JSON 快照，PowerShell/WinForms 窗口负责渲染。

## 说明 / 兼容性

- 仅 Windows —— 界面是 PowerShell 驱动的 WinForms；Windows PowerShell 5.1（系统自带）与
  PowerShell 7+（`pwsh`）都能跑，`start.cmd` 在装了 `pwsh` 时优先用它、否则回落系统自带的 5.1，
  免安装任何东西
- 上面这两个库结构是 OpenCode 桌面版的**内部实现**，版本间可能变化。本项目在
  **2.0.31** 上验证；若未来版本改动，窗口会显示 *no todo list here*
- 窗口会**挂到 OpenCode 主窗口之上**（进程名以 `opencode` 开头、类名 `Chrome_WidgetWin_1` 的顶层窗口），作为它的*附属窗口*。OpenCode 还没启动时它就等着；OpenCode 一关，它跟着关
- 中文等非 ASCII 待办文本完全支持（按 UTF-8 读回）

## 致谢

- [`opencode-todolist`](https://github.com/aiev/opencode-todolist)（作者 [@aiev](https://github.com/aiev)）—— 提供本 HUD 所读取的待办工具（`todowrite` / `todoread`）

## 许可

[MIT](LICENSE)
