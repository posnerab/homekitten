#!/usr/bin/env python3
"""Forward HomeKitten's stdio MCP protocol over an existing trusted SSH connection.

The signed Mac app remains the HomeKit owner. SSH keys and host trust are managed
outside this launcher; it never accepts new host keys or prompts for passwords.
"""
import argparse
import shutil
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='Existing SSH alias for the Mac')
    parser.add_argument('--hostname', help='LAN hostname/address override, retaining existing trust')
    parser.add_argument('--host-key-alias', help='Existing trusted known_hosts identity')
    parser.add_argument('--python', default='/usr/bin/python3', help='Mac Python executable')
    parser.add_argument('--script', required=True, help='Absolute Mac homekit_agent.py path')
    parser.add_argument('--bridge', default='~/Documents/AgentBridge')
    args = parser.parse_args()
    ssh = shutil.which('ssh')
    if not ssh:
        parser.error('OpenSSH is required')
    command = [ssh, '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=30',
               '-o', 'ServerAliveCountMax=3']
    if args.hostname:
        command += ['-o', 'HostName=' + args.hostname]
    if args.host_key_alias:
        command += ['-o', 'HostKeyAlias=' + args.host_key_alias]
    remote = shlex.join([args.python, args.script, '--local-bridge', args.bridge, 'mcp'])
    command += [args.host, remote]
    # Inherit the client's streams unchanged: diagnostics remain on stderr and
    # request/result JSON stays on stdout. Never retry interrupted HomeKit writes.
    return subprocess.call(command)


if __name__ == '__main__':
    sys.exit(main())
