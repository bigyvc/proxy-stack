# Dayv PSM：维护、上传与发布

维护者：bigyvc（Dayv）。仓库：https://github.com/bigyvc/proxy-stack 。

这是基于 jinqians/proxy-stack 的维护分支，保留 AGPL-3.0、原贡献历史及上游变更记录。安装目录仍是 `/opt/psm`，命令仍是 `psm`，避免破坏既有服务、定时任务和配置路径。

## 将压缩包上传到 GitHub

压缩包内的 `proxy-stack/` 是完整仓库文件。上传的是该目录的**内容**，不要在 GitHub 仓库根目录再套一层 `proxy-stack/`。必须包括隐藏目录 `.github/` 和文件 `.gitignore`；压缩包不含 `.git/`、运行时配置或你的账号凭据。

网页操作：打开仓库 → Add file → Upload files → 上传解压后的文件 → Commit changes。文件数量较多，应分批上传。GitHub 不会把上传的 ZIP 自动解压成代码；不要只上传 ZIP。

默认基础 CI 会在提交到 `main` 后运行。如果你的 Fork 尚未启用 Actions，先打开 Actions 页面并按 GitHub 提示启用工作流。CI 徽章属于你的仓库，运行结果以 Actions 实际显示为准。

### VPS 上用 Git 上传（完整保留目录与历史）

将本次 ZIP 放在 VPS 的 `/root/proxy-stack-bigyvc-audited.zip`。不要在运行中的 `/opt/psm` 内改源码；以下使用单独工作目录：

```bash
mkdir -p /root/dayv-psm-upload
cd /root/dayv-psm-upload
git clone https://github.com/bigyvc/proxy-stack.git proxy-stack
unzip -o /root/proxy-stack-bigyvc-audited.zip -d /root/dayv-psm-upload
cd proxy-stack
git status --short
git diff --stat
git add -A
git commit -m "Customize Dayv PSM installation, branding, CI and fork documentation"
git push origin main
```

如果缺少命令，Debian/Ubuntu 先安装 `git unzip`。Git 身份使用你的姓名与 GitHub noreply 邮箱。HTTPS 推送按 GitHub 的认证方式使用有该仓库写入权限的令牌，或将 remote 改为你已配置的 SSH 地址；不要把令牌写进代码或 README。GitHub 网页对 `.github/workflows/` 的修改、保护分支及推送权限以你的账号设置为准。

## 从你的仓库安装

Debian / Ubuntu / 常规 Bash 系统，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bigyvc/proxy-stack/main/bootstrap.sh)
```

Alpine：

```sh
wget -qO- https://raw.githubusercontent.com/bigyvc/proxy-stack/main/bootstrap.sh | sh
```

手动安装：

```bash
git clone -b main https://github.com/bigyvc/proxy-stack.git /opt/psm
bash /opt/psm/install.sh
```

手动克隆适用于 `/opt/psm` 尚不存在的新安装。已有安装使用前面的 bootstrap 命令更新。

安装完成输入 `psm`。没有新增你尚未配置的域名，也不依赖原作者的安装域名。

## 已安装原版的服务器

重新运行本分支 bootstrap 后，它会把已有 `/opt/psm` 的 `origin` 和当前 `main` 分支的跟踪来源切到本分支，然后更新。非 `main` 分支或 detached HEAD 会停止并提示先切换分支；不会自动切换这些特殊检出。`PSM_REPO`、`PSM_BRANCH`、`PSM_BOOTSTRAP_URL` 仍可通过环境变量覆盖。

检查来源：

```bash
git -C /opt/psm remote get-url origin
git -C /opt/psm branch -vv
```

应指向 `bigyvc/proxy-stack`。菜单自动更新和 `psm --update scripts` 使用检出的 Git 跟踪来源。

继承的更新行为：脚本的未提交修改会先保存到 `/root/psm-local-changes-时间.patch`（实际路径使用当前 HOME）再还原；bootstrap 遇到无法快进时会重置到所选远端分支。源码定制应提交到 GitHub，不能只在运行目录手改。运行时的 `config/`、`backup/`、`logs/` 是 Git 忽略项。

## Agent 首次发布：手机也能操作

普通本机代理管理不需要 Agent。只有使用 `psm agent join` 接入面板时，才需要你仓库中的 Agent Release。

Fork 不会自动复制原作者的 Release 附件。首次发布步骤：

1. 先把修改后的完整文件提交到 `main`，启用仓库 Actions。
2. Actions → **psm-agent release** → **Run workflow**。
3. 选择 `main`，版本输入 `0.12.0`，运行。
4. 等待成功，在 Releases 确认 `agent-v0.12.0` 下存在 `psm-agent-linux-amd64`、`psm-agent-linux-arm64`、`psm-agent-linux-armv7` 和 `SHA256SUMS`。

工作流也支持推送 `agent-v*` 标签触发。版本必须与 `agent/main.go` 和 `lib/agent.sh` 保持一致。同名 Release 已存在时，`gh release create` 会报错；不要重复发布同一版本。二进制及校验文件都从你的仓库下载，下载失败不回退到原作者仓库。

本分支兼容上游 PSM 面板；面板 `jinqians/psm-panel` 是另外一个项目，本次没有复制或改名该项目。

## 测试与工作流

基础 CI 使用 GitHub 托管的 Ubuntu runner，不需要原作者的 `psm-vps` 自托管服务器。默认检查 Shell 语法、ShellCheck、四语言键集合、配置回归、诊断 JSON、节点操作、Fork 来源和 Agent 编译/测试。

实际内核校验和多系统集成测试保留：Actions → **CI** → **Run workflow** → 勾选 `full_tests`。它们会下载代理内核和系统镜像、创建特权测试容器，耗时及资源用量明显高于基础 CI。本次交付未在 Docker 中运行这组测试，不能把基础检查通过理解成所有系统实机部署均已通过。

本地基础检查（需要 Bash、ShellCheck、jq、OpenSSL、Python 3）：

```bash
bash scripts/ci.sh
cd agent
gofmt -l .
go vet ./...
go test -count=1 ./...
```

## 外部依赖与原作者引用

原作者安装域名已从现行脚本和 README 移除。保留的引用分为两类：

- 归属记录：许可证、上游仓库链接、历史 CHANGELOG、历史截图及明确标为“上游”的使用文档。
- 实际依赖：独立 Snell/SS2022 安装脚本、Alpine Snell Docker 镜像、IP 检测工具和面板兼容说明。它们不是本仓库文件，不能只替换用户名，否则将产生不存在的下载地址。Xray、sing-box、mihomo 等官方项目下载地址也保留。

详见 [AUDIT.md](AUDIT.md) 及 `audit/` 下的逐文件清单和外部 URL 清单。

## 与上游同步

保留 Fork 关系。以后使用 GitHub 的 Sync fork 或 Git 的 upstream remote 获取更新时，检查冲突及重新出现的原作者安装地址，尤其是 `bootstrap.sh`、`lib/agent.sh`、工作流与 README；不要直接覆盖本分支定制。

```bash
git remote add upstream https://github.com/jinqians/proxy-stack.git
git fetch upstream
git merge upstream/main
```

这里只添加名为 `upstream` 的维护来源；运行服务器的 `origin` 仍应指向你的仓库。不要用移除许可证或原作者归属说明的方式表述为完全原创。
