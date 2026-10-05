#!/usr/bin/env python3
"""Explicit terminal-only disclosure. No credential output through the module CLI."""
import os
from pathlib import Path
import resource
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lifecycle import Node, NodeError


class ViewError(Exception):
    """Only user-safe constant messages, never underlying exceptions or input values."""


class Terminal:
    def __enter__(self):
        if not all(os.isatty(fd) for fd in (0, 1, 2)):
            raise ViewError('为避免凭据进入文件或日志，请在本人已登录的交互终端直接打开此菜单，不要使用管道或重定向。')
        self.fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY | os.O_CLOEXEC)
        try:
            # /dev/tty has its own device number, not the actual PTY's number.
            target = os.fstat(0)
            if (not stat.S_ISCHR(target.st_mode)
                    or any(os.fstat(fd).st_rdev != target.st_rdev for fd in (1, 2))
                    or os.tcgetpgrp(self.fd) != os.tcgetpgrp(0)
                    or os.tcgetpgrp(self.fd) != os.getpgrp()):
                raise ViewError('当前输入和输出不属于同一个前台交互终端。请重新通过本人 SSH 会话打开平台。')
        except BaseException:
            os.close(self.fd)
            raise
        return self

    def __exit__(self, *_):
        os.close(self.fd)

    def write(self, text):
        remaining = text.encode('utf-8')
        while remaining:
            written = os.write(self.fd, remaining)
            remaining = remaining[written:]

    def line(self):
        value = bytearray()
        while len(value) < 64:
            char = os.read(self.fd, 1)
            if not char:
                return None
            if char == b'\n':
                return value.decode('ascii', errors='replace').strip()
            value.extend(char)
        return None

    def size(self):
        return os.get_terminal_size(self.fd)


def require_admin():
    if os.geteuid() != 0:
        raise ViewError('需要管理员权限才能读取受保护节点资料。请在本人 SSH 会话中以管理员权限打开平台，再选择此项。')


def find_encoder():
    tool = shutil.which('qrencode', path='/usr/bin:/bin')
    if tool is None:
        raise ViewError('二维码工具未安装，仍可查看并复制链接。本次不会自动安装软件。')
    path = Path(tool).resolve()
    for item in (path, *path.parents):
        info = item.stat()
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ViewError('二维码工具的权限不安全，本次不运行它。仍可查看并复制链接。')
    return str(path)


def qr_matrix(uri):
    if len(uri.encode('utf-8')) > 2048:
        raise ViewError('导入内容过长，不适合在终端扫码。请改用可复制链接。')
    tool = find_encoder()
    try:
        result = subprocess.run([tool, '-t', 'ASCII', '-m', '4', '-l', 'M', '-o', '-'],
                                input=uri.encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=5, check=False, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
        if result.returncode or len(result.stdout) > 80000:
            raise ValueError()
        lines = result.stdout.decode('ascii').splitlines()
        width = len(lines)
        if not 29 <= width <= 185 or (width - 29) % 4:
            raise ValueError()
        matrix = []
        for line in lines:
            if len(line) != width * 2:
                raise ValueError()
            pairs = [line[i:i + 2] for i in range(0, len(line), 2)]
            if any(pair not in ('##', '  ') for pair in pairs):
                raise ValueError()
            matrix.append([pair == '##' for pair in pairs])
        # Preserve the four-module quiet zone; never render arbitrary tool output.
        if any(matrix[y][x] for y in range(width) for x in range(width)
               if min(x, y, width - 1 - x, width - 1 - y) < 4):
            raise ValueError()
        if not any(any(row) for row in matrix):
            raise ValueError()
        return matrix
    except (OSError, ValueError, subprocess.TimeoutExpired):
        raise ViewError('二维码生成失败，未显示不完整图片。请改用可复制链接。') from None


def qr_frame(matrix, size):
    columns, rows = len(matrix) + 2, (len(matrix) + 1) // 2 + 4
    if size.columns < columns or size.lines < rows:
        raise ViewError(f'窗口不足以完整显示二维码，需要至少 {columns} 列、{rows} 行。请放大窗口或缩小字体后重试，也可改用链接。')
    if os.environ.get('TERM', '') in ('', 'dumb') or 'utf' not in (sys.stdout.encoding or '').lower():
        raise ViewError('当前终端未提供所需的彩色 UTF-8 显示条件。请改用可复制链接。')
    lines = []
    for y in range(0, len(matrix), 2):
        bottom = matrix[y + 1] if y + 1 < len(matrix) else [False] * len(matrix)
        lines.append(''.join((' ', '▄', '▀', '█')[2 * int(top) + int(low)]
                             for top, low in zip(matrix[y], bottom)))
    return '\x1b[30;47m' + '\n'.join(lines) + '\x1b[0m\n'


def show_link(terminal, uri):
    terminal.write('\n以下是可复制导入链接（未自动复制到剪贴板）：\n' + uri + '\n')
    terminal.write('请使用终端的选择/复制功能，在客户端选择从剪贴板导入。\n')


def show(terminal, mode):
    terminal.write('\n导入链接和二维码等同密码，获得它的人可能使用你的节点。\n'
                   '终端日志、录屏、历史回滚和截图都可能留存内容；程序无法阻止外部录制，清屏也不能撤销留存。\n'
                   '仅在本人已认证的 SSH/管理员终端查看，请勿分享屏幕或截图。\n'
                   '本次只按已有资料在内存生成导入信息，不写文件、不更换凭据、不修改服务。\n'
                   '确认在当前终端显示导入信息？ (y/N): ')
    answer = terminal.line()
    if answer not in ('y', 'Y'):
        terminal.write('\n已取消，未读取或显示节点凭据。\n')
        return 90
    # Process-local only; also inherited by the encoder, never a system setting.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    uri = Node().read_client_uri()
    if mode == 'link':
        show_link(terminal, uri)
    else:
        try:
            matrix = qr_matrix(uri)
            frame = qr_frame(matrix, terminal.size())
        except ViewError as error:
            terminal.write('\n' + str(error) + '\n输入 l 查看可复制链接；直接回车返回: ')
            if terminal.line() not in ('l', 'L'):
                return 90
            show_link(terminal, uri)
        else:
            terminal.write('\n请用客户端扫码；保持等宽字体和二维码完整显示。\n' + frame)
            terminal.write('字体或行距可能影响扫码；输入 l 改用可复制链接，直接回车返回: ')
            if terminal.line() not in ('l', 'L'):
                return 0
            show_link(terminal, uri)
    terminal.write('按回车返回；内容可能仍留在终端历史中。')
    terminal.line()
    return 0


def friendly_node_error(error):
    if str(error) == 'node_not_installed':
        return '尚未找到本脚本管理的节点。请返回节点菜单选择“安装节点”；若旧节点仍在使用，请勿重复安装或删除旧服务。'
    if str(error) == 'another_node_operation_is_running':
        return '节点正在执行其他操作，请等该操作结束后再查看。'
    if str(error) == 'pending_recovery_blocks_export':
        return '上一次变更尚未完成恢复。请先返回节点菜单检查状态，并按恢复提示处理，再查看导入信息。'
    return '节点资料缺失、权限异常或被其他程序更改，已停止显示。请返回节点菜单检查状态；如需恢复，请使用受保护备份，不要直接删除或重装。'


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv not in (['link'], ['qr']):
        print('请从 REALITY 节点菜单选择“显示可复制链接”或“显示本机二维码”。')
        return 64
    try:
        require_admin()
        with Terminal() as terminal:
            return show(terminal, argv[0])
    except ViewError as error:
        print(str(error), file=sys.stderr)
        return 30
    except NodeError as error:
        print(friendly_node_error(error), file=sys.stderr)
        return 30
    except (KeyboardInterrupt, EOFError):
        print('\n已停止显示；此前已显示的内容可能仍在终端历史中。', file=sys.stderr)
        return 90
    except Exception:
        print('暂时无法安全显示导入信息。请返回菜单检查节点状态和资料权限后重试；不要重复安装节点。', file=sys.stderr)
        return 40


if __name__ == '__main__':
    sys.exit(main())
