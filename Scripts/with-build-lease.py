#!/usr/bin/env python3
"""Run a build with the workspace's shared acquire/verify/release protocol."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner', default='gaowenjian-' + str(os.getpid()))
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('需要提供待执行的构建或编译命令')
    lease = Path(__file__).resolve().parents[2] / '合并迁移-2026-11-02/build_lease.py'
    if not lease.is_file():
        raise SystemExit('缺少工作区指定的统一构建锁脚本，停止构建')
    base = [sys.executable, str(lease)]
    acquired = subprocess.run(base + ['acquire', '--owner', args.owner,
                              '--purpose', '搞文件编译及必要单元测试', '--title', '搞文件'],
                              capture_output=True, text=True)
    if acquired.returncode:
        print(acquired.stderr.strip(), file=sys.stderr)
        return acquired.returncode
    receipt = json.loads(acquired.stdout)
    env = dict(os.environ, GAO_BUILD_LEASE_OWNER=args.owner, GAO_BUILD_LEASE_TOKEN=receipt['token'])
    try:
        child = subprocess.Popen(command, env=env)
        def forward(signum, frame):
            child.send_signal(signum)
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, forward)
        return child.wait()
    finally:
        released = subprocess.run(base + ['release'], env=env, capture_output=True, text=True)
        if released.returncode:
            print('构建锁释放未完成：' + released.stderr.strip(), file=sys.stderr)


if __name__ == '__main__':
    raise SystemExit(main())
