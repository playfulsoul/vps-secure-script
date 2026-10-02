#!/usr/bin/env python3
"""Single REALITY node entry point. Default output is redacted."""
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import artifacts
import preflight
from lifecycle import Node, NodeError, install_signal_handlers
from target_check import TargetError


def main(argv=None):
    os.umask(0o077)
    try:
        parser = preflight.SafeParser(description=__doc__)
        parser.add_argument('action', choices=('check', 'plan', 'preflight', 'status', 'doctor', 'verify',
                                              'apply', 'configure', 'backup', 'rollback', 'uninstall', 'start', 'stop'))
        parser.add_argument('--target-host', default='127.0.0.1')
        parser.add_argument('--target-port', type=int)
        parser.add_argument('--server-name')
        parser.add_argument('--node-port', type=int, default=443)
        parser.add_argument('--public-address')
        parser.add_argument('--core-version', default=artifacts.VERSION)
        parser.add_argument('--upgrade', action='store_true')
        parser.add_argument('--export-client', action='store_true')
        parser.add_argument('--transaction')
        args = parser.parse_args(argv)
        if args.action == 'plan':
            print('仅管理单个 VLESS + REALITY + Vision 节点；目标必须是已准备好的本机 HTTPS 服务。')
            print('安装新增独立低权限服务及精确防火墙规则；操作前备份，失败恢复。不会更改 SSH、旧面板、网站或证书。')
            print('卸载保留受保护的恢复资料和已校验内核。备份与客户端导出含凭据，不可公开。')
            return 0
        if args.action == 'check':
            return preflight.main(['check'])
        if args.action == 'preflight':
            if None in (args.target_port, args.server_name, args.public_address):
                raise NodeError('required_target_and_endpoint_arguments_missing', 64)
            print(preflight.prerequisites(args))
            return 0
        preflight.platform_check()
        if os.geteuid() != 0:
            raise NodeError('root_required')
        node = Node()
        if args.action in ('status', 'verify', 'doctor'):
            if not node.root.exists():
                print('NODE=not_installed; PUBLIC_CLIENT=not_tested')
                return 10
            node.secure_path(node.root, directory=True)
            if node.pending.exists():
                raise NodeError('pending_recovery_requires_rollback', 60)
            if args.action == 'status':
                node.ownership()
                state = node.service_state()
                print('NODE=' + ('active' if state['active'] else 'stopped_or_absent') + '; PUBLIC_CLIENT=not_tested')
            else:
                node.firewall_gate()
                print(node.verify())
            return 0
        install_signal_handlers()
        with node.locked():
            if args.action == 'apply':
                if None in (args.target_port, args.server_name, args.public_address):
                    raise NodeError('required_target_and_endpoint_arguments_missing', 64)
                result = node.install(args)
            elif args.action == 'configure':
                if args.upgrade == args.export_client:
                    raise NodeError('choose_upgrade_or_export_client', 64)
                if args.upgrade:
                    result = node.upgrade(args.core_version)
                else:
                    node.export_client()
                    print('CLIENT_EXPORT=protected_server_file; SECRET_VALUES=not_printed')
                    print('客户端配置和导入链接保存在 /var/lib/vps-secure-reality-node/ 的 client-export.json 与 client-link.txt；仅 root 可读，请勿公开。')
                    return 0
            elif args.action == 'backup':
                identifier = node.backup()
                print('BACKUP=' + identifier + '; PERMISSIONS=private; SECRET_VALUES=not_printed')
                return 0
            elif args.action == 'rollback':
                result = node.rollback(args.transaction)
            else:
                result = node.change_state(args.action)
        print('NODE_OPERATION=' + ('unchanged' if result == 10 else 'completed') + '; PUBLIC_CLIENT=not_tested')
        return result
    except (NodeError, preflight.PreflightError) as error:
        print('NODE_OPERATION=' + str(error), file=sys.stderr)
        return error.code
    except TargetError as error:
        print('NODE_OPERATION=' + str(error), file=sys.stderr)
        return 30
    except Exception:
        print('NODE_OPERATION=unexpected_failure_redacted; CHECK_PENDING_RECOVERY=required', file=sys.stderr)
        return 40


if __name__ == '__main__':
    sys.exit(main())
