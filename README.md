# GitHub Actions 云端自动领取

不开电脑也能每天自动领取 WorkBuddy / Trae 积分。

---

## 一、原理

```
你的电脑（开机时）                     GitHub 云端（每天定时）
┌──────────────────┐                  ┌──────────────────────┐
│ sync-token.ps1   │  推送最新 token   │  checkin.yml         │
│ 读本地登录态     │ ───────────────► │  每天 09:00 触发      │
│ 写入 GitHub      │   (Secrets)      │  跑 checkin.py       │
│ Secret           │                  │  调签到接口           │
└──────────────────┘                  └──────────────────────┘
```

- **云端只负责"定时执行"** —— 不需要你的电脑开着
- **本机只负责"提供令牌"** —— 开机时顺手同步一次
- 令牌有效期：WorkBuddy 约 55 天，Trae 约 2 周。本机同步让云端永远有有效令牌

---

## 二、文件说明

| 文件 | 作用 |
|---|---|
| `checkin.py` | 签到核心脚本，在 GitHub 云端运行 |
| `.github/workflows/checkin.yml` | 定时任务定义（每天 09:00 北京时间） |
| `sync-token.ps1` | 本机脚本：读取登录态并推送到 GitHub Secrets |
| `install-autosync.bat` | 把 `sync-token.ps1` 注册为开机自动运行 |
| `test-local.ps1` | 本地验证：上传前先跑通，避免配好了才发现令牌有问题 |
| `decrypt-trae.py` | 解密 Trae 登录态（`test-local.ps1` 会调用） |

---

## 三、部署步骤

### 第 1 步：创建 GitHub 仓库

1. 打开 <https://github.com/new>
2. 仓库名随意，例如 `daily-checkin`
3. **选 Private**（私有仓库同样免费，且令牌不会暴露）
4. 创建后，把本文件夹的内容推上去：

```bash
cd "E:\AiDemo\DailyCheckin\GitHub Actions"
git init
git add .
git commit -m "feat: 每日积分自动领取"
git branch -M main
git remote add origin https://github.com/你的用户名/daily-checkin.git
git push -u origin main
```

> **注意**：推送前确认 `.gitignore` 已排除 `sync-token.log` 等本地文件，
> 千万不要把明文令牌提交上去。

### 第 2 步：配置 token 同步方式（二选一）

#### 方式 A：装 GitHub CLI（推荐，最简单）

```powershell
winget install --id GitHub.cli
gh auth login
```

装好后 `sync-token.ps1` 会自动用它写 Secret，**不需要任何加密代码**。

#### 方式 B：用 Personal Access Token

1. 打开 <https://github.com/settings/tokens?type=beta> 创建**细粒度令牌**
2. 权限只勾 **Repository permissions → Secrets → Read and write**
3. 设置环境变量：

```powershell
setx GH_REPO "你的用户名/daily-checkin"
setx GH_PAT "你刚生成的PAT"
pip install pynacl
```

设置后**需要重开终端**才生效。

### 第 3 步：先本地验证

```powershell
cd "E:\AiDemo\DailyCheckin\GitHub Actions"
powershell -ExecutionPolicy Bypass -File test-local.ps1
```

看到 `========== 验证通过：两个平台都正常 ==========` 就说明令牌和逻辑都没问题。

### 第 4 步：同步令牌到 GitHub

```powershell
powershell -ExecutionPolicy Bypass -File sync-token.ps1
```

成功后会看到：

```
[OK] [GitHub] Secret WB_TOKEN 已更新
[OK] [GitHub] Secret TRAE_TOKEN 已更新
[OK] [GitHub] Secret TRAE_DEVICE_ID 已更新
[OK] ========== 全部同步成功 ==========
```

### 第 5 步：手动触发一次 Actions 验证

1. 打开仓库页面 → **Actions** 标签
2. 左侧选 **Daily Checkin**
3. 点右侧 **Run workflow** → **Run workflow**
4. 等十几秒，点进去看日志

看到这样的输出就成功了：

```
[WorkBuddy] 返回 code=10001, msg=今天已签到，请明天再来
[WorkBuddy] 今日已签到（幂等成功，说明端点可达、令牌有效）。
[Trae] 今日已签到，无需重复领取。
========== 全部成功 ==========
```

### 第 6 步：设置开机自动同步

```powershell
# 双击运行即可（会自动请求管理员权限）
install-autosync.bat
```

安装后会创建一个计划任务，每次登录时静默同步一次 token。

---

## 四、日常使用

配好之后你**什么都不用做**：

- 每天 09:00（北京时间），云端自动领取
- 你开电脑时，token 自动同步更新
- 想手动跑一次：Actions 页面点 **Run workflow**

### 查看状态

```powershell
# 查看自动同步任务
schtasks /Query /TN "DailyCheckin-SyncToken" /V /FO LIST

# 看同步日志
type "E:\AiDemo\DailyCheckin\GitHub Actions\sync-token.log"

# 手动执行同步
schtasks /Run /TN "DailyCheckin-SyncToken"
```

---

## 五、常见问题

### Q1: 令牌过期了怎么办？

重新登录对应的桌面客户端（WorkBuddy / Trae），然后跑一次同步：

```powershell
powershell -ExecutionPolicy Bypass -File sync-token.ps1
```

### Q2: 想改执行时间？

编辑 `.github/workflows/checkin.yml` 里的 `cron`。

**⚠️ GitHub 用 UTC 时间，北京时间要减 8 小时：**

| 想要的北京时间 | cron 写法 |
|---|---|
| 09:00 | `0 1 * * *` |
| 00:30 | `30 16 * * *` |
| 12:00 | `0 4 * * *` |

### Q3: Actions 突然不跑了？

GitHub 对**60 天无活动的仓库**会自动暂停定时任务。解决办法：
- 去 Actions 页面点一下 **Enable workflow**
- 或者往仓库随便推个 commit

由于 `sync-token.ps1` 会不定期更新 Secret，通常能维持活跃，一般不会被暂停。

### Q4: 为什么 WorkBuddy 总是返回 HTTP 400？

**这是正常的。** 该接口对合法请求就返回 HTTP 400 + 业务响应体，
`checkin.py` 里已经做了处理：不因状态码丢弃响应，只看业务体里的 `code`。

- `code = 0` → 本次新领到积分
- `code = 10001` → 今天已签到（幂等成功）

两者都算成功。

### Q5: 安全吗？

- 仓库设为 **Private**，只有你能看
- Secrets 加密存储，日志里自动打码
- 脚本只做两件事：调用官方签到接口 + 写 GitHub Secrets
- 令牌权限等同于你的登录态，**不要泄露仓库访问权限**

---

## 六、想升级成全自动（可选）

目前方案需要你**开电脑时同步 token**（实际上每月最多一两次，因为 WorkBuddy 令牌管 55 天）。

如果想彻底免手动，可以研究 refresh token 自动续期：

- WorkBuddy 的 `workbuddy-desktop.info` 里带 `refreshToken`（有效期 60 天）
- 但刷新接口走的是平台私有协议，需要逆向客户端才能确认端点

这属于进阶玩法，且客户端一升级就可能失效。**当前方案已经能满足"不用每天开电脑"的需求**，建议先用着，真有需要再折腾。

---

## 七、与本地版的关系

本方案与原有的 C# 版 `DailyCheckin` **互不冲突**，可以并存：

| | 本地版（Windows 服务） | 云端版（GitHub Actions） |
|---|---|---|
| 运行条件 | 电脑开机 | 无需开机 |
| 凭证 | 直读本地文件 | 从 Secrets 读 |
| 适用场景 | 常用电脑 | 长期不开机 / 出差 |

两个版本的签到接口都是**幂等**的，重复执行只会返回"今日已签到"，不会重复发积分。
所以即使两边都跑，也不会出问题。
