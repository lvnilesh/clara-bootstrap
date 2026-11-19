import fnmatch
import importlib.util
import os
import subprocess
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "patch_nginx", Path(__file__).resolve().parents[1] / "scripts/patch-nginx.py"
)
if spec is None or spec.loader is None:
    raise RuntimeError("Cannot load the nginx patch policy")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

OLD = "1.24.0-2ubuntu7.19"
FIXED = "1.24.0-2ubuntu7.20"
NEWER = "1.24.0-2ubuntu7.21"


class InventoryTests(unittest.TestCase):
    def test_selects_source_packages_regardless_of_binary_name(self):
        rows = {
            "nginx": f"nginx\tnginx\tinstalled\t{OLD}",
            "libnginx-mod-mail": f"libnginx-mod-mail\tnginx\tinstalled\t{OLD}",
            "openssl": "openssl\topenssl\tinstalled\t3.0.13",
            "nginx-full": "nginx-full\tnginx\tnot-installed\t",
        }

        def query(command, **kwargs):
            patterns = command[3:]
            return "\n".join(
                row for name, row in rows.items()
                if not patterns or any(fnmatch.fnmatchcase(name, p) for p in patterns)
            ) + "\n"

        with mock.patch.object(policy.subprocess, "check_output", side_effect=query):
            self.assertEqual(
                policy.installed_packages(),
                {"nginx": OLD, "libnginx-mod-mail": OLD},
            )


class PatchPolicyTests(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.version = OLD
        self.package_overrides = {}
        self.extra_packages = {}
        self.candidate = FIXED
        self.master_current = True
        self.restart_works = True
        self.commands = []
        self.plan = "Inst nginx\nInst nginx-common\nConf nginx\nConf nginx-common\n"
        stack.enter_context(mock.patch.dict(os.environ, {}, clear=True))
        stack.enter_context(mock.patch.object(policy.os, "geteuid", return_value=0))
        stack.enter_context(mock.patch.object(
            policy.platform, "freedesktop_os_release",
            return_value={"ID": "ubuntu", "VERSION_ID": "24.04"},
        ))
        stack.enter_context(mock.patch.object(
            policy.socket, "gethostname", return_value="clara"
        ))
        stack.enter_context(mock.patch.object(policy, "check_origin"))
        stack.enter_context(mock.patch.object(
            policy.subprocess, "check_output",
            side_effect=lambda command, **kwargs: self.output(*command),
        ))
        stack.enter_context(mock.patch.object(
            policy.subprocess, "check_call", side_effect=self.run_command
        ))
        stack.enter_context(mock.patch.object(
            policy.subprocess, "run", side_effect=self.compare_versions
        ))
        stack.enter_context(mock.patch.object(
            policy.Path, "samefile", side_effect=lambda other: self.master_current
        ))

    def output(self, *command):
        if command[0] == "dpkg-query":
            common = self.package_overrides.get("nginx-common", self.version)
            return (
                f"nginx\tnginx\tinstalled\t{self.version}\n"
                f"nginx-common\tnginx\tinstalled\t{common}\n"
                + "".join(
                    f"{name}\tnginx\tinstalled\t{version}\n"
                    for name, version in self.extra_packages.items()
                )
                + "nginx-full\t\tnot-installed\t"
            )
        if command == ("apt-cache", "policy", "nginx"):
            return f"nginx:\n  Candidate: {self.candidate}"
        if command[0] == "apt-get" and "--simulate" in command:
            return self.plan
        if command == ("systemctl", "show", "nginx", "--property=MainPID", "--value"):
            return "123"
        self.fail(f"Unexpected command: {command}")

    def run_command(self, command):
        self.commands.append(command)
        if command[0] == "apt-get" and "install" in command:
            self.master_current = self.master_current and self.version == self.candidate
            self.version = self.candidate
            self.package_overrides.clear()
            self.extra_packages = dict.fromkeys(self.extra_packages, self.candidate)
        if command == ["systemctl", "restart", "nginx"] and self.restart_works:
            self.master_current = True

    def compare_versions(self, command, check):
        self.assertEqual(command[:2], ["dpkg", "--compare-versions"])
        self.assertEqual(command[3:], ["ge", FIXED])
        code = 0 if command[2] in (FIXED, NEWER) else 1
        return subprocess.CompletedProcess(command, code)

    def test_upgrades_only_installed_nginx_packages_and_loads_the_new_binary(self):
        for candidate in (FIXED, NEWER):
            with self.subTest(candidate=candidate):
                self.commands.clear()
                self.version = OLD
                self.candidate = candidate
                policy.main()
                installs = [
                    command for command in self.commands
                    if command[0] == "apt-get" and "install" in command
                ]
                self.assertEqual(len(installs), 1)
                self.assertEqual(
                    installs[0][installs[0].index("install") + 1:],
                    [f"nginx={candidate}", f"nginx-common={candidate}"],
                )
                self.assertIn(["systemctl", "restart", "nginx"], self.commands)
                self.assertEqual(os.environ["NEEDRESTART_MODE"], "l")
                self.assertTrue(self.master_current)

    def test_module_update_restarts_nginx_even_when_the_binary_matches(self):
        self.version = FIXED
        self.extra_packages["libnginx-mod-mail"] = OLD
        self.plan = "Inst libnginx-mod-mail\nConf libnginx-mod-mail\n"
        policy.main()
        self.assertIn(["systemctl", "restart", "nginx"], self.commands)

    def test_refuses_mixed_package_tracks_before_apt(self):
        self.package_overrides["nginx-common"] = "1.30.4-7ubuntu1.1"
        with self.assertRaisesRegex(RuntimeError, "unexpected nginx package track"):
            policy.main()
        self.assertFalse(any(command[0] == "apt-get" for command in self.commands))

    def test_refuses_unfixed_missing_or_wrong_track_candidates(self):
        for candidate in (OLD, "(none)", "1.30.4-7ubuntu1.1"):
            with self.subTest(candidate=candidate):
                self.commands.clear()
                self.candidate = candidate
                with self.assertRaises(RuntimeError):
                    policy.main()
                self.assertFalse(any("install" in command for command in self.commands))

    def test_refuses_unrelated_or_empty_transactions(self):
        plans = [
            f"Inst nginx\n{action}\n"
            for action in ("Inst openssl", "Conf openssl", "Remv nginx", "Purg nginx")
        ] + ["Reading package lists...\n0 upgraded\n"]
        for plan in plans:
            with self.subTest(plan=plan):
                self.commands.clear()
                self.plan = plan
                with self.assertRaises(RuntimeError):
                    policy.main()
                self.assertFalse(any("install" in command for command in self.commands))

    def test_fixed_packages_still_require_the_correct_running_master(self):
        for current, restart_works in ((True, True), (False, True), (False, False)):
            with self.subTest(current=current, restart_works=restart_works):
                self.commands.clear()
                self.version = FIXED
                self.master_current = current
                self.restart_works = restart_works
                if restart_works:
                    policy.main()
                else:
                    with self.assertRaisesRegex(RuntimeError, "not using"):
                        policy.main()
                self.assertFalse(any(command[0] == "apt-get" for command in self.commands))
                self.assertEqual(
                    ["systemctl", "restart", "nginx"] in self.commands, not current
                )


class OriginPolicyTests(unittest.TestCase):
    def test_rejects_http2_before_origin_probes(self):
        for directive in (
            "listen 443 ssl http2;",
            "listen\n443 ssl\nhttp2;",
            "http2 on;",
        ):
            with self.subTest(directive=directive):
                with (
                    mock.patch.object(policy, "output", return_value=directive),
                    mock.patch.object(policy.ssl, "create_default_context") as context,
                    mock.patch.object(policy.socket, "create_connection"),
                ):
                    with self.assertRaisesRegex(RuntimeError, "HTTP/2"):
                        policy.check_origin()
                    context.assert_not_called()

    def test_requires_http1_on_every_origin(self):
        for protocol in ("http/1.1", "h2"):
            with self.subTest(protocol=protocol):
                with (
                    mock.patch.object(policy, "output", return_value="listen 443 ssl;"),
                    mock.patch.object(policy.ssl, "create_default_context") as context,
                    mock.patch.object(policy.socket, "create_connection"),
                ):
                    tls = context.return_value.wrap_socket.return_value.__enter__.return_value
                    tls.selected_alpn_protocol.return_value = protocol
                    if protocol == "h2":
                        with self.assertRaisesRegex(RuntimeError, "HTTP/1.1"):
                            policy.check_origin()
                    else:
                        policy.check_origin()
                        self.assertEqual(
                            {
                                call.kwargs["server_hostname"]
                                for call in context.return_value.wrap_socket.call_args_list
                            },
                            set(policy.PUBLIC_ORIGINS),
                        )


if __name__ == "__main__":
    unittest.main()
