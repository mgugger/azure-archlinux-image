#!/bin/bash
set -euo pipefail

if [[ -z "${MOUNT_ROOT:-}" ]]; then
    echo "ERROR: MOUNT_ROOT is not set" >&2
    exit 1
fi

mkdir -p "${MOUNT_ROOT}/etc/ssh/sshd_config.d"
cat > "${MOUNT_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" << 'EOF'
IgnoreRhosts yes
MaxAuthTries 3
HostbasedAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
LoginGraceTime 1m
Compression yes
ClientAliveCountMax 2
AllowTcpForwarding yes
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
AllowAgentForwarding no
MaxSessions 2
TCPKeepAlive no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp256
PubkeyAcceptedAlgorithms ssh-ed25519,ecdsa-sha2-nistp256
EOF

# Keep su restricted to wheel group.
if [[ -f "${MOUNT_ROOT}/etc/pam.d/su-l" ]]; then
    if ! grep -Eq '^\s*auth\s+required\s+pam_wheel\.so\s+use_uid\s*$' "${MOUNT_ROOT}/etc/pam.d/su-l"; then
        echo 'auth required pam_wheel.so use_uid' >> "${MOUNT_ROOT}/etc/pam.d/su-l"
    fi
fi

# Increase local password hash rounds.
if [[ -f "${MOUNT_ROOT}/etc/pam.d/passwd" ]]; then
    if grep -Eq '^password\s+required\s+pam_unix\.so' "${MOUNT_ROOT}/etc/pam.d/passwd"; then
        sed -i -E 's|^password\s+required\s+pam_unix\.so.*$|password required pam_unix.so sha512 shadow nullok rounds=65536|' "${MOUNT_ROOT}/etc/pam.d/passwd"
    else
        echo 'password required pam_unix.so sha512 shadow nullok rounds=65536' >> "${MOUNT_ROOT}/etc/pam.d/passwd"
    fi
fi

ensure_login_defs_value() {
    local key="$1"
    local value="$2"
    local file="${MOUNT_ROOT}/etc/login.defs"

    if [[ ! -f "${file}" ]]; then
        return 0
    fi

    if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "${file}"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*$|${key} ${value}|" "${file}"
    else
        echo "${key} ${value}" >> "${file}"
    fi
}

ensure_login_defs_value "SHA_CRYPT_MAX_ROUNDS" "4000000"
ensure_login_defs_value "SHA_CRYPT_MIN_ROUNDS" "400000"

if [[ -f "${MOUNT_ROOT}/etc/profile" ]]; then
    if grep -Eq '^\s*umask\s+' "${MOUNT_ROOT}/etc/profile"; then
        sed -i -E 's|^\s*umask\s+.*$|umask 027|' "${MOUNT_ROOT}/etc/profile"
    else
        echo 'umask 027' >> "${MOUNT_ROOT}/etc/profile"
    fi
fi

mkdir -p "${MOUNT_ROOT}/etc/systemd/timesyncd.conf.d"
cat > "${MOUNT_ROOT}/etc/systemd/timesyncd.conf.d/10-ntp.conf" << 'EOF'
[Time]
NTP=time.windows.com
FallbackNTP=pool.ntp.org
EOF

# Enable AppArmor profile cache.
if [[ -f "${MOUNT_ROOT}/etc/apparmor/parser.conf" ]]; then
    grep -Eq '^write-cache\s*$' "${MOUNT_ROOT}/etc/apparmor/parser.conf" || \
        echo 'write-cache' >> "${MOUNT_ROOT}/etc/apparmor/parser.conf"
fi

# Enable hardening-related services only when they are present.
arch-chroot "${MOUNT_ROOT}" bash -c '
    if systemctl cat apparmor.service >/dev/null 2>&1; then
        systemctl enable apparmor.service
    fi

    if systemctl cat auditd.service >/dev/null 2>&1; then
        systemctl enable auditd.service
    fi

    systemctl enable systemd-timesyncd.service
'
