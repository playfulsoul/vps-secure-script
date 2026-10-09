# 独立 REALITY 节点（Beta）

## 适用与停止条件

仅适用于 Debian 13、x86_64、systemd、单公网 IPv4、简单 UFW；管理一个 VLESS + REALITY + Vision 节点。不接管现有 x-ui、Xray、网站、复杂路由或容器防火墙。其他系统不属于本模块支持范围。

节点连接到自有的 IPv4 回环 HTTPS 目标，不使用任意外站作为目标。目标需提供系统信任、域名匹配的证书以及 TLS 1.3/h2。私网路由拒绝是节点配置中的防护，不能据此宣称整台主机的所有进程已实现出口隔离。

保留可用 SSH 管理连接和供应商救援入口。先检查实际 SSH 端口、系统、DNS、监听和防火墙所有者；发现冲突或待恢复事务时停止，不清空规则表、不删除 pending 文件、不停止旧网站来绕过检查。

## 持久安装与依赖

**位置：目标 VPS 的 SSH 终端，不是本机电脑终端。以下命令按 root 编写，不要求安装 sudo。** 已有 sudo 权限的普通管理员可先用 `sudo -i` 进入 root shell；没有该权限或没有 sudo 时停止，使用已有授权的 root 登录，不为执行本文放宽登录策略。保持另一条可用管理连接。

本指南对应已发布的 `2.1.0-beta.5` 预发布版；README 的默认稳定版 `2.0.0` 安装块不含节点模块，不能替代。**从官方 Release 下载同版本的归档和校验文件。** 若下载返回 404、版本不符或校验失败，立即停止，不退回 beta.2 或绕过校验。

下载失败时先停止：curl 不存在就安装 curl 与 ca-certificates；连接超时先检查 VPS 到 GitHub 及其下载域名的 HTTPS 可达性，稍后重试，不能仅凭超时认定服务商封锁；404 核对版本和官方 Release 文件名；SHA-256 失败不要安装，重新下载同一版本的两个官方文件。不要关闭防火墙、改 DNS、使用未知镜像或跳过校验。

在目标 VPS 的 root 终端先准备 Debian 13 下载工具和 Python 3：

```bash
(
  set -eu
  test "$(id -u)" -eq 0
  . /etc/os-release
  test "$ID" = debian
  test "$VERSION_ID" = 13
  test "$(uname -m)" = x86_64
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! test -s /etc/ssl/certs/ca-certificates.crt; then
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl python3
  fi
  python3 --version
)
```

确认上述检查成功后，整体执行以下 Beta 安装块。每次都创建新的下载目录和空白 `source` 子目录；子 shell 中任意失败即停止，不改变原终端目录、变量或 umask：

```bash
(
  set -eu
  test "$(id -u)" -eq 0
  umask 022
  node_install_work=$(mktemp -d "${TMPDIR:-/tmp}/vps-node-install.XXXXXX")
  cd "$node_install_work"
  curl --fail --location --show-error --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 --retry-max-time 600 --proto '=https' --proto-redir '=https' --tlsv1.2 --remote-name https://github.com/playfulsoul/vps-secure-script/releases/download/v2.1.0-beta.5/vps-secure-platform-2.1.0-beta.5.tar.gz
  curl --fail --location --show-error --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 --retry-max-time 600 --proto '=https' --proto-redir '=https' --tlsv1.2 --remote-name https://github.com/playfulsoul/vps-secure-script/releases/download/v2.1.0-beta.5/vps-secure-platform-2.1.0-beta.5.tar.gz.sha256
  sha256sum -c vps-secure-platform-2.1.0-beta.5.tar.gz.sha256
  mkdir source
  tar --no-same-owner --no-same-permissions -xzf vps-secure-platform-2.1.0-beta.5.tar.gz -C source
  cd source
  test "$(cat VERSION)" = 2.1.0-beta.5
  test -f modules/builtin/applications-reality-node/target_service.py
  ./install.sh
  /usr/local/bin/vps --version
  test "$(cat /usr/lib/vps-secure/VERSION)" = 2.1.0-beta.5
  test "$(cat /usr/lib/vps-secure/BUILD_ID)" = "$(cat BUILD_ID)"
  /usr/local/bin/vps module info applications.reality-node
)
```

校验文件应显示 `OK`，安装后的版本、构建身份和节点模块应一致。外部 SHA 只验证压缩包，安装器还会校验解压树；不要把归档、摘要或个人笔记放进 `source`，不要删除 `BUILD_ID` 或绕过身份检查。包和解压目录不混用，安全解压参数配合 `umask 022` 保持预期权限。失败后不执行下节，先处理明确报错。

以下示例采用正式持久目录 `/usr/lib/vps-secure`。配套首次运行会按源码位置记录平台 `bin/vps`，此后续期仍调用它检查防火墙。不要从临时解压目录运行配套，也不要搬走已记录的平台目录。

Python 3 必须先存在，才能调用配套的 `dependencies`，上面的准备块已包含检查与发行版安装。平台的 UFW 安全准备在配套之前完成，保留检测出的实际 SSH 端口，并用新的 SSH 连接验证；需要 active/default deny 的简单规则环境。

```sh
(
  set -eu
  /usr/lib/vps-secure/bin/vps firewall plan
  /usr/lib/vps-secure/bin/vps firewall apply --yes
  /usr/lib/vps-secure/bin/vps firewall verify
)
```

核对成功且新的 SSH 连接可用后，回到原 root 终端继续：

```sh
python3 -I /usr/lib/vps-secure/modules/builtin/applications-reality-node/target_service.py dependencies --yes
```

依赖安装拒绝覆盖已有 `policy-rc.d`，临时阻止软件包自动启动服务，只禁用本次新引入的默认 nginx/certbot 定时器。软件包会保留，事务回滚不等于卸载依赖或恢复整个操作系统。

## 证书与本机目标

两种模式分别处理：

- 首次自行签发：自有域名 A 正确指向本机，不使用不适用的 AAAA 或普通 HTTP CDN 代理；标准 HTTP 端口空闲且公网可达。配套管理挑战专用 HTTP 服务及精确防火墙规则，普通路径返回 404。
- 复用已有证书：明确原签发者负责续期，提供包含匹配证书链和私钥的受保护绝对目录。配套只校验、复制和同步，不接管签发者或原网站。

以下参数在**目标 VPS 的同一个交互式 root SSH 终端**输入；新开终端后须重新填写。不填密码、私钥或完整节点链接。域名先核对 A/AAAA，端口先核对监听与已有规则；不能为空，不用未替换的占位符。

```sh
TARGET_TOOL=/usr/lib/vps-secure/modules/builtin/applications-reality-node/target_service.py
NODE_CLI=/usr/lib/vps-secure/bin/vps
printf '自有证书完整域名: '
read -r NODE_DOMAIN
printf '本服务器公网 IPv4: '
read -r NODE_IPV4
printf '已确认空闲的节点入口端口: '
read -r NODE_PORT
printf '已确认空闲的回环 HTTPS 目标端口: '
read -r TARGET_PORT
python3 -I "$TARGET_TOOL" --help
```

本机目标端口必须与节点入口和 HTTP 挑战端口不同，且不对公网放行。下面首次签发与已有证书路径二选一；不要先执行首次路径再改成已有证书路径。任一步返回失败时停止，保留错误和事务状态，不继续签发或安装节点。

首次签发路径：

```sh
(
  set -eu
  : "${TARGET_TOOL:?请在当前终端设置入口}" "${NODE_DOMAIN:?请填写域名}" "${TARGET_PORT:?请填写目标端口}"
  python3 -I "$TARGET_TOOL" preflight --server-name "$NODE_DOMAIN" --target-port "$TARGET_PORT"
  python3 -I "$TARGET_TOOL" apply --yes --server-name "$NODE_DOMAIN" --target-port "$TARGET_PORT"
  python3 -I "$TARGET_TOOL" verify
)
```

首次模式此时显示 `TLS=awaiting_certificate`，不是证书已准备好。阅读并接受 CA 条款后，才运行：

```sh
(
  set -eu
  python3 -I "${TARGET_TOOL:?请设置入口}" issue --yes --accept-ca-terms
  python3 -I "$TARGET_TOOL" verify
)
```

新签发先走隔离 staging，再生产签发；账户无邮箱，不能依赖邮件提醒。已有自身 lineage 时验证并部署，不重新签发。正常续期不强制签发，且必须保留 HTTP-01 挑战入口。签发失败可能保留已确认的挑战服务及自有规则供修复或卸载；删除本地文件不能撤销 CA 侧签发。不要反复签发碰运气。

已有证书路径（替代上面的首次签发路径）：先确认源目录和原签发者的续期责任，再在同一 root 终端输入：

```sh
printf '已有证书 lineage 的受保护绝对目录: '
read -r TARGET_LINEAGE
(
  set -eu
  : "${TARGET_TOOL:?请设置入口}" "${NODE_DOMAIN:?请填写域名}" "${TARGET_PORT:?请填写目标端口}" "${TARGET_LINEAGE:?请填写证书目录}"
  python3 -I "$TARGET_TOOL" preflight --server-name "$NODE_DOMAIN" --target-port "$TARGET_PORT" --existing-lineage "$TARGET_LINEAGE" --external-renewal
  python3 -I "$TARGET_TOOL" apply --yes --server-name "$NODE_DOMAIN" --target-port "$TARGET_PORT" --existing-lineage "$TARGET_LINEAGE" --external-renewal
  python3 -I "$TARGET_TOOL" verify
)
```

其定时器只同步源文件；源证书到期时应处理原签发者，不能误把同步当续期。`dependencies` 或同参数不变操作可能返回 10，需结合明确的“不变”状态核验，不当成新增成功，也不忽略其他错误码。

新建公共 webroot 可由非特权 nginx worker 读取；私有证书状态仍保持私密。既有挑战目录若被改成不可遍历，Certbot 不会自动修复。不得为解决挑战失败而递归放宽证书私有目录。

## 节点、导出与验证

目标 `verify` 显示 `TLS=ready` 后，在保留上述参数的同一个 root 终端执行；新终端必须先重新填写参数：

```sh
(
set -eu
: "${NODE_CLI:?请设置入口}" "${NODE_IPV4:?请填写公网IPv4}" "${NODE_PORT:?请填写入口端口}" "${TARGET_PORT:?请填写目标端口}" "${NODE_DOMAIN:?请填写域名}"
"$NODE_CLI" module run applications.reality-node preflight \
  --public-address "$NODE_IPV4" --node-port "$NODE_PORT" \
  --target-host 127.0.0.1 --target-port "$TARGET_PORT" --server-name "$NODE_DOMAIN"
"$NODE_CLI" module run applications.reality-node apply --yes \
  --public-address "$NODE_IPV4" --node-port "$NODE_PORT" \
  --target-host 127.0.0.1 --target-port "$TARGET_PORT" --server-name "$NODE_DOMAIN"
"$NODE_CLI" module run applications.reality-node verify
"$NODE_CLI" module run applications.reality-node configure --yes --export-client
)
```

模块管理自己的精确 TCP 规则，不要预先添加冲突规则。标准 HTTPS 端口被占用时可选择另一个空闲节点入口，但这不代表支持共用网站端口或自动分流。

导出保存在 `/var/lib/vps-secure-reality-node/client-export.json` 和 `client-link.txt`，仅 root 可读。完整链接等同凭据；不要贴聊天、公开日志或在线二维码转换网站，不通过放宽权限获得导出。客户端传输需使用可信、已授权通道。

以下新菜单适用于 `2.1.0-beta.5` 及其对应构建。旧 beta.3 / beta.4 的节点菜单 1 是状态、2 是安装、10 是文件导出；不要在旧版按新编号操作。首页 **4「应用安装」→ 4「独立 REALITY 节点」** 入口不变。

普通用户优先选 **1「显示可复制导入链接」**，由本人手动选择复制到可信客户端；程序不会自动写入剪贴板。需本人在 root 管理员交互终端明确确认后才展示，不接受管道或重定向。链接等同访问凭据，注意共享会话、截图、录制及剪贴板同步，不发聊天或公开日志。清屏不能删除终端历史、会话录制、剪贴板历史或已有截图。

可选 **2「显示本机二维码」**。仅使用本机 `qrencode` 生成，不上传第三方，也不自动安装依赖。工具缺失、窗口不足或生成失败时，可主动输入 `l` 改用链接；已显示但扫码困难时也可这样切换，字体和行距可能影响识别。合成二维码独立解码及真实 SSH 缺工具时的主动链接退路已验证；实际二维码手机扫码与 GUI 导入尚未验收，不能将二维码显示或链接生成当作客户端联网成功。

**12「导出受保护文件」** 保留为高级用途，不直接显示链接；上面的 `configure --yes --export-client` 是此文件路线，不是交互显示命令。既有受保护文件和可信 SSH/SFTP 传输路线仍可用，不能为获取文件放宽权限。目标证书前置、适用平台和独立 runtime 的限制不变。

### 节点菜单

- 1：显示可复制导入链接；2：显示本机二维码。
- 3：查看状态；4：安装节点；5：检查节点，不替代公网客户端验收。
- 6：升级到当前已校验内核；7：创建受保护备份。
- 8：撤销最近一次变更，不是自动恢复刚创建的备份。
- 9：停止；10：启动；11：卸载节点并保留恢复资料。
- 12：高级受保护文件导出；0：返回。

实际客户端需完成认证后的 HTTPS 请求，并验证出口是预期服务器；active、配置检查、TCP 连通或公开 TLS 握手均不能替代它。分别验证 SSH、UFW、目标、节点和续期服务；手动定时任务成功不等于自然续期或真实换证已验收。

## 升级、恢复与卸载边界

- 节点菜单的内核升级仅选择当前固定校验版本，不追任意 latest。
- **平台升级不会自动更新 `/usr/local/lib/vps-secure-reality-target` 中的独立配套 runtime。没有已验收的通用配套自动升级/迁移流程。** 不要手工覆盖受保护 runtime，也不要把平台更新成功解释为节点内核和证书配套一起更新成功。
- 持久平台路径在常规升级/回滚后应保持可用；路径未变不能单独证明未来模块接口兼容。更新后仍须核验目标、续期和实际客户端。
- 节点与证书/防火墙配套各自保留事务。显式备份恢复使用对应的 `--transaction`；不带 ID 的 rollback 不是“恢复最新备份”。
- 配套 `runtime-pending.json` 或依赖恢复待处理时，按对应错误先执行不带 ID 的配套 rollback；不能删标记绕过。恢复依赖保留的证书代、二进制、runtime 和无关防火墙一致性，不是独立完整灾备。
- 受管节点仍引用目标时，配套拒绝卸载。先确认并卸载节点，再处理目标；卸载保留签发账户、源证书、代文件、事务、runtime、webroot 和依赖，不是秘密擦除。

本模块未完成 GUI 客户端、自然定时续期、到期换证或全部环境验收。既有代码的测试结果不自动适用于每个重新打包的构建；应分别核对版本、构建身份、归档摘要及对应验收范围。
