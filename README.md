# github_monitoring

本地/服务器定时轮询 GitHub 仓库，发现新提交自动推送**飞书群卡片通知**（提交列表 + AI 变更分析），全程不需要在 GitHub 侧配置任何 Webhook / Actions / 集成。

## 功能

- 定时（默认 1 分钟）`git fetch` 多仓库多分支，与本地基线 SHA 对比
- 检测到新提交 → 组装飞书交互卡片：
  - 提交列表：可点击 SHA（直达 GitHub commit）、作者、日期、标题
  - **AI 分析**（可选）：按提交拆分 diff 喂给 LLM，输出【技术实现】【对用户的影响】【风险与建议】三段
  - 「查看代码」按钮跳转仓库
- 失败自动重试；AI 不可用时降级为无分析区块的普通卡片
- 文件锁防并发（定时器重叠触发安全）
- 全部密钥/配置存放在本地 `~/.config/git-notify/`，**不进任何代码仓库**

## 依赖

- git（私有仓库需配好免密读取：SSH key 或 credential helper）
- python3（仅标准库）
- 一个飞书群自定义机器人 webhook（安全设置建议用「自定义关键词」，脚本消息含 `commit` 字样）
- AI 分析（可选）：任意 OpenAI Responses API 兼容服务

## 快速开始

```bash
git clone https://github.com/kanlina/github_monitoring.git
cd github_monitoring
./install/setup.sh
```

安装脚本会：
1. 把 `notify.sh` 装到 `~/.config/git-notify/`
2. 生成三个配置文件（见下），等你填好
3. 按操作系统自动注册定时任务（macOS=launchd / Linux=systemd user timer）
4. 手动跑一轮建立 SHA 基线（首增不通知）

## 配置文件（~/.config/git-notify/）

| 文件 | 说明 |
|---|---|
| `repos.conf` | 监听清单，每行 `名称\|仓库本地路径\|分支`，支持多行 |
| `webhook.txt` | 飞书群自定义机器人 webhook 地址（敏感，勿外传） |
| `ai_key.txt` | AI 服务 token（留空则通知不带 AI 分析） |
| `state/` | 各分支上次见到的 SHA（自动维护） |
| `notify.log` | 运行日志 |

示例配置见仓库内 `*.example` 文件。

## AI 分析

- 接口：OpenAI Responses API 兼容（`/v1/responses`），在 `notify.sh` 顶部修改 `ai.zonheng.net` 为你的服务地址即可
- 模型/字数/段落格式在 `notify.sh` 的 `instructions` 字段调整
- 注意：脚本会把 diff 发给 AI 服务，敏感仓库请评估是否启用

## 服务器部署

1. 服务器上克隆本仓库 + 业务仓库
2. `./install/setup.sh`，选 systemd 路径；SSH 断开后仍要运行需执行 `loginctl enable-linger $USER`
3. 业务仓库用 Deploy Key（只读）授权
4. cron 代替方案：`* * * * * $HOME/.config/git-notify/notify.sh`

## 常用运维

```bash
tail -f ~/.config/git-notify/notify.log          # 看日志
launchctl unload ~/Library/LaunchAgents/com.git-notify.plist   # mac 停止
systemctl --user stop git-notify.timer           # linux 停止
rm -rf ~/.config/git-notify/state                # 重置基线（会补发一条当前状态通知）
```
