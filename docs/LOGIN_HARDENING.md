# 分阶段登录安全设置

这个向导用于把日常 SSH 登录从“root + 密码”逐步迁移到“普通用户 + 公钥 + sudo”。它不会一次性关闭所有旧入口，每个高风险步骤都需要新 SSH 窗口的实际验证。

## 安全顺序

1. 保持当前 root 或管理员 SSH 窗口不关闭。
2. 创建或复用一个普通用户，确认 sudo 权限，并从 GitHub 导入该用户的 SSH 公钥。
3. 用该普通用户和密钥打开新 SSH 窗口，然后使用向导给出的一次性令牌验证当前会话和 sudo。
4. 首次验证成功后，才能关闭 SSH 密码和键盘交互登录。
5. 密码登录关闭后，必须再打开一个新的密钥登录窗口并完成第二次验证。
6. 只有第二次验证成功后，才能选择 root 仅允许公钥登录，或完全禁止 root 直接登录。

推荐先使用“root 仅允许公钥登录”。它能阻止 root 密码登录，同时保留已验证的 root 公钥作为应急入口。“完全禁止 root 直接登录”更严格，应在确认普通用户的密钥、sudo 和服务商控制台均可用后再选择。

## 菜单操作

root 用户运行 `vps`，普通 sudo 用户运行 `sudo vps`，然后选择：

```text
2. SSH 与安全防护
2. 分阶段设置普通用户、密钥、密码和 root 策略
```

向导会在需要新窗口时显示完整验证命令。一次性令牌默认 30 分钟内有效，且只有目标普通用户通过 sudo 执行、服务器日志能证明该连接使用了公钥时才会通过。令牌创建之前的旧登录日志不能解锁后续步骤。

## 命令模式

```bash
sudo vps login prepare --user <普通用户> --github <GitHub用户名> --yes

# 在新的普通用户密钥登录窗口中，执行准备步骤显示的完整命令
sudo env VPS_LOGIN_SESSION="$SSH_CONNECTION" vps login verify --token <一次性令牌>

sudo vps login disable-password --user <普通用户> --yes

# 再次打开新窗口并验证后，二选一
sudo vps login restrict-root --user <普通用户> --mode key-only --yes
sudo vps login restrict-root --user <普通用户> --mode disable --yes
```

## 保护与恢复边界

- 模块不修改 SSH 端口，也不会删除用户已有的公钥。
- 准备阶段不修改 sshd 登录策略；验证失败时保留原登录方式。
- 模块只管理 `/etc/ssh/sshd_config.d/00-vps-secure-login-hardening.conf`。如果该路径已有非本模块文件，会停止而不覆盖。
- 每次修改后都会检查 sshd 语法、重新加载服务并读取实际生效值。验证失败会尝试恢复原配置。
- `sudo vps login rollback --yes` 只恢复本模块上一次已提交的 SSH 登录策略；不回滚用户创建、sudo 包安装或已完成的公钥导入。
- 如果自动恢复未完成，不要关闭当前 SSH 窗口，也不要手动删除 `/var/lib/vps-secure/modules/security-login-hardening/` 中的事务记录。
