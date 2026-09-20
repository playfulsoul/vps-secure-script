# Secure Remote Graphical Desktop

为 Debian/Ubuntu VPS 安装完整的 Linux 远程桌面，同时保留服务器的命令行启动和既有安全边界。

## 桌面档位

| 档位 | 桌面 | 建议资源 | 默认浏览器 |
| --- | --- | --- | --- |
| `lxqt` | LXQt 轻量版 | 1 核、1 GB 内存、6 GB 可用空间 | 不安装 |
| `xfce` | XFCE 推荐版 | 2 核、2 GB 内存、10 GB 可用空间 | Firefox |
| `mate` | MATE 完整版 | 2 核、4 GB 内存、15 GB 可用空间 | Firefox |

模块只安装一个桌面环境。GNOME/KDE 不属于首版支持范围。

## 固定安全边界

- 使用发行版提供的 `xrdp` 与 `xorgxrdp`，不执行第三方一键脚本。
- RDP 只监听 `127.0.0.1:3389`，不新增 UFW 规则，也不提供公网开放按钮。
- 用户通过现有 SSH 入口建立本地隧道后连接；不会修改 SSH 端口或认证方式。
- 禁止 root 图形登录，只允许 `vpsrdp` 组内用户登录。
- 默认关闭磁盘、打印和音频重定向；剪贴板仅允许文本。
- 不安装显示管理器，不切换 systemd 默认启动目标。
- 安装软件包期间先屏蔽 xrdp 服务；只有仅回环配置完成并通过检查后才解除屏蔽并启动，避免安装脚本短暂产生公网 RDP 监听。
- 配置写入 `/etc/vps-secure/remote-desktop`，通过项目自己的 systemd drop-in 使用；不覆盖发行版 `/etc/xrdp/*.ini`。
- 回滚会在卸载软件包前停止并清空 xrdp 的 systemd unit cgroup，并仅枚举受管用户中由 `xrdp-sesman` 建立的 X11 logind 会话。模块会核对用户、UID、service、scope、进程归属以及当前 SSH 控制会话隔离，再按精确 session ID 终止；任何枚举、归属或清空结果不确定时都会保留软件包和事务证据。
- 事务会记录本次新增的软件包；卸载和回滚只清理这些新增包，不删除普通用户、主目录或浏览器个人资料，也不执行大范围 `apt autoremove`。

## 命令示例

```bash
sudo vps module run applications.remote-desktop check
sudo vps module run applications.remote-desktop plan \
  --profile xfce --user desktop --create-user --browser firefox --set-password
sudo vps module run applications.remote-desktop preflight \
  --profile xfce --user desktop --create-user --browser firefox --set-password
sudo vps module run applications.remote-desktop apply --yes \
  --profile xfce --user desktop --create-user --browser firefox --set-password
sudo vps module run applications.remote-desktop status --connection
sudo vps module run applications.remote-desktop verify
sudo vps module run applications.remote-desktop rollback --yes
```

创建新用户或使用 `--set-password` 时，密码由系统 `passwd` 在交互终端中读取；不会出现在命令行、日志或模块状态文件中。

## 连接方法

模块状态页会按当前 SSH 连接生成示例。通用形式如下：

```bash
ssh -N -L 127.0.0.1:13389:127.0.0.1:3389 \
  -p <SSH端口> <SSH用户>@<服务器地址>
```

保持该 SSH 窗口打开，再让远程桌面客户端连接 `127.0.0.1:13389`。SSH 通道关闭时桌面连接会断开，但服务器文件不会因此丢失。
