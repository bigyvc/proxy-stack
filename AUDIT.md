# Dayv PSM 修改审计

日期：2026-10-03。目标仓库：[bigyvc/proxy-stack](https://github.com/bigyvc/proxy-stack)。

审计基线提交：`7620d0d857c970d6d2817e0165ee17ea3808ff51`。

## 范围与结论

对基线全部 **327 个 Git 跟踪文件**进行目录、内容类型、项目身份、安装/更新/发布来源、外部 URL、敏感凭据模式和格式检查。其中 320 个 UTF-8 文本文件已纳入全文扫描，7 个 PNG 已检查格式并查看缩略图。重点人工复核安装与自更新路径、Agent 下载及执行入口、工作流、四种语言 README、独立协议外部依赖和迁移路径。

此次是面向 Fork 自维护的全文件来源与配置审计，并结合已有测试验证修改；不是逐行形式化安全证明，也没有在所有支持系统上部署全部服务。外部脚本、内核和镜像的实现不在这 327 个仓库文件内。

修改后，本项目现行安装脚本、Agent 下载、项目徽章和工作流均使用 bigyvc/proxy-stack；上游归属及真实第三方依赖明确保留。未更改代理协议配置、客户端导出格式、默认安装目录或管理命令。

## 已修改内容

| 文件 | 修改及原因 |
| --- | --- |
| `bootstrap.sh` | 默认 Git 仓库改为 bigyvc；POSIX sh 的重下载地址改为本分支 raw 链接；重复运行时切换 origin 和 main 跟踪来源；特殊检出停止更新 |
| `manager.sh`、`install.sh`、`bootstrap.sh` | 去除 JQ 字样、原作者展示域名；展示 Dayv 和本仓库地址 |
| `lang/zh.sh`、`lang/en.sh`、`lang/ko.sh`、`lang/ru.sh` | 统一菜单标题为 Dayv's Proxy Stack Manager |
| `README.md`、`README_EN.md`、`README_KO.md`、`README_RU.md` | 更新安装命令、维护者说明和本分支入口；中英徽章改为本仓库；外部文档标为上游；纠正每次提交运行全部系统测试的陈述；移除容易误认成维护者地址的捐赠展示 |
| `.github/assets/banner.svg` | 新增 Dayv PSM 横幅；README 改为引用该 SVG |
| `.github/workflows/ci.yml` | 仓库条件改为 bigyvc；使用 GitHub 托管 runner；重型测试通过 full_tests 手动开启；基础检查加入 Python 3 |
| `.github/workflows/agent-release.yml` | 允许本仓库发布；增加网页 Run workflow 入口；校验版本并向当前提交发布 Agent 文件 |
| `.github/ISSUE_TEMPLATE/installation_failure.md` | 故障报告中的重现命令改为本分支入口 |
| `lib/agent.sh` | Agent 版本固定为原有 0.12.0，默认下载本仓库 Release，不回退到上游 |
| `agent/go.mod` | Go 模块路径改为 github.com/bigyvc/proxy-stack/agent |
| `lang/zh/snell.sh` | 修正“上游官方镜像”说法，明确它是第三方镜像 |
| `tests/fork-source.py`、`scripts/ci.sh` | 加入隔离、离线的安装来源回归测试，防止将来重新下载原版 |
| `FORK_GUIDE.md`、`AUDIT.md`、`audit/` | 新增上传、安装、发布、维护和验证说明及逐文件清单 |

## 保留内容及原因

| 引用 | 保留原因 |
| --- | --- |
| `LICENSE` | 原 AGPL-3.0 文本逐字保留，SHA-256 与基线一致 |
| `CHANGELOG.md` | 原历史记录保留，包括旧安装命令；这些记录不是本分支现行安装入口 |
| README 中的 jinqians/proxy-stack 链接 | 标明原项目来源，不代表安装来源 |
| `psm-docs.pages.dev` | 文档属于上游，仓库没有文档站源码；未编造你的文档域名 |
| `.github/assets/*.png` | 保留历史截图，菜单截图明确标注为上游示例；原 PNG 横幅作为历史资源保留，现行 README 使用新 SVG |
| `jinqians/snell.sh`、`jinqians/ss-2022.sh` | 独立 Snell/SS2022 模块实际执行的第三方安装器；没有对应 bigyvc 仓库，不能只改用户名 |
| `jinqians/snell-server:v5` | Alpine Snell 的真实第三方 Docker 镜像；状态检测、卸载逻辑和集成测试必须与镜像一致 |
| `jinqians/ipcheck` | 独立 IP 检测组件，按既有固定版本下载并检查校验和 |
| `jinqians/psm-panel` | Agent 兼容的外部面板项目，本次不包含面板源码 |
| XTLS / SagerNet / MetaCubeX 等 | 官方内核、规则集、证书、Docker、Cloudflare 等运行依赖地址，不属于 Fork 身份替换范围 |

原作者的安装域名只留在历史 CHANGELOG 中；当前脚本、README 和故障模板不再使用。保留的 jinqians 引用可以在 `audit/external-urls.json` 和源码中逐项核对。

## 已执行验证

| 检查 | 结果 |
| --- | --- |
| Bash 语法及非 ASCII 变量边界 | 212 个 `.sh` 文件通过 |
| ShellCheck 0.11.0 | 原项目 warning 级别检查通过；包括运行脚本及带 MSG 声明的语言表包装检查 |
| 四语言键集合 | zh/en/ko/ru 一致，通过 |
| 配置回归 | 72 个配置快照通过 |
| doctor JSON 合约 | 通过；诊断环境本身无代理服务，退出码 1 属于测试允许的诊断状态 |
| 节点 CLI | JSON、store-only 增删改查、凭据隐藏及用法退出码通过 |
| Fork 来源测试 | 新安装、POSIX sh 重下载、已有安装切换 origin 并获取 Fork 新提交、detached HEAD 拒绝更新，四项通过 |
| JSON / YAML / SVG | 73 个 JSON、13 个 YAML 和 1 个 SVG 成功解析；10 个工作流 run 块通过 Bash 语法检查 |
| GitHub Actions actionlint 1.7.12 | 两个工作流的语法、表达式及配置检查通过 |
| Go 1.27.1 | gofmt 无未格式化文件；go vet、go test 通过 |
| Agent 构建 | Linux amd64、arm64、armv7 三种静态构建成功；arm64/armv7 未在对应硬件执行 |
| 凭据模式扫描 | 基线文件未匹配私钥 PEM、GitHub PAT、Telegram Bot token、AWS Access Key 的扫描模式；这不覆盖所有凭据格式 |
| 文件一致性 | 逐文件 SHA-256 与原始基线比较；未修改文件保持一致 |

原项目静态检查保留其现有 ShellCheck 排除规则，本次没有删除失败测试或重写配置快照来取得通过。测试日志在 `audit/check-results.txt`。

## 已发现的继承行为与待办

1. **Agent Release 需要首次发布。** Fork 通常没有复制上游附件。现在它从你的仓库下载，需要先运行 `psm-agent release` 工作流，发布 `agent-v0.12.0` 及三个二进制、SHA256SUMS。普通本机管理不依赖该 Release。
2. **更新会还原运行目录源码。** manager 和 update 会保存本地未提交修改为补丁后 reset；bootstrap 无法快进时可重置到远端。此行为继承自原版，所以定制代码应提交到自己的仓库。环境变量可覆盖的安装来源仍按原接口保留。
3. **独立安装器仍依赖外部源码。** Snell 和 SS2022 的 systemd 菜单安装/更新会下载并执行上述外部脚本；当前按外部 main 分支获取，并未固定 commit 或校验脚本哈希。若需进一步供应链独立化，应另行审计并固定/导入这些项目，而非盲目替换地址。Alpine Snell 镜像也未固定 digest。
4. **部分查询/测试使用 HTTP。** 如 VPNGate 目录、IP 地理信息和连接测试；这些地址没有在本次品牌与来源修改中强行替换。URL 清单包含具体文件与行号。
5. **运行功能需要特权。** 防火墙、系统服务、证书、SSH 配置与软件安装会修改服务器。没有在本次交付环境执行实际 VPS 安装、真实协议握手、Telegram 通知、Cloudflare API 或跨系统 Docker 集成测试。
6. **CI 尚未在你的 GitHub 提交上运行。** 本地基础检查通过；上传后以你仓库 Actions 结果为准。高级 full_tests 使用真实容器和外部下载，托管 runner 与原自托管环境的差异可能需要后续适配。

## 交付清单

- 完整源码位于压缩包 `proxy-stack/` 内；不是仅有修改文件的增量包。
- `audit/file-inventory.tsv`：每个交付文件的路径、类型、修改状态和哈希；清单自身为避免循环哈希不填写自身哈希。
- `audit/external-urls.json`：当前文本文件中外部 URL 模板及所在文件/行号；含说明文档、模板和测试地址，不能等同于运行时一定发起的请求列表。
- `audit/check-results.txt`：执行检查的结果记录。
- 压缩包不含 `.git/`、测试工具、编译缓存、临时图片、服务器运行配置或认证数据。

上传与 Agent 发布操作见 [FORK_GUIDE.md](FORK_GUIDE.md)。
