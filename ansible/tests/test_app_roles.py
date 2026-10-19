import configparser
import base64
from pathlib import Path
import shlex
import unittest

from ansible.plugins.filter.core import FilterModule
from ansible.plugins.test.core import TestModule
from jinja2 import Environment, StrictUndefined
import yaml


ANSIBLE_DIR = Path(__file__).resolve().parents[1]
ROLES_DIR = ANSIBLE_DIR / "roles"
APP_ROLES = ("rclone-onedrive", "immich", "papra", "netbird", "netbird-client",
             "bifrost", "open-webui")


def load_yaml(path):
    return yaml.safe_load(path.read_text())


def defaults(role):
    values = load_yaml(ROLES_DIR / role / "defaults/main.yml")
    environment = Environment(undefined=StrictUndefined)
    for key, value in values.items():
        if isinstance(value, str) and "{{" in value:
            values[key] = environment.from_string(value).render(values)
    return values


def render(role, template, **overrides):
    environment = Environment(
        undefined=StrictUndefined, keep_trailing_newline=True,
        trim_blocks=True, lstrip_blocks=True,
    )
    environment.filters.update(FilterModule().filters())
    values = defaults(role)
    values.update(overrides)
    source = (ROLES_DIR / role / "templates" / template).read_text()
    return environment.from_string(source).render(values)


def unit(text):
    parsed = configparser.ConfigParser(strict=False, interpolation=None)
    parsed.read_string(text)
    return parsed


class AppRolesTests(unittest.TestCase):
    def test_yaml_and_handler_references(self):
        load_yaml(ANSIBLE_DIR / "local.yml")
        for role in APP_ROLES:
            with self.subTest(role=role):
                tasks = load_yaml(ROLES_DIR / role / "tasks/main.yml")
                for task in list(tasks):
                    if "ansible.builtin.include_tasks" in task:
                        tasks.extend(load_yaml(ROLES_DIR / role / "tasks" /
                                               task["ansible.builtin.include_tasks"]))
                    tasks.extend(task.get("block", []))
                    tasks.extend(task.get("always", []))
                handlers = load_yaml(ROLES_DIR / role / "handlers/main.yml")
                handler_names = {handler["name"] for handler in handlers}
                for task in tasks:
                    notifications = task.get("notify", [])
                    if isinstance(notifications, str):
                        notifications = [notifications]
                    self.assertTrue(set(notifications) <= handler_names)
                    module = task.get("ansible.builtin.template")
                    if module:
                        overrides = {}
                        if role == "rclone-onedrive":
                            overrides["item"] = defaults(role)["rclone_onedrive_mounts"][0]
                        if role == "open-webui":
                            overrides["open_webui_version"] = "0.11.4"
                        render(role, module["src"], **overrides)

    def test_immich_compose_preserves_storage_and_images(self):
        compose = yaml.safe_load(render("immich", "docker-compose.yml.j2"))
        services = compose["services"]
        self.assertEqual(len(services), 4)
        self.assertEqual(services["immich-server"]["volumes"], ["${UPLOAD_LOCATION}:/data"])
        self.assertEqual(services["database"]["volumes"], [
            "${DB_DATA_LOCATION}:/var/lib/postgresql/data",
        ])
        self.assertIn("@sha256:", services["database"]["image"])
        self.assertIn("@sha256:", services["redis"]["image"])
        self.assertEqual(compose["networks"]["default"], {
            "name": "immich_default", "external": True,
        })

    def test_immich_service_requires_mounted_media(self):
        service = unit(render("immich", "immich-compose.service.j2"))
        self.assertEqual(service["Unit"]["Requires"], "rclone-media.service")
        self.assertEqual(service["Service"]["ExecStartPre"], "/usr/bin/mountpoint -q /mnt/media")
        self.assertEqual(service["Service"]["Type"], "oneshot")
        self.assertEqual(service["Service"]["ExecStop"], "/usr/bin/podman compose down")

    def test_immich_environment_escaping(self):
        text = render("immich", "immich.env.j2", immich_db_password="a$b#c'd\\e")
        self.assertIn("DB_PASSWORD='a$b#c\\'d\\\\e'\n", text)
        self.assertIn('IMMICH_VERSION="v3"\n', text)
        self.assertIn('HTTP_PROXY="http://10.89.0.1:8888"\n', text)

    def test_papra_quadlet_keeps_secrets_out_of_unit(self):
        text = render("papra", "papra.container.j2",
                      papra_auth_secret="test-auth", papra_document_encryption_keys="test-key")
        self.assertNotIn("test-auth", text)
        self.assertNotIn("test-key", text)
        self.assertIn("EnvironmentFile=/etc/papra/papra.env\n", text)
        self.assertIn("Requires=rclone-onedrive.service\n", text)
        self.assertIn("Volume=/mnt/onedrive/Papra_Docs:/papra-docs:U\n", text)
        self.assertIn("Volume=/var/lib/papra-db:/papra-db:U\n", text)
        self.assertIn("DOCUMENT_STORAGE_ENCRYPTION_IS_ENABLED=true", text)
        self.assertIn("DOCUMENTS_OCR_LANGUAGES[0]=eng", text)
        self.assertNotIn("DOCUMENTS_OCR_LANGUAGES[1]", text)
        self.assertEqual(defaults("papra")["papra_ocr_languages"], ["eng"])
        service = unit(text)
        self.assertEqual(service["Install"]["WantedBy"], "multi-user.target")
        self.assertEqual(service["Service"]["ExecStartPre"], "/usr/bin/mountpoint -q /mnt/onedrive")

    def test_rclone_units_wait_for_mount_readiness(self):
        for mount in defaults("rclone-onedrive")["rclone_onedrive_mounts"]:
            with self.subTest(mount=mount["name"]):
                text = render("rclone-onedrive", "rclone-mount.service.j2", item=mount)
                service = unit(text)
                self.assertEqual(service["Service"]["Type"], "notify")
                self.assertIn(f"rclone mount {mount['remote']} {mount['path']}", text)
                self.assertIn("--allow-other", text)
                self.assertIn("--vfs-cache-mode=full", text)
                self.assertEqual(text.count("--vfs-read-ahead="), 1)
                self.assertIn("--config=/var/lib/rclone/.config/rclone/rclone.conf", text)
                self.assertEqual(service["Unit"]["RequiresMountsFor"],
                                 "/mnt/arch-var/rclone-cache-onedrive")

    def test_existing_oauth_tokens_are_never_overwritten(self):
        tasks = load_yaml(ROLES_DIR / "rclone-onedrive/tasks/main.yml")
        copies = [task for task in tasks if "ansible.builtin.copy" in task]
        self.assertEqual(len(copies), 1)
        self.assertIs(copies[0]["ansible.builtin.copy"]["force"], False)
        self.assertIs(copies[0]["no_log"], True)
        self.assertIs(copies[0]["diff"], False)

    def test_credentials_are_required_only_for_missing_configs(self):
        cases = (
            ("rclone-onedrive", "rclone_onedrive_config_stat",
             {"rclone_onedrive_config_content": "[onedrive_media]\ntype = onedrive\n"}),
            ("immich", "immich_env_stat", {"immich_db_password": "test-password"}),
            ("papra", "papra_env_stat",
             {"papra_auth_secret": "test-auth", "papra_document_encryption_keys": "test-key"}),
        )
        environment = Environment(undefined=StrictUndefined)
        for role, stat_variable, secrets in cases:
            tasks = load_yaml(ROLES_DIR / role / "tasks/main.yml")
            conditions = next(task["ansible.builtin.assert"]["that"] for task in tasks
                              if "ansible.builtin.assert" in task)

            def accepted(exists, overrides):
                values = {**defaults(role), stat_variable: {"stat": {"exists": exists}}, **overrides}
                return all(environment.compile_expression(condition)(values)
                           for condition in conditions)

            with self.subTest(role=role):
                self.assertFalse(accepted(False, {}))
                self.assertTrue(accepted(True, {}))
                self.assertTrue(accepted(False, secrets))
                if role == "papra":
                    self.assertFalse(accepted(False, {"papra_auth_secret": "test-auth"}))

    def test_proxy_firewall_rule_is_in_input_chain(self):
        text = render("networking-hardening", "nftables.conf.j2")
        input_chain, rest = text.split("chain output", 1)
        rule = 'iifname "podman1" ip saddr 10.89.0.0/24 tcp dport 8888 accept'
        self.assertIn(rule, input_chain)
        self.assertNotIn(rule, rest)


class NetBirdRoleTests(unittest.TestCase):
    def test_server_config_uses_embedded_idp_and_loopback_backend(self):
        key = base64.b64encode(bytes(range(32))).decode()
        text = render(
            "netbird", "config.yaml.j2", netbird_relay_auth_secret='quoted"secret',
            netbird_store_encryption_key=key, netbird_session_cookie_encryption_key=key,
        )
        config = yaml.safe_load(text)["server"]
        self.assertEqual(config["authSecret"], 'quoted"secret')
        self.assertEqual(config["listenAddress"], "127.0.0.1:8085")
        self.assertEqual(config["healthcheckAddress"], "127.0.0.1:9001")
        self.assertEqual(config["exposedAddress"], "https://netbird.manolito.wanip.ch:443")
        self.assertEqual(config["auth"]["issuer"], "https://netbird.manolito.wanip.ch/oauth2")
        self.assertEqual(config["auth"]["dashboardRedirectURIs"], [
            "https://netbird.manolito.wanip.ch/nb-auth",
            "https://netbird.manolito.wanip.ch/nb-silent-auth",
        ])
        self.assertEqual(config["auth"]["cliRedirectURIs"], ["http://localhost:53000/"])
        self.assertEqual(config["store"], {"engine": "sqlite", "encryptionKey": key})
        self.assertEqual(config["auth"]["sessionCookieEncryptionKey"], key)
        self.assertEqual(config["reverseProxy"]["trustedHTTPProxies"], ["127.0.0.1/32"])
        self.assertEqual(config["stunPorts"], [3478])

    def test_dashboard_environment_is_shell_compatible_and_public_only(self):
        lines = render("netbird", "dashboard.env.j2").splitlines()
        values = dict(shlex.split(line)[0].split("=", 1) for line in lines)
        self.assertEqual(values["NETBIRD_MGMT_API_ENDPOINT"], "https://netbird.manolito.wanip.ch")
        self.assertEqual(values["AUTH_AUTHORITY"], "https://netbird.manolito.wanip.ch/oauth2")
        self.assertEqual(values["AUTH_CLIENT_ID"], "netbird-dashboard")
        self.assertEqual(values["AUTH_AUDIENCE"], "netbird-dashboard")
        self.assertEqual(values["AUTH_SUPPORTED_SCOPES"], "openid profile email groups")
        self.assertEqual(values["AUTH_CLIENT_SECRET"], "")
        self.assertEqual(values["OUTPUT_DIR"], "/var/lib/netbird-dashboard")

    def test_caddy_routes_cover_grpc_websockets_api_auth_and_static_pages(self):
        text = render("netbird", "netbird.Caddyfile.j2")
        for path in (
            "/signalexchange.SignalExchange/*", "/management.ManagementService/*",
            "/management.ProxyService/*", "/relay*", "/ws-proxy/*", "/api/*", "/oauth2/*",
        ):
            self.assertIn(path, text)
        self.assertIn("reverse_proxy h2c://127.0.0.1:8085", text)
        self.assertIn("reverse_proxy 127.0.0.1:8085", text)
        self.assertIn("root * /var/lib/netbird-dashboard", text)
        self.assertIn("try_files {path} {path}.html {path}/ /index.html", text)
        self.assertNotIn("handle_path", text)

    def test_native_service_uses_unprivileged_user_and_proxy(self):
        text = render("netbird", "netbird-server.conf.j2")
        self.assertIn("User=netbird\n", text)
        self.assertIn("Group=netbird\n", text)
        self.assertIn("UMask=0077\n", text)
        self.assertIn("ExecStart=/usr/bin/netbird-server --config /etc/netbird-server/config.yaml", text)
        self.assertIn('Environment="HTTPS_PROXY=http://127.0.0.1:8888"', text)

    def test_netbird_secrets_and_hostname_validation(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/main.yml")
        environment = Environment(undefined=StrictUndefined)
        environment.tests.update(TestModule().tests())
        environment.filters.update(FilterModule().filters())
        validation = tasks[0]["ansible.builtin.assert"]["that"]
        secret_tasks = load_yaml(ROLES_DIR / "netbird/tasks/secrets.yml")
        readiness = next(task["ansible.builtin.set_fact"]["netbird_secrets_ready"]
                         for task in secret_tasks
                         if "netbird_secrets_ready" in task.get("ansible.builtin.set_fact", {}))
        readiness = environment.compile_expression(readiness.strip()[2:-2].strip())
        secrets = next(task["ansible.builtin.assert"]["that"] for task in tasks
                       if task["name"] == "Require persistent NetBird secrets or explicit staging")
        values = defaults("netbird")
        values["netbird_secrets_ready"] = readiness(values)
        self.assertTrue(all(environment.compile_expression(c)(values) for c in validation))
        self.assertFalse(all(environment.compile_expression(c)(values) for c in secrets))
        staged = {**values, "netbird_allow_unconfigured": True}
        self.assertTrue(all(environment.compile_expression(c)(staged) for c in secrets))
        partial = {**staged, "netbird_relay_auth_secret": "partial"}
        self.assertFalse(all(environment.compile_expression(c)(partial) for c in secrets))
        key = base64.b64encode(bytes(range(32))).decode()
        values.update(netbird_relay_auth_secret=key, netbird_store_encryption_key=key,
                      netbird_session_cookie_encryption_key=key)
        values["netbird_secrets_ready"] = readiness(values)
        self.assertTrue(all(environment.compile_expression(c)(values) for c in secrets))
        for overrides in (
            {"netbird_domain": "https://invalid.example"},
            {"netbird_domain": "bad.example\ninjected"},
            {"netbird_listen_address": "0.0.0.0:8085"},
            {"netbird_listen_address": "127.0.0.1:99999"},
            {"netbird_dashboard_dir": "/var/lib"},
            {"netbird_dashboard_dir": "/var/lib/netbird-dashboard/../../etc"},
        ):
            with self.subTest(overrides=overrides):
                self.assertFalse(all(environment.compile_expression(c)({**values, **overrides})
                                     for c in validation))

    def test_stun_firewall_access_is_opt_in(self):
        default = render("networking-hardening", "nftables.conf.j2")
        enabled = render("networking-hardening", "nftables.conf.j2",
                         networking_hardening_extra_udp_ports=[3478])
        rule = "udp dport 3478 accept"
        self.assertNotIn(rule, default)
        self.assertIn(rule, enabled.split("chain output", 1)[0])
        self.assertEqual(enabled.count(rule), 1)

    def test_service_checks_are_skipped_only_when_package_is_missing(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/main.yml")
        handlers = load_yaml(ROLES_DIR / "netbird/handlers/main.yml")
        service_tasks = [
            task for task in tasks + handlers
            if task.get("ansible.builtin.systemd", {}).get("name") == "netbird-server.service"
        ]
        self.assertEqual(len(service_tasks), 2)
        environment = Environment(undefined=StrictUndefined)
        for task in service_tasks:
            condition = environment.compile_expression(task["when"])
            for check_mode, rc, expected in ((True, 1, False), (True, 0, True),
                                            (False, 1, True), (False, 0, True)):
                with self.subTest(task=task["name"], check_mode=check_mode, rc=rc):
                    self.assertEqual(condition(
                        ansible_check_mode=check_mode,
                        netbird_secrets_ready=True,
                        netbird_package_query={"results": [{"item": "netbird-server", "rc": rc}]},
                    ), expected)

    def test_unconfigured_staging_never_starts_backend(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/main.yml")
        handlers = load_yaml(ROLES_DIR / "netbird/handlers/main.yml")
        handler = next(task for task in handlers if task["name"] == "Restart NetBird server")
        environment = Environment(undefined=StrictUndefined)
        self.assertFalse(environment.compile_expression(handler["when"])(
            netbird_secrets_ready=False, ansible_check_mode=False,
        ))
        service = next(task["ansible.builtin.systemd"] for task in tasks
                       if task.get("ansible.builtin.systemd", {}).get("name") ==
                       "netbird-server.service")
        environment.filters.update(FilterModule().filters())
        self.assertEqual(environment.from_string(service["state"]).render(
            netbird_secrets_ready=False), "stopped")
        seed = next(task["ansible.builtin.template"] for task in tasks
                    if task.get("ansible.builtin.template", {}).get("src") == "secrets.yml.j2")
        self.assertFalse(seed["force"])
        self.assertEqual(seed["mode"], "0600")

    def test_stun_rule_is_persistent_and_before_input_drop(self):
        firewall = render("networking-hardening", "nftables.conf.j2")
        include = 'include "/etc/nftables.d/*-input.nft"'
        self.assertIn(include, firewall.split("chain output", 1)[0])
        self.assertLess(firewall.index(include), firewall.index('log prefix "nft-drop-in: " drop'))
        self.assertEqual(render("netbird", "stun-input.nft.j2").strip(),
                         'udp dport 3478 counter accept comment "ansible-netbird-stun"')
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/firewall.yml")
        self.assertFalse(any("ansible.builtin.systemd" in task for task in tasks))
        command = tasks[-1]["ansible.builtin.command"]["argv"]
        self.assertEqual(command[:6], ["/usr/bin/nft", "insert", "rule", "inet", "filter", "input"])
        self.assertIn("position", command)
        self.assertNotIn("flush", command)

    def test_live_stun_rule_detection_is_idempotent_and_handles_port_changes(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/firewall.yml")
        detection = next(task["ansible.builtin.set_fact"] for task in tasks
                         if "ansible.builtin.set_fact" in task)
        environment = Environment(undefined=StrictUndefined)
        environment.filters.update(FilterModule().filters())
        live = (
            '\t\tudp dport 3478 counter packets 12 bytes 345 accept '
            'comment "ansible-netbird-stun" # handle 42\n'
            '\t\tlog prefix "nft-drop-in: " drop # handle 18\n'
        )
        values = {"netbird_live_input": {"stdout": live}}
        rules_expression = detection["netbird_live_stun_rules"].strip()[2:-2].strip()
        drop_expression = detection["netbird_live_drop_handles"].strip()[2:-2].strip()
        rules = environment.compile_expression(rules_expression)(values)
        self.assertEqual(rules, [("3478", "42")])
        self.assertEqual(environment.compile_expression(drop_expression)(values), ["18"])
        should_insert = environment.compile_expression(tasks[-1]["when"])
        self.assertFalse(should_insert(netbird_stun_port=3478, netbird_live_stun_rules=rules))
        self.assertTrue(should_insert(netbird_stun_port=53478, netbird_live_stun_rules=rules))

    def test_aur_builds_restore_the_original_update_timer_state(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/main.yml")
        build = next(task for task in tasks if "block" in task)
        self.assertIn("always", build)
        restore = build["always"][0]
        self.assertEqual(restore["ansible.builtin.systemd"], {
            "name": "pacman-auto-update.timer", "state": "started",
        })
        environment = Environment(undefined=StrictUndefined)
        self.assertTrue(environment.compile_expression(restore["when"])(
            netbird_update_timer={"stdout": "active"}))
        self.assertFalse(environment.compile_expression(restore["when"])(
            netbird_update_timer={"stdout": "inactive"}))
        pause = next(task for task in build["block"] if "ansible.builtin.systemd" in task)
        self.assertEqual(pause["ansible.builtin.systemd"]["state"], "stopped")
        install = next(task for task in build["block"]
                       if task["name"] == "Install NetBird server and dashboard from AUR using yay")
        self.assertEqual(install["become_user"], "{{ netbird_aur_builder_user }}")
        self.assertEqual(install["ansible.builtin.command"]["argv"],
                         "{{ ['/usr/bin/yay', '-S', '--noconfirm', '--needed'] + netbird_packages }}")

    def test_raw_encryption_keys_are_encoded_without_changing_key_material(self):
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/secrets.yml")
        normalization = next(task for task in tasks
                             if task["name"] ==
                             "Encode raw 32-byte encryption keys for the server configuration")
        environment = Environment(undefined=StrictUndefined)
        environment.filters.update(FilterModule().filters())
        raw = "test-key-with-special-characters"
        self.assertEqual(len(raw), 32)
        expected = base64.b64encode(raw.encode()).decode()
        for name, expression in normalization["ansible.builtin.set_fact"].items():
            with self.subTest(key=name):
                result = environment.from_string(expression).render({name: raw})
                self.assertEqual(result, expected)
                self.assertEqual(base64.b64decode(result), raw.encode())
                self.assertEqual(environment.from_string(expression).render({name: expected}),
                                 expected)
        self.assertTrue(normalization["no_log"])

    def test_initial_geolocation_database_download_is_allowed(self):
        self.assertIn("pkgs.netbird.io", defaults("netbird")["netbird_proxy_domains"])


class NetBirdClientRoleTests(unittest.TestCase):
    def test_client_uses_aur_binary_package_as_unprivileged_builder(self):
        values = defaults("netbird-client")
        self.assertEqual(values["netbird_client_package_name"], "netbird-bin")
        self.assertEqual(values["netbird_client_service_name"], "netbird@client.service")
        tasks = load_yaml(ROLES_DIR / "netbird-client/tasks/main.yml")
        install = next(task for task in tasks
                       if task["name"] == "Install NetBird client binary from AUR using yay")
        self.assertEqual(install["ansible.builtin.command"]["argv"], [
            "/usr/bin/yay", "-S", "--noconfirm", "--needed", "{{ netbird_client_package_name }}",
        ])
        self.assertEqual(install["become_user"], "{{ netbird_client_aur_builder_user }}")
        self.assertEqual(install["when"], "netbird_client_package_query.rc == 1")

    def test_client_does_not_share_server_directories(self):
        text = render("netbird-client", "client.conf.j2")
        service = unit(text)["Service"]
        for key in ("CacheDirectory", "ConfigurationDirectory", "LogsDirectory",
                    "RuntimeDirectory", "StateDirectory"):
            self.assertIn(f"{key}=\n{key}=netbird-client\n", text)
            self.assertEqual(service[key], "netbird-client")
        self.assertIn('Environment="NB_STATE_DIR=/var/lib/netbird-client"', text)
        self.assertIn("--config /etc/netbird-client/config.json", text)
        self.assertIn("--log-file /var/log/netbird-client/client.log", text)
        self.assertIn("--daemon-addr unix:///var/run/netbird-client/netbird.sock", text)
        self.assertIn("User=netbird-client", text)
        self.assertIn("AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE", text)
        self.assertIn("UMask=0077", text)

    def test_client_preserves_enrollment_and_never_runs_up(self):
        tasks = load_yaml(ROLES_DIR / "netbird-client/tasks/main.yml")
        for task in tasks:
            command = task.get("ansible.builtin.command", {}).get("argv", [])
            self.assertNotIn("up", command)
            self.assertNotIn("down", command)
            self.assertNotIn("--setup-key", command)
            template = task.get("ansible.builtin.template", {})
            self.assertFalse(template.get("dest", "").endswith("config.json"))
        self.assertNotIn(" up ", render("netbird-client", "client.conf.j2"))


class NetBirdHardeningTests(unittest.TestCase):
    def test_reload_preserves_dynamic_tables_and_includes_service_chains(self):
        text = render("networking-hardening", "nftables.conf.j2")
        self.assertNotIn("flush ruleset", text)
        self.assertIn("destroy table inet filter", text)
        for chain in ("input", "output", "forward"):
            self.assertIn(f'include "/etc/nftables.d/*-{chain}.nft"', text)
        self.assertIn("udp dport 443 accept", text)
        handlers = load_yaml(ROLES_DIR / "networking-hardening/handlers/main.yml")
        reload = next(t for t in handlers if t["name"] == "Reload nftables")
        self.assertEqual(reload["ansible.builtin.command"]["argv"],
                         ["/usr/bin/nft", "--file", "/etc/nftables.conf"])

    def test_udp_exceptions_are_uid_scoped_or_fixed_kernel_port(self):
        text = render("netbird-client", "netbird-client-output.nft.j2")
        rules = [line for line in text.splitlines() if line.startswith("oifname")]
        self.assertEqual(len(rules), 3)
        for rule in rules:
            self.assertIn('oifname "eth0" meta skuid ', rule)
            if "meta skuid 0 " in rule:
                self.assertIn("udp sport 51821", rule)
            else:
                self.assertIn('meta skuid "netbird-client"', rule)
                self.assertTrue("tcp dport 443" in rule or "meta l4proto udp" in rule)
        changed = render("netbird-client", "netbird-client-output.nft.j2",
                         netbird_client_wireguard_port=51999)
        self.assertIn("udp sport 51999", changed)
        self.assertNotIn("51821", changed)
        forward = render("netbird-client", "netbird-client-forward.nft.j2")
        self.assertIn("ct status dnat", forward)
        self.assertIn("ct state established,related", forward)

    def test_caddy_idle_timeout_and_ipv6_fix_do_not_broaden_admin_policy(self):
        import re
        tasks = load_yaml(ROLES_DIR / "netbird/tasks/main.yml")
        timeout = next(t["ansible.builtin.blockinfile"] for t in tasks
                       if t.get("ansible.builtin.blockinfile", {}).get("marker", "").endswith(
                           "ANSIBLE NETBIRD GRPC TIMEOUT"))
        self.assertIn("read_body_idle", timeout["block"])
        self.assertIn("write_idle", timeout["block"])
        for role in ("netbird", "caddy"):
            role_tasks = load_yaml(ROLES_DIR / role / "tasks/main.yml")
            fix = next(t["ansible.builtin.replace"] for t in role_tasks
                       if "remote_ip" in t.get("ansible.builtin.replace", {}).get("regexp", ""))
            admin = "      not remote_ip 10.0.0.0/8 127.0.0.1"
            self.assertEqual(re.sub(fix["regexp"], fix["replace"], admin), admin)
            app = "      not remote_ip 10.0.0.0/8 100.64.0.0/10"
            updated = re.sub(fix["regexp"], fix["replace"], app)
            self.assertEqual(updated, app + " fc00::/7")
            self.assertEqual(re.sub(fix["regexp"], fix["replace"], updated), updated)

    def test_socket_persistence_and_dns_authorization_are_service_scoped(self):
        tasks = load_yaml(ROLES_DIR / "netbird-client/tasks/main.yml")
        tmpfiles = next(t["ansible.builtin.copy"] for t in tasks
                        if t.get("ansible.builtin.copy", {}).get("dest") ==
                        "/etc/tmpfiles.d/netbird-client.conf")
        self.assertIn("/run/netbird.sock", tmpfiles["content"])
        self.assertIn("/run/netbird-client/netbird.sock", tmpfiles["content"])
        text = render("netbird-client", "50-netbird-client-resolved.rules.j2")
        self.assertIn('subject.user === "netbird-client"', text)
        self.assertIn("org.freedesktop.resolve1.set-dns-servers", text)
        self.assertNotIn("org.freedesktop.systemd1", text)
        self.assertNotIn("sudo", text)

    def test_live_userspace_rule_condition_is_boolean_and_idempotent(self):
        tasks = load_yaml(ROLES_DIR / "netbird-client/tasks/firewall.yml")
        task = next(t for t in tasks if t["name"] ==
                    "Allow userspace UDP only for the dedicated NetBird client UID")
        condition = Environment().compile_expression(task["when"])
        self.assertIs(condition(netbird_client_limited_userspace_udp_handles=[],
                                netbird_client_live_output='comment "ansible-netbird-client-userspace"'), False)
        self.assertIs(condition(netbird_client_limited_userspace_udp_handles=[],
                                netbird_client_live_output=""), True)
        self.assertIs(condition(netbird_client_limited_userspace_udp_handles=["73"],
                                netbird_client_live_output='comment "ansible-netbird-client-userspace"'), True)


class AiAppRoleTests(unittest.TestCase):
    def test_bifrost_quadlet_is_pinned_and_loopback_only(self):
        values = defaults("bifrost")
        self.assertEqual(values["bifrost_image"], "docker.io/maximhq/bifrost:v2.3.1")
        text = render("bifrost", "bifrost.container.j2")
        container = unit(text)["Container"]
        self.assertEqual(container["Network"], "host")
        self.assertEqual(container["User"], "1000:0")
        self.assertEqual(container["Volume"], "/var/lib/bifrost:/app/data:U")
        self.assertIn("Environment=APP_HOST=127.0.0.1\n", text)
        self.assertIn("Environment=APP_PORT=8086\n", text)
        self.assertIn("Environment=HTTPS_PROXY=http://127.0.0.1:8888\n", text)
        self.assertEqual(unit(text)["Install"]["WantedBy"], "multi-user.target")
        self.assertNotIn("PublishPort", text)
        self.assertEqual(container["EnvironmentFile"], "/etc/bifrost/secret.env")
        self.assertNotIn("BIFROST_SETUP_TOKEN=", text)

    def test_bifrost_setup_token_is_private_persistent_and_verified(self):
        tasks = load_yaml(ROLES_DIR / "bifrost/tasks/main.yml")
        generate = next(task for task in tasks
                        if task["name"] == "Generate Bifrost setup token on the server")
        self.assertTrue(generate["no_log"])
        self.assertIn("secrets.token_hex(32)", generate["ansible.builtin.command"]["argv"][-1])
        self.assertEqual(generate["when"],
                         "not bifrost_secret_stat.stat.exists and not ansible_check_mode")
        seed = next(task for task in tasks if "ansible.builtin.copy" in task)
        self.assertFalse(seed["ansible.builtin.copy"]["force"])
        self.assertEqual(seed["ansible.builtin.copy"]["mode"], "0600")
        self.assertEqual(seed["ansible.builtin.copy"]["owner"], "root")
        self.assertTrue(seed["no_log"])
        self.assertFalse(seed["diff"])
        self.assertEqual(seed["notify"], "Restart Bifrost")
        verification = next(task for task in tasks
                            if task["name"] ==
                            "Verify Bifrost dashboard setup is available or already completed")
        self.assertIn("setup_token_configured", verification["failed_when"])
        self.assertIn("is_auth_enabled", verification["failed_when"])
        backup = next(task for task in tasks if "ansible.builtin.lineinfile" in task)
        self.assertIn("/etc/bifrost", backup["loop"])

    def test_open_webui_overrides_launcher_port_and_ollama_dependency(self):
        text = render("open-webui", "service.conf.j2", open_webui_version="0.11.4")
        service = unit(text)
        self.assertEqual(service["Unit"]["Requires"], "")
        self.assertNotIn("ollama.service", text)
        self.assertIn("open-webui@0.11.4 serve --host 127.0.0.1 --port 3000",
                      service["Service"]["ExecStart"])
        self.assertEqual(service["Service"]["EnvironmentFile"], "/etc/open-webui/secret.env")
        self.assertIn("ExecStart=\nExecStart=", text)

    def test_open_webui_seeds_bifrost_and_disables_public_signup(self):
        text = render("open-webui", "environment.j2")
        self.assertIn("OPENAI_API_BASE_URL=http://127.0.0.1:8086/openai/v1\n", text)
        self.assertIn("WEBUI_AUTH=true\n", text)
        self.assertIn("ENABLE_SIGNUP=false\n", text)
        self.assertIn("ENABLE_OLLAMA_API=false\n", text)
        self.assertIn("WEBUI_ADMIN_EMAIL=admin@chat.manolito.wanip.ch\n", text)
        self.assertIn("NO_PROXY=localhost,127.0.0.1,::1\n", text)
        self.assertIn("UV_TORCH_BACKEND=cpu\n", text)
        self.assertNotIn("UV_INDEX=", text)
        self.assertNotIn("WEBUI_ADMIN_PASSWORD=", text)
        self.assertNotIn("WEBUI_SECRET_KEY=", text)
        changed = render("open-webui", "environment.j2",
                         open_webui_bifrost_url="http://127.0.0.1:9000/openai/v1")
        self.assertIn("OPENAI_API_BASE_URL=http://127.0.0.1:9000/openai/v1\n", changed)

    def test_caddy_streaming_route_is_validated_and_preserves_other_sites(self):
        text = render("open-webui", "open-webui.Caddyfile.j2")
        self.assertIn("chat.manolito.wanip.ch {", text)
        self.assertIn("reverse_proxy 127.0.0.1:3000", text)
        self.assertIn("flush_interval -1", text)
        self.assertNotIn("handle_path", text)
        tasks = load_yaml(ROLES_DIR / "open-webui/tasks/main.yml")
        block = next(task["ansible.builtin.blockinfile"] for task in tasks
                     if "ansible.builtin.blockinfile" in task)
        self.assertIn("caddy validate", block["validate"])
        self.assertEqual(block["marker"], "# {mark} ANSIBLE OPEN WEBUI")
        self.assertIn("acme.zerossl.com", defaults("open-webui")["open_webui_proxy_domains"])
        self.assertIn("getbifrost.ai", defaults("bifrost")["bifrost_proxy_domains"])
        self.assertIn("mdgcorpfoundry.services.ai.azure.com",
                      defaults("bifrost")["bifrost_proxy_domains"])

    def test_chat_caddy_restricts_all_paths_to_lan_and_netbird(self):
        text = render("open-webui", "open-webui.Caddyfile.j2")
        self.assertIn(
            "not remote_ip 192.168.0.0/16 172.16.0.0/12 10.0.0.0/8 "
            "100.64.0.0/10 fc00::/7\n", text,
        )
        self.assertIn("path /*\n", text)
        deny = 'respond @insecureadmin "Access Denied" 403'
        self.assertIn(deny, text)
        self.assertLess(text.index(deny), text.index("reverse_proxy"))
        self.assertNotIn("tls internal", text)
        self.assertNotIn("X-Forwarded-For", text)

    def test_secrets_are_generated_on_target_and_never_replaced(self):
        tasks = load_yaml(ROLES_DIR / "open-webui/tasks/main.yml")
        seed = next(task for task in tasks if "ansible.builtin.copy" in task)
        self.assertFalse(seed["ansible.builtin.copy"]["force"])
        self.assertEqual(seed["ansible.builtin.copy"]["mode"], "0600")
        self.assertTrue(seed["no_log"])
        self.assertFalse(seed["diff"])
        generation = next(task for task in tasks
                          if task["name"] == "Generate persistent Open WebUI bootstrap credentials")
        self.assertTrue(generation["no_log"])
        self.assertIn("not open_webui_secret_stat.stat.exists", generation["when"])

    def test_shared_aur_installer_restores_update_timer_on_failure(self):
        tasks = load_yaml(ROLES_DIR / "yay-bin/tasks/install-aur.yml")
        build = next(task for task in tasks if "block" in task)
        install = next(task for task in build["block"] if "become_user" in task)
        self.assertEqual(install["become_user"], "{{ yay_bin_aur_builder_user }}")
        self.assertEqual(build["when"], "aur_package_query.rc == 1")
        self.assertEqual(build["always"][0]["ansible.builtin.systemd"]["state"], "started")
        self.assertIn("aur_update_timer.stdout", build["always"][0]["when"])
        for role in ("open-webui",):
            tasks = load_yaml(ROLES_DIR / role / "tasks/main.yml")
            includes = [task["ansible.builtin.include_role"] for task in tasks
                        if "ansible.builtin.include_role" in task]
            self.assertEqual(includes, [{"name": "yay-bin", "tasks_from": "install-aur"}])


if __name__ == "__main__":
    unittest.main()
