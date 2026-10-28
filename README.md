# Codex Quota Bar

在 Mac 菜单栏查看 Codex **5 小时 / 每周剩余额度**，点击即可查看详情和重置时间。

**[下载安装包](https://github.com/zheng-dada/codex-quota-bar/releases)** · macOS 13+ · Apple 芯片（M 系列）

## 界面预览

菜单栏：**左边是 5 小时，右边是每周**，默认显示剩余百分比。

采用 **13 pt 系统字体、原有细框分栏**；待机时背景透明，状态变化通过背景填色提示。

![菜单栏：5 小时剩余 51%，每周剩余 85%](docs/images/menu-bar.png)

**运行时，右侧自动切换为当前估算速率；完成或取消后恢复周限额。**

![运行中的菜单栏：左侧为 5 小时额度，右侧为估算速率](docs/images/menu-bar-running.png)

点击数值，展开额度面板：

<img src="docs/images/popup.png" alt="额度面板：两项剩余额度和重置倒计时，下方保留上一轮平均速率与首 Token 延迟" width="340">

<sub>以上为当前源码渲染的界面截图，数值为示例。</sub>

## 三步开始使用

1. **登录 Codex**：在这台 Mac 上安装 Codex 桌面端或 CLI，并使用自己的 ChatGPT 账户登录。
2. **安装工具**：在 [Releases](https://github.com/zheng-dada/codex-quota-bar/releases) 的 **Assets** 中下载 `CodexQuotaBar-macOS-arm64.zip`，解压后将 `Codex Quota Bar.app` 拖入「应用程序」。
3. **打开应用**：双击启动，在屏幕顶部菜单栏查看额度。无需填写 Token 或 API Key。

> 当前安装包仅支持 Apple 芯片 Mac。应用未做 Apple 公证；若首次打开提示无法验证开发者，确认下载来源可信后，到「系统设置 → 隐私与安全性 → 仍要打开」。[Apple 操作说明](https://support.apple.com/zh-cn/102445)

## 怎么用

| 想做什么 | 操作 |
| --- | --- |
| 查看额度和重置时间 | 点击菜单栏数值 |
| 查看运行速率 | 运行时查看菜单栏右侧的 `38t/s`；暂无样本时显示 `…` |
| 查看运行状态 | 看菜单栏背景颜色，悬停或打开面板可查看状态文字 |
| 查看上一轮速率和延迟 | 打开面板，查看双环下方的「上一轮」；下一轮运行期间保留原数值 |
| 切换显示方式 | 点击面板中的「剩余额度 / 已用额度」 |
| 立即更新 | 点击面板右上角刷新按钮；平时每分钟自动刷新 |
| 开机自动运行 | 点击右下角齿轮 →「登录时启动」 |
| 退出应用 | 点击右下角齿轮 →「退出 Codex Quota Bar」 |

菜单栏数值在 **10%–20% 时显示黄色，低于 10% 时显示红色**。默认模式下，数值越低，剩余额度越少。

背景颜色：**待机透明、蓝色运行、绿色完成、黄色取消、红色失败、橙色监控异常**。完成和取消显示 4 秒后恢复待机；失败保留到开始新任务。多个任务同时执行时保持蓝色。状态依据本机会话日志判断。

<details>
<summary>查看不同背景下的状态颜色</summary>

![浅色外观的六种状态与背景对比](docs/images/status-colors-light.png)

![深色外观的六种状态与背景对比](docs/images/status-colors-dark.png)

</details>

速率是**输出 Token 数 ÷ 整轮耗时**的估算平均值，包含等待和工具执行时间，随本地日志更新，不是逐 Token 的瞬时生成速度。首 Token 延迟采用 Codex 的记录，缺失时显示 `—`。多个任务并行时，菜单栏显示最近启动任务的速率。

## 常见问题

**打开后没有窗口？** 这是菜单栏应用，直接看屏幕顶部，不会显示 Dock 图标。

**显示 `—` 或找不到 Codex？** 先确认 Codex 已登录，再点击刷新。若仍找不到，点击齿轮 →「选择 Codex 可执行文件…」，选择本机的 `codex` 程序。账户未提供的额度窗口会显示 `—`；API Key 登录不提供这里的订阅额度。

**数值旁出现 `!`？** 表示刷新失败或重置时间已到、数据待同步。检查网络后重试，面板会保留上次数据并显示更新时间。

**运行统计没有数值？** 需要本机 Codex 写入会话记录。旧版本、远程任务或缺少统计字段时可能无法显示；此时额度查询仍可用。日志分批写入时速率会间隔更新；记录连续 30 分钟没有新事件时停止视作运行中。

**如何卸载？** 先关闭「登录时启动」，退出后删除应用。

## 账户与隐私

共用本机 Codex 登录，通过本机 Codex CLI 查询账户额度。不读取或复制登录令牌，不保存额度到磁盘，也不发起模型对话。若额度与桌面端不同，请确认两者使用相同账户和 `CODEX_HOME`。

运行统计增量读取 `CODEX_HOME/sessions`（默认 `~/.codex/sessions`）中的本机会话日志，不保留聊天正文、工具输出或登录信息。仅缓存上一轮的数值和时间，重启后仍可查看。

适合常驻：日志变化时才读取，空闲时不逐秒轮询；弹窗关闭后释放界面视图，电脑休眠时暂停监控。能够覆盖全部记录时，每 5 分钟校准一次目录；历史记录超出监听范围或监听不可用时，每 30 秒校准，旧聊天重新运行可能需要等待这次发现。已识别任务的速率按秒计算，显示不变时不重复刷新界面。

这是独立开发的本地工具，非 OpenAI 官方应用。

<details>
<summary>开发者：从源码构建</summary>

需要 Apple Command Line Tools（`xcode-select --install`），无需 npm 或第三方依赖。

```bash
git clone https://github.com/zheng-dada/codex-quota-bar.git
cd codex-quota-bar
bash test.sh
bash build.sh
open "dist/Codex Quota Bar.app"
```

应用生成在 `dist/`，按当前 Mac 的架构编译，使用本地 ad-hoc 签名。测试使用模拟服务，不访问真实账户。

运行 `bash performance.sh` 可检查大日志解析和 2,000 个历史文件下的空闲开销，默认测量 60 秒；只使用临时测试文件，不访问真实会话。[本次性能检查记录](docs/PERFORMANCE.md)

仅诊断连接和额度：

```bash
"dist/Codex Quota Bar.app/Contents/MacOS/CodexQuotaBar" --check
```

</details>
