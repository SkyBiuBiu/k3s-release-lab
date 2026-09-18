#!/usr/bin/env python3
"""Minimal SSH/SFTP helper for the K3S release-lab.

Credentials are read from outside the repo (never committed):
  env LAB_PASS  or  file %USERPROFILE%\\.workbuddy\\lab-secrets\\k3s-128.pass

Usage:
  python labssh.py run "<remote command>"
  python labssh.py script <local.sh>            # upload to /tmp and run with bash
  python labssh.py put <local> <remote>
  python labssh.py get <remote> <local>
"""
import os
import sys
import pathlib
import argparse

import paramiko

HOST = os.environ.get("LAB_HOST", "192.168.100.128")
PORT = int(os.environ.get("LAB_PORT", "22"))
USER = os.environ.get("LAB_USER", "root")
PASSFILE = os.environ.get(
    "LAB_PASSFILE",
    str(pathlib.Path.home() / ".workbuddy" / "lab-secrets" / "k3s-128.pass"),
)


def get_password() -> str:
    if os.environ.get("LAB_PASS"):
        return os.environ["LAB_PASS"]
    return pathlib.Path(PASSFILE).read_text(encoding="utf-8").strip()


def connect(timeout: int = 30) -> paramiko.SSHClient:
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(
        HOST,
        port=PORT,
        username=USER,
        password=get_password(),
        timeout=timeout,
        banner_timeout=timeout,
        auth_timeout=timeout,
        look_for_keys=False,
        allow_agent=False,
    )
    return cli


def run(cli: paramiko.SSHClient, command: str, timeout: int = 600) -> int:
    _, stdout, stderr = cli.exec_command(command, timeout=timeout)
    stdout.channel.settimeout(timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    rc = stdout.channel.recv_exit_status()
    if out:
        sys.stdout.write(out)
    if err:
        sys.stdout.write("\n--- STDERR ---\n" + err)
    sys.stdout.write(f"\n--- EXIT {rc} ---\n")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["run", "script", "put", "get"])
    ap.add_argument("a")
    ap.add_argument("b", nargs="?")
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()

    cli = connect()
    try:
        if args.action == "run":
            return run(cli, args.a, args.timeout)
        if args.action == "script":
            local = pathlib.Path(args.a).resolve()
            remote = "/tmp/_lab_run.sh"
            sftp = cli.open_sftp()
            sftp.put(str(local), remote)
            sftp.close()
            return run(cli, f"bash {remote}", args.timeout)
        if args.action == "put":
            sftp = cli.open_sftp()
            sftp.put(args.a, args.b)
            sftp.close()
            print(f"uploaded {args.a} -> {args.b}")
            return 0
        if args.action == "get":
            sftp = cli.open_sftp()
            sftp.get(args.a, args.b)
            sftp.close()
            print(f"downloaded {args.a} -> {args.b}")
            return 0
    finally:
        cli.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
