#!/usr/bin/env python3
"""Apply the Ubuntu 24.04 nginx security backport without upgrading the host."""

import os
import platform
import re
import socket
import ssl
import subprocess
from pathlib import Path


MINIMUM_VERSION = "1.24.0-2ubuntu7.20"
PUBLIC_ORIGINS = (
    "auth.cloudgeni.us",
    "pangolin.cloudgeni.us",
    "immich.cloudgeni.us",
    "vault.cloudgeni.us",
    "dstar.cloudgeni.us",
    "backend.cloudgenius.app",
    "hls.cloudgenius.app",
    "thecloudseminar.com",
    "www.thecloudseminar.com",
)


def output(*command):
    return subprocess.check_output(command, text=True, timeout=60).rstrip("\n")


def is_fixed(version):
    if not re.fullmatch(r"1\.24\.0-2ubuntu7(?:\.\d+)*", version):
        raise RuntimeError(f"Refusing an unexpected nginx package track: {version}")
    result = subprocess.run(
        ["dpkg", "--compare-versions", version, "ge", MINIMUM_VERSION],
        check=False,
    )
    if result.returncode not in (0, 1):
        result.check_returncode()
    return result.returncode == 0


def installed_packages():
    metadata = output(
        "dpkg-query", "-W",
        "-f=${binary:Package}\t${source:Package}\t${db:Status-Status}\t${Version}\n",
    )
    packages = {}
    for line in metadata.splitlines():
        name, source, status, version = line.split("\t")
        if source == "nginx" and status == "installed":
            packages[name] = version
    if not any(name.split(":")[0] == "nginx" for name in packages):
        raise RuntimeError("nginx must already be installed")
    return packages


def validate_plan(plan, packages):
    upgrade_planned = False
    for line in plan.splitlines():
        fields = line.split()
        if fields and fields[0] in ("Inst", "Conf", "Remv", "Purg"):
            if len(fields) < 2:
                raise RuntimeError("Malformed APT transaction plan")
            action, package = fields[:2]
            if action not in ("Inst", "Conf") or package not in packages:
                raise RuntimeError(f"Refusing an APT action outside this patch: {line}")
            if action == "Inst":
                upgrade_planned = True
    if not upgrade_planned:
        raise RuntimeError("APT did not plan any nginx package upgrade")


def check_origin():
    config = output("nginx", "-T")
    if re.search(r"(?m)^\s*(?:listen\b[^;]*\bhttp2\b[^;]*;|http2\s+on\s*;)", config):
        raise RuntimeError("HTTP/2 must remain disabled in the origin configuration")
    context = ssl.create_default_context(
        cafile="/etc/cloudflared/cloudflare-origin-ca-rsa.pem"
    )
    context.set_alpn_protocols(["h2", "http/1.1"])
    for host in PUBLIC_ORIGINS:
        with socket.create_connection(("127.0.0.1", 443), timeout=10) as connection:
            with context.wrap_socket(connection, server_hostname=host) as tls:
                if tls.selected_alpn_protocol() != "http/1.1":
                    raise RuntimeError(f"Expected HTTP/1.1 at the origin: {host}")
    print("Origin TLS verified; HTTP/2 disabled on all public origins.", flush=True)


def master_uses_installed_binary():
    pid = output("systemctl", "show", "nginx", "--property=MainPID", "--value")
    if not re.fullmatch(r"[1-9]\d*", pid):
        raise RuntimeError(f"nginx has no valid running master PID: {pid}")
    return Path("/usr/sbin/nginx").samefile(f"/proc/{pid}/exe")


def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run as root or via sudo")
    release = platform.freedesktop_os_release()
    if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04":
        raise RuntimeError("This patch is only for Ubuntu 24.04")
    if socket.gethostname().split(".")[0] != "clara":
        raise RuntimeError("This workflow may only patch Clara")

    os.environ.update(
        LC_ALL="C", DEBIAN_FRONTEND="noninteractive", NEEDRESTART_MODE="l"
    )
    subprocess.check_call(["systemctl", "is-active", "--quiet", "nginx"])
    check_origin()
    packages = installed_packages()
    fixed = [is_fixed(version) for version in packages.values()]
    packages_updated = False
    if not all(fixed):
        subprocess.check_call(["apt-get", "update"])
        policy = output("apt-cache", "policy", "nginx")
        match = re.search(r"^\s*Candidate:\s*(\S+)\s*$", policy, re.MULTILINE)
        if not match or not is_fixed(match.group(1)):
            raise RuntimeError(f"APT does not offer nginx {MINIMUM_VERSION} or newer")
        candidate = match.group(1)
        targets = [f"{name}={candidate}" for name in sorted(packages)]
        install = [
            "apt-get", "--yes", "--only-upgrade", "--no-install-recommends",
            "--no-remove", "-o", "Dpkg::Options::=--force-confold",
            "install", *targets,
        ]
        plan = output(install[0], "--simulate", *install[1:])
        validate_plan(plan, packages)
        subprocess.check_call(install)
        packages_updated = True

    packages = installed_packages()
    if any(not is_fixed(version) for version in packages.values()):
        raise RuntimeError("Installed nginx packages are still below the fixed version")
    subprocess.check_call(["nginx", "-t"])
    if packages_updated or not master_uses_installed_binary():
        print("Restarting only nginx to load the installed packages.", flush=True)
        subprocess.check_call(["systemctl", "restart", "nginx"])
    subprocess.check_call(["systemctl", "is-active", "--quiet", "nginx"])
    if not master_uses_installed_binary():
        raise RuntimeError("The nginx master is not using the installed executable")
    check_origin()
    for name, version in sorted(packages.items()):
        print(f"Verified package: {name} {version}", flush=True)
    print("Running master matches the patched installed binary.", flush=True)


if __name__ == "__main__":
    main()
