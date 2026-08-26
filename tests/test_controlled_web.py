from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]


def source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def external_path(path: Path, executable: str) -> str:
    resolved = path.resolve().as_posix()
    if executable.lower().endswith(".exe") and resolved.startswith("/mnt/"):
        return f"{resolved[5].upper()}:\\" + resolved[7:].replace("/", "\\")
    return str(path.resolve())


class ControlledWebPolicyTests(unittest.TestCase):
    def node_executable(self) -> str:
        node = shutil.which("node") or shutil.which("node.exe")
        self.assertIsNotNone(node, "Node.js is required for proxy policy tests")
        return str(node)

    def compose_config(self, controlled: bool) -> dict[str, object]:
        docker = shutil.which("docker") or shutil.which("docker.exe")
        self.assertIsNotNone(docker, "Docker Compose is required for topology tests")
        docker = str(docker)
        environment = os.environ.copy()
        root = external_path(ROOT, docker)
        fixture = external_path(ROOT / "README.md", docker)
        environment.update(
            {
                "QWEN_PROJECT_ROOT": root,
                "RUNPOD_IDENTITY_FILE": fixture,
                "RUNPOD_KNOWN_HOSTS_FILE": fixture,
                "RUNPOD_API_KEY_FILE": fixture,
                "RUNPOD_SSH_HOST": "93.184.216.34",
                "RUNPOD_SSH_PORT": "22",
                "RUNPOD_SSH_USER": "root",
                "RUNPOD_REMOTE_PORT": "8080",
                "OPENCODE_HTPASSWD_FILE": fixture,
                "OPENCODE_WEB_PORT": "4096",
            }
        )
        command = [
            docker,
            "compose",
            "--project-name",
            "qwen-eval-agent",
            "--file",
            external_path(ROOT / "agent" / "compose.yaml", docker),
        ]
        if controlled:
            command.extend(
                [
                    "--file",
                    external_path(
                        ROOT / "agent" / "compose.controlled-web.yaml", docker
                    ),
                    "--profile",
                    "controlled-web-v1",
                ]
            )
        command.extend(["config", "--format", "json"])
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_address_policy_dynamic_host_deny_and_rebinding_guard(self) -> None:
        node = self.node_executable()
        module_path = (ROOT / "agent" / "controlled-web-proxy.mjs").resolve()
        module_url = module_path.as_uri()
        posix_module_path = module_path.as_posix()
        if node.lower().endswith(".exe") and posix_module_path.startswith("/mnt/"):
            windows_module_path = (
                f"{posix_module_path[5].upper()}:/" + posix_module_path[7:]
            )
            module_url = "file:///" + quote(windows_module_path, safe=":/")
        program = f"""
import {{
  createDenyPolicy,
  isPublicAddress,
  parseConnectAuthority,
  parseHttpTarget,
  resolvePublicTarget,
}} from {json.dumps(module_url)};

const allowed = [
  '1.1.1.1', '8.8.8.8', '93.184.216.35', '2606:4700:4700::1111',
];
const blocked = [
  '0.0.0.0', '10.0.0.1', '100.64.0.1', '127.0.0.1',
  '168.63.129.16', '169.254.169.254', '172.16.0.1', '192.168.0.1',
  '198.18.0.1', '224.0.0.1', '::', '::1', '::ffff:127.0.0.1',
  'fc00::1', 'fe80::1', 'ff02::1', '2001:db8::1', '2620:4f:8000::1',
];
const records = new Map([
  ['cdn.allowed.net', [
    {{ address: '93.184.216.35', family: 4 }},
    {{ address: '2606:4700:4700::1111', family: 6 }},
  ]],
  ['rebind.allowed.net', [
    {{ address: '93.184.216.35', family: 4 }},
    {{ address: '127.0.0.1', family: 4 }},
  ]],
  ['metadata.allowed.net', [{{ address: '169.254.169.254', family: 4 }}]],
  ['pod.runpod.io', [{{ address: '93.184.216.34', family: 4 }}]],
  ['pod-alias.allowed.net', [{{ address: '93.184.216.34', family: 4 }}]],
]);
const lookup = async (host) => {{
  if (!records.has(host)) throw new Error('NXDOMAIN');
  return records.get(host);
}};
const denyPolicy = createDenyPolicy(['pod.runpod.io']);
async function rejected(action) {{
  try {{ await action(); return false; }} catch {{ return true; }}
}}

const publicOnly = await resolvePublicTarget('cdn.allowed.net', {{ lookup, denyPolicy }});
const rebindingBlocked = await rejected(() =>
  resolvePublicTarget('rebind.allowed.net', {{ lookup, denyPolicy }}),
);
const metadataBlocked = await rejected(() =>
  resolvePublicTarget('metadata.allowed.net', {{ lookup, denyPolicy }}),
);
const exactHostBlocked = await rejected(() =>
  resolvePublicTarget('pod.runpod.io', {{ lookup, denyPolicy }}),
);
const hostAddressBlocked = await rejected(() =>
  resolvePublicTarget('pod-alias.allowed.net', {{ lookup, denyPolicy }}),
);
const denyResolutionFailClosed = await rejected(() =>
  resolvePublicTarget('cdn.allowed.net', {{
    lookup: async (host) => host === 'cdn.allowed.net' ? records.get(host) : Promise.reject(),
    denyPolicy,
  }}),
);
const specialNamesBlocked = await Promise.all(
  [
    'localhost', 'service.local', 'host.internal', 'hidden.onion', 'name.alt',
    'x.ip6.arpa', 'host.docker.internal', 'metadata.google.internal',
  ].map((host) => rejected(() => resolvePublicTarget(host, {{ lookup, denyPolicy }}))),
);
const obfuscatedLoopbackBlocked = await Promise.all(
  ['http://127.1/', 'http://0x7f000001/', 'http://0177.0.0.1/'].map((url) =>
    rejected(() => resolvePublicTarget(parseHttpTarget(url).host, {{ lookup, denyPolicy }})),
  ),
);
const portPolicy = {{
  http80: parseHttpTarget('http://93.184.216.35/path').port,
  connect443: parseConnectAuthority('93.184.216.35:443').port,
  http8080Blocked: await rejected(() => parseHttpTarget('http://93.184.216.35:8080/')),
  connect22Blocked: await rejected(() => parseConnectAuthority('93.184.216.35:22')),
}};
console.log(JSON.stringify({{
  allowed: allowed.map(isPublicAddress), blocked: blocked.map(isPublicAddress),
  publicOnly, rebindingBlocked, metadataBlocked, exactHostBlocked,
  hostAddressBlocked, denyResolutionFailClosed, specialNamesBlocked,
  obfuscatedLoopbackBlocked, portPolicy,
}}));
"""
        result = subprocess.run(
            [node, "--input-type=module", "--eval", program],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertTrue(all(evidence["allowed"]))
        self.assertFalse(any(evidence["blocked"]))
        self.assertEqual(len(evidence["publicOnly"]["addresses"]), 2)
        for key in (
            "rebindingBlocked",
            "metadataBlocked",
            "exactHostBlocked",
            "hostAddressBlocked",
            "denyResolutionFailClosed",
        ):
            self.assertTrue(evidence[key], key)
        self.assertTrue(all(evidence["specialNamesBlocked"]))
        self.assertTrue(all(evidence["obfuscatedLoopbackBlocked"]))
        self.assertEqual(evidence["portPolicy"]["http80"], 80)
        self.assertEqual(evidence["portPolicy"]["connect443"], 443)
        self.assertTrue(evidence["portPolicy"]["http8080Blocked"])
        self.assertTrue(evidence["portPolicy"]["connect22Blocked"])

    def test_compose_json_proves_default_offline_and_proxy_only_egress(self) -> None:
        default = self.compose_config(controlled=False)
        controlled = self.compose_config(controlled=True)
        default_services = default["services"]
        controlled_services = controlled["services"]
        self.assertEqual(
            set(default_services), {"model-gateway", "opencode", "ui-proxy"}
        )
        self.assertNotIn("HTTP_PROXY", default_services["opencode"]["environment"])
        self.assertEqual(
            set(default_services["opencode"]["networks"]), {"agent-internal"}
        )
        self.assertEqual(default_services["opencode"]["dns"], ["127.0.0.1"])
        self.assertIn(
            "model-gateway=172.30.240.2",
            default_services["opencode"]["extra_hosts"],
        )
        self.assertEqual(
            default_services["opencode"]["working_dir"],
            "/workspace/agent-workspace",
        )
        self.assertEqual(
            default_services["opencode"]["labels"]["qwen-eval.network-mode"],
            "offline-v1",
        )
        self.assertEqual(
            default_services["opencode"]["environment"][
                "OPENCODE_SERVER_PASSWORD"
            ],
            "nonsecret-internal-v1",
        )
        self.assertEqual(
            set(controlled_services),
            {"controlled-web-proxy", "model-gateway", "opencode", "ui-proxy"},
        )
        self.assertEqual(
            set(controlled_services["opencode"]["networks"]), {"agent-internal"}
        )
        self.assertEqual(
            controlled_services["opencode"]["environment"]["HTTP_PROXY"],
            "http://controlled-web-proxy:3128",
        )
        self.assertEqual(
            controlled_services["opencode"]["labels"]["qwen-eval.network-mode"],
            "controlled-web-v1",
        )
        proxy = controlled_services["controlled-web-proxy"]
        self.assertEqual(
            set(proxy["networks"]), {"agent-internal", "controlled-web-egress"}
        )
        self.assertEqual(
            proxy["environment"], {"CONTROLLED_WEB_DENY_HOSTS": "93.184.216.34"}
        )
        self.assertNotIn("volumes", proxy)
        self.assertNotIn("ports", proxy)
        self.assertTrue(proxy["read_only"])
        self.assertEqual(proxy["cap_drop"], ["ALL"])
        self.assertEqual(
            proxy["labels"]["qwen-eval.network-mode"], "controlled-web-v1"
        )

    def test_native_web_tools_are_approval_gated(self) -> None:
        config = source("opencode.jsonc")
        for action in ("webfetch", "websearch"):
            ask_rule = (
                f'{{ "action": "{action}", "resource": "*", "effect": "ask" }}'
            )
            deny_rule = (
                f'{{ "action": "{action}", "resource": "*", "effect": "deny" }}'
            )
            self.assertIn(ask_rule, config)
            self.assertNotIn(deny_rule, config)

        agents = source("AGENTS.md")
        self.assertIn("`webfetch`", agents)
        self.assertIn("`websearch`", agents)
        self.assertIn("`ask`", agents)
        self.assertIn("`offline-v1`", agents)
        self.assertIn("`controlled-web-v1`", agents)

    def test_http_path_is_parsed_and_framed_instead_of_raw_tunneled(self) -> None:
        proxy = source("agent/controlled-web-proxy.mjs")
        http_handler = proxy[
            proxy.index("async function handleHttpRequest") : proxy.index(
                "async function handleConnect"
            )
        ]
        self.assertIn("http.createServer", proxy)
        self.assertIn("http.request", http_handler)
        self.assertIn("request.pipe(upstreamRequest)", http_handler)
        self.assertNotIn("client.pipe", http_handler)
        self.assertIn("exactly-one-host-header-required", proxy)
        self.assertIn("ambiguous-request-framing", proxy)
        self.assertIn("protocol-upgrade-blocked", proxy)
        self.assertIn("proxy-authorization", proxy)
        self.assertIn("host: candidate.address", proxy)
        self.assertNotIn("host: resolved.host", proxy)

    def test_gui_lifecycle_uses_container_attestation_and_central_cleanup(self) -> None:
        gui = source("scripts/runpod-gui.ps1")
        common = source("scripts/RunPod.Common.psm1")
        controlled_common = source("scripts/ControlledWeb.Common.psm1")
        connect = source("scripts/runpod-connect.ps1")
        switch = source("scripts/runpod-switch.ps1")
        stop = source("scripts/runpod-stop.ps1")
        cleanup_smoke = source("scripts/verify-opencode-cleanup.ps1")

        self.assertIn("[switch]$ControlledWeb", gui)
        self.assertIn("'--profile', 'controlled-web-v1'", gui)
        self.assertIn("Get-ControlledWebRuntimeMode -ExpectedDenyHost", gui)
        self.assertIn("$attestedNetworkMode -ne $requestedNetworkMode", gui)
        self.assertIn("OPENCODE_HTPASSWD_FILE", gui)
        self.assertNotIn("OPENCODE_WEB_PASSWORD =", gui)
        self.assertIn("qwen-eval-controlled-web", common)
        self.assertIn("qwen-eval-agent_controlled-web-egress", common)
        self.assertIn("OpenCodeNetworkMode -NotePropertyValue $null", common)
        self.assertIn("Get-OpenCodeDockerInspectionRecord", common)
        self.assertIn("Docker is required to ownership-check", common)
        self.assertNotIn("index .Config.Labels", common)
        self.assertIn("Preflight every exact target before deleting anything", common)
        self.assertIn("container rm --force $container.Id", common)
        self.assertIn("still exists after cleanup", common)
        self.assertIn("Get-RunPodSessionForLocalCleanup", stop)
        self.assertIn("Assert-RunPodQualifiedSession", stop)
        self.assertIn("Local tunnel actions were skipped fail-closed", stop)
        self.assertIn("foreign rejected without partial deletion", cleanup_smoke)
        self.assertIn("did not fail closed when docker.exe was unavailable", cleanup_smoke)
        self.assertIn("stopped/unqualified session still permits local cleanup", cleanup_smoke)
        self.assertIn("container inspect", controlled_common)
        self.assertNotIn("--format", controlled_common)
        self.assertIn("qwen-eval.network-mode", controlled_common)
        self.assertIn("CONTROLLED_WEB_DENY_HOSTS=$ExpectedDenyHost", controlled_common)
        for wrapper in (connect, switch):
            self.assertIn("[switch]$ControlledWeb", wrapper)
            self.assertIn("[switch]$Offline", wrapper)
            self.assertIn("Get-ControlledWebRuntimeMode -ExpectedDenyHost", wrapper)
            self.assertIn("-ControlledWeb:($requestedNetworkMode", wrapper)

    def test_auth_dns_workdir_and_live_smokes_are_contract_bound(self) -> None:
        compose = source("agent/compose.yaml")
        ui_proxy = source("agent/ui-proxy.conf")
        isolation = source("scripts/verify-agent-isolation.ps1")
        controlled_smoke = source("scripts/verify-controlled-web.ps1")
        ignore = source(".gitignore")

        self.assertIn("auth_basic_user_file /run/secrets/opencode_htpasswd", ui_proxy)
        self.assertIn("location = /healthz", ui_proxy)
        self.assertIn("OPENCODE_SERVER_PASSWORD: nonsecret-internal-v1", compose)
        self.assertIn(
            'proxy_set_header Authorization "Basic b3BlbmNvZGU6bm9uc2VjcmV0LWludGVybmFsLXYx"',
            ui_proxy,
        )
        self.assertIn("dns:\n      - 127.0.0.1", compose)
        self.assertIn("working_dir: /workspace/agent-workspace", compose)
        self.assertIn("agent-workspace/*", ignore)
        self.assertIn("!agent-workspace/.gitkeep", ignore)
        self.assertTrue((ROOT / "agent-workspace" / ".gitkeep").is_file())
        for script in (isolation, controlled_smoke):
            self.assertIn("ExtServers: \\[127\\.0\\.0\\.1\\]", script)
            self.assertIn("getent hosts example.com", script)
            self.assertIn("model-gateway", script)
        for evidence in (
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://168.63.129.16/",
            "https://93.184.216.34/",
            "http://93.184.216.35:8080/",
            "https://93.184.216.35:444/",
        ):
            self.assertIn(evidence, controlled_smoke)


if __name__ == "__main__":
    unittest.main()
