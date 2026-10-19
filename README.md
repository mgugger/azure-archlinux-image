# Archlinux on Azure — Squashfs + vTPM Architecture

A hardened Arch Linux image for Azure Trusted Launch VMs with:
* **Squashfs fallback root** — minimal boot image, no Packer required
* **vTPM disk encryption** — LUKS2 sealed to vTPM (PCR 11), replaces luks_unlocker
* **Auto-provisioning** — raw data disk is encrypted and installed on first boot
* systemd-boot + UKI + Secure Boot
* BTRFS with subvolumes + zstd compression
* cloud-init, AppArmor, linux-hardened
* No walinuxagent

## Architecture

```
Boot VHD (~1.5GB)                     Data Disk (attached in Azure)
┌─────────────────────┐               ┌──────────────────────────┐
│ ESP: UKI + loader   │               │ LUKS2 (vTPM-sealed)      │
│ Root: squashfs.sfs  │  ──detects──▶ │  └─ BTRFS                │
│       /var/log      │               │     ├─ @      (root)     │
│       /var/cache    │               │     ├─ @home             │
└─────────────────────┘               │     ├─ @log              │
                                      │     ├─ @cache            │
                                      │     └─ @srv              │
                                      └──────────────────────────┘
```

### Boot Flow

1. **UKI boots** → initramfs runs `arch-root-setup.service` (`setup-root`)
2. **Data disk with LUKS found** → vTPM unseals key → mount BTRFS subvols → boot into data disk root
3. **Raw/unformatted data disk found** → boot into squashfs + overlayfs → `provision-data-disk.service` runs:
   - LUKS2 format + `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=11`
   - BTRFS with subvolumes
   - System install from squashfs + `pacman -Syu`
   - Regenerate UKI for data-disk root
   - Reboot
4. **No data disk** → boot into squashfs maintenance environment (SSH available via cloud-init)

## Build (replaces Packer)

Build directly on an Arch Linux host — no QEMU/Packer needed:

```bash
# Install build dependencies
pacman -S arch-install-scripts squashfs-tools dosfstools btrfs-progs \
    qemu-img mkinitcpio systemd-ukify sbsigntools azure-cli

# Build the VHD image
sudo KEY_VAULT_NAME=<your-key-vault-name> ./build.sh

# Build and upload to Azure
sudo AZURE_STORAGE_ACCOUNT=mystorageacct \
     AZURE_STORAGE_CONTAINER=vhds \
  KEY_VAULT_NAME=<your-key-vault-name> \
     ./build.sh --upload
```

Output: `out/azure-archlinux.vhd`

Then create the Azure managed image:
```bash
az image create --resource-group <rg> --name azure-archlinux \
  --os-type Linux --hyper-v-generation V2 \
  --source https://<storage>.blob.core.windows.net/vhds/azure-archlinux.vhd
```

## Deployment

Deploy with the existing Bicep templates:
```bash
az deployment group create \
  --resource-group <rg> \
  --template-file bicep/main.bicep \
  --parameters baseName=myvm pubkeydata="$(cat ~/.ssh/id_rsa.pub)" \
               vm_admin_name=$(whoami) local_public_ip=$(curl -s ifconfig.me)
```

### Post-Deployment

1. **Set VM tag and Key Vault permissions** before first provisioning reboot:
  - VM tag: `KeyVaultName=<your-key-vault-name>`
  - Grant VM managed identity `secrets/get` on that Key Vault
2. **Attach a data disk** (Premium SSD v2 recommended) to the VM
3. **Reboot** — the first-boot service will automatically:
   - Encrypt the data disk with LUKS2 + vTPM
   - Install the full system
  - Fetch Secure Boot private key from Key Vault into encrypted root
   - Reboot into the data disk root
4. **Secure Boot** — after first successful boot, enable Secure Boot and run:
   ```bash
   /usr/local/sbin/setup-secureboot.sh
   ```

### Secure Boot Private Key Flow

* Build time: key is generated, used for signing UKI/systemd-boot, uploaded to Key Vault, then shredded from the build workspace
* Build time: a random 64-character root password is generated and uploaded to Key Vault as `root-login-password` (override with `ROOT_PASSWORD_SECRET_NAME`)
* Boot disk image: only the public certificate is included
* Provisioning: private key is fetched via managed identity and stored on encrypted data disk only
* Provisioning: root password is fetched from Key Vault and applied to the data-disk root
* Runtime updates: `/usr/local/bin/secure-boot-resign` uses local encrypted key and can recover it from Key Vault if missing

### Recovery / Maintenance

If the data disk is removed or fails, the VM boots into the squashfs maintenance environment with password-based root login on console only (sshd is masked).

## Recreating Immich, Papra, and OneDrive mounts

The opt-in roles in [ansible/local.yml](ansible/local.yml) reproduce the
rootful Podman and rclone setup inspected on `192.168.8.0`:

| Role | Services | Persistent storage |
|------|----------|--------------------|
| `rclone-onedrive` | `rclone-onedrive`, `rclone-media` | `onedrive_media:` at `/mnt/onedrive`; `onedrive_media_crypt:` at `/mnt/media` |
| `immich` | `immich-compose` | Photos at `/mnt/media/Pictures`; PostgreSQL at `/etc/containers/systemd/immich/postgres`; Podman model-cache volume |
| `papra` | `papra` (generated from a Quadlet) | Documents at `/mnt/onedrive/Papra_Docs`; SQLite at `/var/lib/papra-db` |

Role defaults expose image versions, paths, ports, proxies, and mount flags.
Immich retains `v3`, the inspected PostgreSQL/Valkey image digests, port 2283,
and the `10.89.0.0/24` bridge with gateway `10.89.0.1` on `podman1`. The
`containers.podman.podman_network` module manages that bridge; Compose treats it
as external so stopping Immich does not remove it.
Papra retains its `latest` image, port 1221, configured URLs, encrypted document
storage, and English-only OCR. Its language data comes from Arch's
`tesseract-data-eng` package rather than a manually downloaded file.

### Credentials and restoration

1. Restore local application databases/configuration **before starting the
   roles**. Keep the Immich database password from the original `.env`.
2. Copy [ansible/secrets/apps.example.yml](ansible/secrets/apps.example.yml) to
   `ansible/secrets/apps.local.yml` (gitignored), restrict its permissions to
   `0600`, and fill in the existing credentials. Alternatively supply an Ansible
   Vault vars file with `-e @<vault-file> --ask-vault-pass`. No production
   credentials are included in the repository.
3. For Papra's first migration from the existing inline Quadlet configuration,
   securely recover `AUTH_SECRET` and
   `DOCUMENT_STORAGE_DOCUMENT_KEY_ENCRYPTION_KEYS` from the original Quadlet
   into `papra_auth_secret` and `papra_document_encryption_keys`. The role moves
   these into a root-only environment file. **Do not generate replacement
   encryption keys for existing documents**: the old keys are needed to decrypt
   them. Neither secret is written to the generated unit or shown in Ansible
   diffs.
4. Restore `/var/lib/rclone/.config/rclone/rclone.conf`, or supply its complete
   contents in `rclone_onedrive_config_content`. It must contain both
   `onedrive_media` and `onedrive_media_crypt`, including the OneDrive OAuth
   token, drive settings, and original crypt passwords. The role only seeds a
   **missing** config and never overwrites refreshed tokens on subsequent runs.
   Update or reauthorize an existing config with `rclone config` separately.
5. Existing Immich `.env` and Papra environment files are preserved when their
   secret variables are empty. Supplying credentials opts into managing those
   files from the role variables; include any non-default settings as overrides.

When `/etc/restic/root.files` exists, the roles register the local database and
configuration paths there, including the rclone credentials. Protect those
backups. Back up PostgreSQL/SQLite consistently (stop the apps or use
database-aware snapshots/dumps); listing the database directories alone does
not guarantee a consistent live backup. Cloud documents/photos and the crypt
keys must also be retained. The model cache can be downloaded again.

### Applying the roles

Install Ansible's `community.general` and `containers.podman` collections on the
controller. Apply `networking-hardening` before the app roles on a new host:
it configures the host/container proxy ACL, registry/model/OneDrive allowlist,
and the container-to-proxy firewall rule. Existing reverse-proxy site
configuration and DNS must also be restored separately. The Caddy role does not
reconstruct the existing application sites.

Uncomment the three tagged role entries in `ansible/local.yml`, retaining the
order **rclone-onedrive, immich, papra**. On an already provisioned host:

```bash
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ansible-playbook \
  -i '192.168.8.0,' -u manuel ansible/local.yml --tags apps --check

# Apply after reviewing the check-mode output:
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ansible-playbook \
  -i '192.168.8.0,' -u manuel ansible/local.yml --tags apps
```

`apps.local.yml` is loaded automatically even for tagged runs.
Run without `--tags apps` for full host provisioning, reviewing the other enabled
roles first. rclone runs as root, matching the existing system services, with
`--allow-other` so containers can access the mounts. `Type=notify` waits for each
FUSE mount to be ready before dependent applications start; both applications
also check that their cloud mountpoint is actually mounted. The cache remains
at `/mnt/arch-var/rclone-cache-onedrive` and must have sufficient local space.
Papra's generated service is enabled via the Quadlet's `[Install]` section,
not `systemctl enable` on a generated unit.

Run the focused template/configuration tests with:

```bash
python -m unittest discover -s ansible/tests -p 'test_app_roles.py'
```

## NetBird server and dashboard

The [netbird role](ansible/roles/netbird), enabled in `ansible/local.yml`, installs `netbird-server`
and `netbird-dashboard` from AUR using **yay as the unprivileged AUR builder**.
The server package is the current combined management/signal/relay/STUN server;
the separately packaged dashboard is generated with
`netbird-dashboard-generate` and served directly by Caddy. No NetBird containers,
Nginx, external identity provider, or client VPN service are installed.

Default URL: **https://netbird.manolito.wanip.ch**.

### Provisioning

1. Point the hostname's DNS record to the server's public IP. Allow TCP 80/443
   and UDP 3478 through the Azure NSG/router/firewall. Caddy handles HTTPS;
   STUN uses UDP directly and cannot go through Caddy.
2. Set the three `netbird_*` secrets directly on the server in the root-only
   `/etc/netbird-server/secrets.yml`, or use
   [apps.local.yml](ansible/secrets/apps.example.yml) / an Ansible Vault vars
   file. Ansible-supplied nonempty values take precedence over server-local
   values. Generate **three independent values** using `openssl rand -base64 32`.
   Raw 32-byte ASCII encryption keys are also accepted and base64-encoded when
   rendering the server configuration; the server-local secrets file is not
   rewritten. The relay secret is used as supplied and must have at least
   32 characters.
   Keep these keys alongside the database backups; do not rotate encryption
   keys when restoring existing data.
3. The NetBird role itself allows `netbird_stun_port` (3478 by default) in
   nftables. It installs `/etc/nftables.d/netbird-input.nft`, includes service
   rules before the input chain's terminal drop, and inserts the live rule at
   that same position. It does **not** flush the ruleset or reload nftables,
   preserving Podman's dynamically installed container/NAT rules. The
   `networking-hardening` template retains the include on subsequent runs.
   If overriding the STUN port, also update the external firewall.
4. Apply the existing `yay-bin` and `caddy` roles before `netbird`, after
   `networking-hardening`. The NetBird role checks these prerequisites and
   extends tinyproxy's allowlist for AUR/Go/npm builds, the initial geolocation
   database download from `pkgs.netbird.io`, and its own public issuer.
   Review AUR PKGBUILDs before use; the first source builds can take some time.
5. Once prerequisites are applied, preview/apply only NetBird with:

   ```bash
   env LANG=C.UTF-8 LC_ALL=C.UTF-8 ansible-playbook \
     -i '192.168.8.0,' -u manuel ansible/local.yml --tags netbird --check

   env LANG=C.UTF-8 LC_ALL=C.UTF-8 ansible-playbook \
     -i '192.168.8.0,' -u manuel ansible/local.yml --tags netbird
   ```

6. Open the HTTPS dashboard and **immediately complete initial administrator
   setup** before allowing other users access. Subsequent user management uses
   NetBird's embedded identity provider.

The role adds a marked, validated site block to the existing Caddyfile, leaving
the other applications' sites intact. Caddy serves the dashboard and callback
pages, forwards gRPC using h2c, and forwards REST, OAuth2, relay, and WebSocket
paths without stripping their prefixes. The server listens only on
`127.0.0.1:8085`; its health endpoint is on `127.0.0.1:9001`. Metrics use port
9091, remain outside the Caddy routes, and should not be exposed by the host or
external firewall. The server runs as a dedicated `netbird` user; the
configuration is root-owned, group-readable, and omitted from Ansible diffs.

The role starts the service and checks embedded OIDC discovery against the
configured public issuer. It registers `/etc/netbird-server`, `/var/lib/netbird`,
the dashboard environment, and Caddyfile with restic when its root file list
exists. Stop the service or take consistent database backups, and retain
`store.db`, `events.db`, `idp.db`, and the encryption keys together.

### Deploying before secrets are available

To install packages, publish the dashboard, and configure the firewall without
starting an unconfigured backend:

```bash
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ansible-playbook \
  -i '192.168.8.0,' -u manuel ansible/local.yml --tags netbird \
  -e netbird_allow_unconfigured=true
```

This explicit staging mode only accepts **all three secrets empty**, not partial
or malformed credentials. It seeds `/etc/netbird-server/secrets.yml` with empty
values and mode `0600` without overwriting an existing file. The dashboard is
served, but login/API calls are unavailable and `netbird-server` remains
**stopped and disabled**.

On the server, edit the file with `sudoedit /etc/netbird-server/secrets.yml` and
set:

```yaml
netbird_relay_auth_secret: "<first openssl rand -base64 32 value>"
netbird_store_encryption_key: "<second independent value>"
netbird_session_cookie_encryption_key: "<third independent value>"
```

Then rerun the role **without** `netbird_allow_unconfigured=true`. It reads the
secrets from the server, renders the private configuration, enables/starts the
backend, and verifies OIDC discovery. No credentials need to be copied back to
the controller. Do not start the staged service manually before this render.

Installed AUR packages are not rebuilt on each Ansible run. Perform upgrades
explicitly with yay as the AUR builder. The dashboard package's upgrade hook
regenerates its assets from the managed environment file. Check-mode does not
build missing packages or run the generator, so a fresh-install check cannot
verify the resulting binaries.

During initial AUR builds, the role temporarily stops an active
`pacman-auto-update.timer`, waits for any running update to finish, and restores
the timer in an `always` block. This prevents the updater's orphan cleanup from
removing Go or other build dependencies during compilation. Apply the same
precaution when performing manual AUR upgrades.

Package/configuration references:
[AUR server](https://aur.archlinux.org/packages/netbird-server),
[AUR dashboard](https://aur.archlinux.org/packages/netbird-dashboard),
[combined server configuration](https://github.com/netbirdio/netbird/blob/v0.81.2/combined/config.yaml.example),
[reverse-proxy requirements](https://docs.netbird.io/selfhosted/external-reverse-proxy).

### NetBird client

The separate `netbird-client` role installs
[`netbird-bin` from the AUR](https://aur.archlinux.org/packages/netbird-bin)
through yay as the unprivileged AUR builder. This package repackages the upstream
prebuilt client; the role does not download/install an unmanaged binary or
compile the Go client. It requires the existing yay-bin, host proxy and kernel
TUN setup.

The role is enabled in [the local playbook](ansible/local.yml). From the
repository root, deploy only this role with:

```bash
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook -i '192.168.8.0,' -u manuel \
  ansible/local.yml --tags netbird-client
```

It enables the AUR-provided `netbird@client.service`, with a managed drop-in
isolating **all five systemd directories** from the backend. Client
configuration is in `/etc/netbird-client`, state and profiles are under
`/var/lib/netbird-client` through `NB_STATE_DIR`, and cache, logs and runtime
files use their respective `netbird-client` directories. The daemon runs as the
separate, non-login **`netbird-client`** account with only `CAP_NET_ADMIN`,
`CAP_NET_RAW`, and `CAP_NET_BIND_SERVICE`. Configuration/state directories are
0700 and remain separate from the backend's `netbird` account. A narrowly scoped
polkit rule authorizes this account's systemd-resolved DNS operations; no general
sudo permission is granted. The role links `/etc/resolv.conf` to the resolved stub
so Go programs do not fall back to a nonexistent localhost DNS server.

The daemon creates its RPC socket in `/run/netbird-client`; a root-owned symlink
at `/run/netbird.sock`, persisted with tmpfiles, preserves the normal CLI:

```bash
sudo systemctl status netbird@client.service
sudo netbird status
```

**Installation does not enroll the client.** A fresh daemon reports `NeedsLogin`.
For an already enrolled client, the role updates only `WgPort` to the managed
`netbird_client_wireguard_port` (default **51821**), preserving identity, keys,
and other enrollment settings. It stops the daemon before a required port edit;
unchanged runs do not restart it. Client configuration/state are registered with
restic when its file list exists.

The role installs persistent firewall snippets with these exceptions:

- Inbound UDP **51821** for the client, distinct from existing `wg0`/51820.
- WAN TCP **443** and UDP **only for the dedicated `netbird-client` UID**.
  STUN/ICE and QUIC use ephemeral source ports, so restricting all userspace UDP
  to the WireGuard source port breaks discovery. Native gRPC may bypass HTTP
  proxy variables, hence the explicit service-only HTTPS exception.
- Kernel WireGuard UDP is UID 0 and is restricted to source port **51821**.
- Overlay input remains subject to NetBird's own ACL table. Forwarding from the
  overlay is limited to DNAT/published container services and established replies.

There is **no all-user outbound UDP rule**. Other applications still use
allowlisted tinyproxy for web egress. The service is a trusted network administrator
because `CAP_NET_ADMIN` is required; this is UID separation, not a sandbox against
a compromised VPN daemon or root. PID-based nftables rules are not used.

Apply the firewall migration and both NetBird roles together:

```bash
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook -i '192.168.8.0,' -u manuel ansible/local.yml \
  --tags firewall,netbird,netbird-client
```

The base ruleset atomically replaces only `inet filter` using `destroy table`
(nftables >= 1.0.9), preserving Podman/NetBird tables. Never use `flush ruleset`.
The `firewall` tag applies just the base firewall tasks, without package/mirror
refreshes. Run that migration before applying only `netbird-client` on an older
installation. The installed snippets are included on future hardening runs.

For initial enrollment, use the same managed port:

```bash
sudo netbird up \
  --management-url https://netbird.manolito.wanip.ch \
  --wireguard-port 51821
```

Complete the interactive login or supply a setup key when explicitly enrolling.
The role neither requires nor stores a setup key in the repository.
`netbird_client_management_url` controls the management hostname allowed through
the proxy and shown in the enrollment instructions; enrollment itself must use
that URL explicitly.

### Caddy and direct-connection troubleshooting

The NetBird role removes a dedicated loopback `/etc/hosts` entry for its public
hostname: that override also redirects STUN and prevents public NAT discovery.
It also extends Caddy's **request-body idle** and write-idle timeouts for long-lived
gRPC streams (`netbird_caddy_write_idle_timeout`, default 24h). This requires the
Caddy 2.11.6+ idle-timeout options. Merely changing reverse-proxy transport timeouts
is insufficient. These are server-wide settings in the existing global `servers`
block; other sites share the longer idle allowance. Header timeouts remain intact.

Existing Caddy app matchers that already trust `100.64.0.0/10` gain IPv6 ULA
`fc00::/7` access. Matchers without NetBird IPv4 access are left unchanged, so
admin/metrics restrictions are not silently broadened. The base firewall allows
inbound UDP 443 for Caddy HTTP/3 as well as TCP HTTPS.

A relayed peer is not necessarily a firewall error. Inspect `sudo netbird status -d`
and the client log. On the investigated Android client (0.78.0), offers advertised
`remote ICE supported: false`; a fixed server port alone cannot make that peer
negotiate a direct ICE path. Update/check the Android client and its STUN/network
reachability. Also test UDP from the VM: contacting its **own public** STUN address
can fail on cloud NAT hairpin paths even when external clients reach that STUN
server. Do not restore broad UDP egress to mask this. At deployment, app access and
control streams were verified fixed, but the Android connection remained relayed
and VM-originated public STUN probes still timed out.

## Bifrost AI gateway and Open WebUI

The `bifrost` role runs a pinned Podman image through a rootful Quadlet, like
Papra. The `open-webui` role installs the AUR package through the unprivileged
yay builder. Apply `networking-hardening`, `yay-bin`, and `caddy` first.
Both backends bind only to loopback:

| Application | Local endpoint | Persistent storage |
|-------------|----------------|--------------------|
| Bifrost | `127.0.0.1:8086` | `/var/lib/bifrost`, `/etc/bifrost` |
| Open WebUI | `127.0.0.1:3000` | `/var/lib/open-webui`, `/etc/open-webui` |

Deploy just these roles to the application server:

```bash
env LANG=C.UTF-8 LC_ALL=C.UTF-8 ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook -i '192.168.8.0,' -u manuel \
  ansible/local.yml --tags bifrost,open-webui
```

The roles extend tinyproxy's allowlist without changing the host firewall or
existing Caddy sites. AUR installation temporarily pauses automatic updates and
restores the timer even on failure. Installed packages are not rebuilt on every
run; upgrade them explicitly through yay.

Bifrost uses `docker.io/maximhq/bifrost:v2.3.1`, configurable with
`bifrost_image`. Its Quadlet uses host networking to reach the existing
loopback-only tinyproxy, explicitly binds the app to `127.0.0.1`, and runs as
the image's non-root UID 1000 with capabilities dropped. Its data mount uses
Podman's `:U` ownership adjustment. No container bridge/firewall exceptions
are needed. This avoids the AUR package's mutable README checksum failure.
The AUR Open WebUI package uses uv to install its Python
environment on first launch; this can take several minutes and several GB of
disk space. The role uses the installed AUR package's application version and
the CPU-only PyTorch index. It overrides the package's hard-coded all-interface
port 8080 and removes the service's Ollama dependency, since Bifrost supplies
the OpenAI-compatible API instead.

### Access and initial configuration

Caddy serves **https://chat.manolito.wanip.ch** with WebSocket support and
unbuffered streaming, restricted to clients in `192.168.0.0/16`,
`172.16.0.0/12`, `10.0.0.0/8`, `100.64.0.0/10` (NetBird), and `fc00::/7`.
All other client addresses receive HTTP 403 on every application path.
The rule checks the direct peer address, not client-supplied forwarded headers.
Connect through the LAN or NetBird; loopback is not included in this allowlist.
TLS uses automatic public certificates, not Caddy's internal CA.
Point the hostname at the server and permit inbound
TCP 80/443 for HTTPS certificate issuance; neither backend port needs opening.
The proxy allowlist includes the ACME endpoints used by Caddy. If this hostname
returns NXDOMAIN, create its public DNS record first; Caddy retries certificate
issuance automatically once DNS resolves to this server.

Public signup is disabled. On first installation the role generates an
administrator password and a session-signing key on the server, storing them
in `/etc/open-webui/secret.env` with mode `0600`. Log in as
`admin@chat.manolito.wanip.ch` (override `open_webui_admin_email` if needed).
Retrieve the initial password privately on the server:

```bash
sudo grep '^WEBUI_ADMIN_PASSWORD=' /etc/open-webui/secret.env
```

Change the password after login. Rerunning the role does not replace the
credentials or reset the account's password. Restore the database **and**
`/etc/open-webui/secret.env` together to retain the session-signing key.

Bifrost's management UI is deliberately not public. Reach it over SSH:

```bash
ssh -L 8086:127.0.0.1:8086 manuel@192.168.8.0
```

Open `http://localhost:8086`. On first setup, the dashboard requires the
operator's setup token before an administrator account can be created.
The role generates this token on the server, stores it in
`/etc/bifrost/secret.env` (root-only, mode `0600`), and passes it into the
container as `BIFROST_SETUP_TOKEN`. Retrieve it privately on the server:

```bash
sudo grep '^BIFROST_SETUP_TOKEN=' /etc/bifrost/secret.env
```

Enter the value in the dashboard, then enable dashboard authentication and
create your administrator account. The setup token stops working once
dashboard authentication is enabled. The role preserves the token across
reruns and registers `/etc/bifrost` for backup alongside the database.
It verifies that setup is possible or dashboard authentication is already
enabled; a basic health check alone does not confirm this.

Then configure providers and their API keys.
Open WebUI initially connects to `http://127.0.0.1:8086/openai/v1`; provider
credentials stay in Bifrost rather than this repository. No provider keys or
paid inference requests are supplied by these roles. Add any additional
provider hosts to `bifrost_proxy_domains`. The configured Azure Foundry resource,
`mdgcorpfoundry.services.ai.azure.com`, is included in the default allowlist.
For each provider, explicitly set its proxy configuration in the Bifrost
dashboard to **HTTP**, URL `http://127.0.0.1:8888`, or choose its environment
proxy mode. Bifrost's provider HTTP clients do not use the container's proxy
environment when the provider has no proxy configuration. Without this setting,
the default-deny host firewall causes provider requests, including model
discovery, to time out.

For Azure, use the resource's inference endpoint rather than a Foundry project
management URL ending in `/api/projects/<project>`. Verify the endpoint against
the deployment's connection details; Bifrost appends `/openai/v1/models` when
discovering Azure models.

If enabling Bifrost virtual-key
authentication, configure the matching key privately in Open WebUI's admin
connection settings. These connection settings persist in Open WebUI's
database after first launch; later environment changes do not overwrite
admin-managed settings.

When `/etc/restic/root.files` exists, both roles register their persistent
state. Protect these backups, which contain chats, credentials and provider
keys; stop the services or use database-consistent backups.

## Repository Structure

```
build.sh                          # Build script (replaces Packer)
packages.conf                     # Package lists for squashfs + full install
initcpio/
  install/squashfs-overlay         # Initramfs: install hook
  systemd/arch-root-setup.service  # Initramfs: orchestrates root selection
  systemd/setup-root               # Initramfs: data-disk or squashfs setup logic
first-boot/
  provision-data-disk.sh           # First-boot: encrypt, format, install
  provision-data-disk.service      # systemd unit for provisioning
bicep/                             # Azure infrastructure (unchanged)
playbooks/                         # Ansible playbooks (optional, for customization)
```

## Key Differences from Previous Architecture

| Aspect | Old (Packer + luks_unlocker) | New (squashfs + vTPM) |
|--------|------------------------------|------------------------|
| Build tool | Packer + QEMU/KVM | Native Arch (`pacstrap` + `mksquashfs`) |
| Image size | 4GB (full LUKS root) | ~1.5GB (squashfs + ESP) |
| Encryption unlock | `luks_unlocker` binary (Azure KeyVault) | `systemd-cryptenroll` (vTPM, PCR 7+11) |
| Root filesystem | LUKS on OS disk | LUKS on data disk, squashfs fallback |
| Recovery | Fallback initramfs with passphrase | Squashfs maintenance environment |
| First boot | Manual data disk migration | Automatic provisioning |
| External deps | GitHub binary download | Azure Key Vault (for Secure Boot private key storage) |
