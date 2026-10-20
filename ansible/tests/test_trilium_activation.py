"""Focused tests for the native Trilium socket-activation role."""
import re
import unittest

from test_app_roles import ROLES_DIR, defaults, load_yaml, render, unit


class TriliumActivationTests(unittest.TestCase):
    def test_templates_and_lifecycle(self):
        socket = unit(render("trilium-next-server", "trilium-proxy.socket.j2"))
        proxy_text = render("trilium-next-server", "trilium-proxy.service.j2")
        proxy = unit(proxy_text)
        self.assertEqual(socket["Socket"]["ListenStream"], "127.0.0.1:8080")
        self.assertEqual(socket["Install"]["WantedBy"], "sockets.target")
        self.assertEqual(proxy["Unit"]["Requires"],
                         "trilium-next-server.service trilium-next-server-proxy.socket")
        self.assertEqual(proxy["Unit"]["After"], proxy["Unit"]["Requires"])
        self.assertIn("--exit-idle-time=10min 127.0.0.1:8081", proxy_text)
        self.assertIn("http://127.0.0.1:8081/api/health-check", proxy["Service"]["ExecStartPre"])
        self.assertIn("--retry-all-errors", proxy["Service"]["ExecStartPre"])
        self.assertNotIn("[Install]", proxy_text)

    def test_app_is_not_boot_started(self):
        tasks = load_yaml(ROLES_DIR / "trilium-next-server/tasks/main.yml")
        override = next(t["ansible.builtin.copy"]["content"] for t in tasks
                        if t["name"] == "Manage trilium service override file")
        self.assertIn("StopWhenUnneeded=yes", override)
        self.assertIn("Environment=TRILIUM_HOST=127.0.0.1", override)
        self.assertIn("Environment=TRILIUM_PORT={{ trilium_next_server_backend_port }}", override)
        app_task = next(t["ansible.builtin.systemd"] for t in tasks
                        if t["name"] == "Disable direct Trilium boot activation")
        self.assertFalse(app_task["enabled"])
        handlers = load_yaml(ROLES_DIR / "trilium-next-server/handlers/main.yml")
        names = {h["name"] for h in handlers} | {h["listen"] for h in handlers if "listen" in h}
        for task in tasks:
            if "notify" in task:
                self.assertIn(task["notify"], names)
        self.assertFalse(any(h.get("ansible.builtin.systemd", {}).get("state") == "restarted"
                             for h in handlers))

    def test_caddy_change_is_targeted_and_idempotent(self):
        from jinja2 import Environment, StrictUndefined
        tasks = load_yaml(ROLES_DIR / "trilium-next-server/tasks/main.yml")
        change = next(t["ansible.builtin.replace"] for t in tasks
                      if "ansible.builtin.replace" in t)
        env = Environment(undefined=StrictUndefined)
        values = defaults("trilium-next-server")
        pattern = env.from_string(change["regexp"]).render(values)
        replacement = env.from_string(change["replace"]).render(values)
        original = "route /note/* {\n    reverse_proxy * 127.0.0.1:8080\n}\nother {\n    reverse_proxy 127.0.0.1:3000\n}\n"
        updated = re.sub(pattern, replacement, original)
        self.assertIn("keepalive off", updated)
        self.assertIn("reverse_proxy 127.0.0.1:3000", updated)
        self.assertEqual(re.sub(pattern, replacement, updated), updated)
        self.assertIn("caddy validate", change["validate"])


if __name__ == "__main__":
    unittest.main()
