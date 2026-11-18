# Codex 剩余用量浮层

一个无侵入的 Windows 用量状态条：横向进度显示 Codex 主额度的剩余百分比；额度用完且接口返回余额时显示剩余额度，恢复后切回百分比。鼠标悬停时显示重置时间。

完整的安装、迁移和故障排查说明见 [使用手册](./使用手册.md)。

## 使用

1. 确保已安装并登录 Codex CLI（`codex --version` 可用）。
2. 双击 `start-overlay.cmd`。
3. 状态条会跟随 Codex 窗口并始终在顶部栏水平、垂直居中；右键可立即刷新、打开只读用量详情或退出。

运行 `Install-Startup.ps1` 可注册为 Windows 登录后无终端静默启动。计划任务每分钟执行一次健康检查，因此即使进程被外部强制终止也能恢复；从右键菜单正常退出则保持关闭到下次登录或手动启动。运行日志保存在 `%LOCALAPPDATA%\GPTBubble\GPTBubble.log`。浮层使用单实例保护，重复启动不会产生多个状态条。

状态条保持一个后台 `codex app-server` 连接，收到 `account/rateLimits/updated` 后立即更新，并每 60 秒兜底刷新。默认只显示 Codex 主额度，不显示 Spark，也不使用透明度变化。它会跟随 Codex 窗口移动和尺寸变化，始终在顶部栏水平、垂直居中，并处于 Codex 正上方一层；切换应用时由其他窗口自然覆盖，最小化或关闭 Codex 时自动隐藏。它不会修改 Codex 安装文件，也不会读取或保存登录令牌；数据来自官方 `account/rateLimits/read`。

详情窗展示 Codex 限额、重置时间、可用重置次数和各重置的到期日期。它不展示套餐或余额，也不提供使用重置、购买或升级操作。

## 单独验证数据源

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo -NoProfile -File .\Get-CodexUsage.ps1
```

如果提示未找到 Codex CLI，请先安装/更新 CLI 并完成登录。若账户通过 API Key 而不是 ChatGPT 登录，服务不会返回 ChatGPT 剩余用量。
