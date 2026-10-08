#!/usr/bin/env bash
# ==============================================================================
#  STEALTH HFT LINUX SERVER - ULTRA-LOW LATENCY SETUP (VER-1)
#  Target: Ubuntu / Debian on AWS Mumbai (ap-south-1)
#  Configured for: Knox Trader NANO-FAST + Zerodha Nano-sec Collector + Finvasia OMS
# ==============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "============================================================"
echo "  [CONFIG] PRIVATE PORT SELECTION & TRADER USER"
echo "============================================================"
RDP_PORT="${1:-5133}"
SSH_PORT="${2:-1721}"
TRADER_USER="trader"

echo "Private Ports Configured: RDP=${RDP_PORT} | SSH=${SSH_PORT}"
echo "Trader Execution User: ${TRADER_USER}"

echo "============================================================"
echo "  [1/10] INDIAN STANDARD TIME (IST) & ATOMIC CHRONY SYNC"
echo "============================================================"
timedatectl set-timezone Asia/Kolkata
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
echo "Asia/Kolkata" > /etc/timezone

apt-get update -y
apt-get install -y chrony cron ethtool

cat > /etc/chrony/chrony.conf <<EOF
# AWS Mumbai Internal Hypervisor NTP (Sub-millisecond RTT)
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 6
# National Physical Laboratory of India (Official Atomic IST Reference)
server time.nplindia.org iburst minpoll 4 maxpoll 6
# Secondary Stratum-1 Atomic Servers
server in.pool.ntp.org iburst minpoll 4 maxpoll 6
server time.cloudflare.com iburst minpoll 4 maxpoll 6
server time.google.com iburst minpoll 4 maxpoll 6

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync

# Quick step on startup if skew > 100ms
makestep 0.1 3

# Prevent backward time steps during market hours!
maxslewrate 500
EOF

systemctl restart chrony
systemctl enable chrony

# Morning Hard-Snap at 08:59:00 IST (1 minute before pre-open 09:00:00)
cat > /etc/cron.d/hft_clock_snap <<'EOF'
59 8 * * 1-5 root /usr/bin/chronyc makestep >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/hft_clock_snap

echo "============================================================"
echo "  [2/10] SYSTEM PACKAGES, RUST TOOLCHAIN & GRAPHICS LIBS"
echo "============================================================"
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
apt-get install -y --no-install-recommends \
    ca-certificates curl wget ufw fail2ban dbus-x11 unzip \
    build-essential pkg-config libssl-dev htop rsync git \
    mesa-vulkan-drivers libgl1-mesa-dri libvulkan1 vulkan-tools \
    libfontconfig1-dev libasound2-dev libx11-dev libxcursor-dev \
    libxrandr-dev libxi-dev libxkbcommon-x11-0 irqbalance cpufrequtils

# Install Rust toolchain
if ! command -v rustc &>/dev/null; then
    echo "Installing Rust toolchain (stable-x86_64-unknown-linux-gnu)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env" || true
fi

echo "============================================================"
echo "  [3/10] NANOSECOND-GRADE HFT KERNEL & NETWORK STACK"
echo "============================================================"
cat > /etc/sysctl.d/99-hft-latency.conf <<'EOF'
# TCP Congestion & Queuing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket Busy Polling (50us low-latency polling for incoming market frames)
net.core.busy_poll = 50
net.core.busy_read = 50

# TCP Latency Optimizations
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# High-Throughput Ring Buffers (32MB Max)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# SYN & Connection Queue Handling
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_synack_retries = 2

# Memory & Swapping
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Shared Memory Maxima (2GB)
kernel.shmmax = 2147483648
kernel.shmall = 524288
EOF
sysctl --system >/dev/null 2>&1

# Mount /dev/shm with performance flags (noatime, nodiratime, 2GB)
if ! grep -q "tmpfs /dev/shm" /etc/fstab; then
    echo "tmpfs /dev/shm tmpfs defaults,noatime,nodiratime,size=2G 0 0" >> /etc/fstab
fi
mount -o remount,noatime,nodiratime,size=2G /dev/shm 2>/dev/null || true

# Maximize NIC Hardware Ring Buffers
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -n "$DEFAULT_IFACE" ]; then
    ethtool -G "$DEFAULT_IFACE" rx 4096 tx 4096 2>/dev/null || true
fi

# Ban irqbalance from interrupting trading cores (Isolates cores 2-7)
cat > /etc/default/irqbalance <<'EOF'
IRQBALANCE_BANNED_CPUS="fc"
EOF
systemctl restart irqbalance 2>/dev/null || true

# Unlimited memory locking for zero-page-fault HFT ring buffers
cat > /etc/security/limits.d/99-hft-limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
trader soft memlock unlimited
trader hard memlock unlimited
EOF

echo "============================================================"
echo "  [4/10] PREVENTING CPU SLEEP (LOCK PERFORMANCE GOVERNOR)"
echo "============================================================"
if which cpufreq-set >/dev/null 2>&1; then
    for CPU in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq-set -c "${CPU##*cpu}" -g performance 2>/dev/null || true
    done
fi

GRUB_CMD="processor.max_cstate=1 intel_idle.max_cstate=1 idle=poll mitigations=off"
if [ -f /etc/default/grub ] && ! grep -q "idle=poll" /etc/default/grub; then
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*/& ${GRUB_CMD}/" /etc/default/grub
    update-grub 2>/dev/null || true
fi

echo "============================================================"
echo "  [5/10] XFCE4 DESKTOP & 24/7 AWAKE CONFIGURATION"
echo "============================================================"
apt-get purge -y xfce4-screensaver light-locker xscreensaver 2>/dev/null || true
apt-get install -y xfce4 xfce4-goodies xfce4-whiskermenu-plugin xfce4-terminal mousepad x11-xserver-utils

if ! id "$TRADER_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$TRADER_USER"
    usermod -aG sudo "$TRADER_USER"
fi

cat > /home/${TRADER_USER}/.xsession <<'EOF'
#!/bin/sh
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export WGPU_BACKEND=vulkan,gl

# Restrict Mesa software rasterizer to 1 worker thread (saves CPU for trading)
export LP_NUM_THREADS=1

# Disable all screen blanking, sleep timers, and DPMS
xset s off
xset s noblank
xset -dpms
exec startxfce4
EOF
chmod +x /home/${TRADER_USER}/.xsession
chown ${TRADER_USER}:${TRADER_USER} /home/${TRADER_USER}/.xsession

CFG="/home/${TRADER_USER}/.config"
mkdir -p "$CFG/xfce4/xfconf/xfce-perchannel-xml/"

cat > "$CFG/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

cat > "$CFG/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="power-button-action" type="uint" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-sleep-ac" type="uint" value="0"/>
    <property name="dpms-off-ac" type="uint" value="0"/>
    <property name="presentation-mode" type="bool" value="true"/>
  </property>
</channel>
EOF
chown -R ${TRADER_USER}:${TRADER_USER} "$CFG"

echo "============================================================"
echo "  [6/10] CORE ISOLATION WRAPPER (hft-run)"
echo "============================================================"
NCPU=$(nproc)
if [ "$NCPU" -ge 8 ]; then
    HFT_CORES="6,7"
elif [ "$NCPU" -ge 4 ]; then
    HFT_CORES="2,3"
else
    HFT_CORES="1"
fi

cat > /usr/local/bin/hft-run <<EOF
#!/usr/bin/env bash
# Run command with locked CPU affinity and maximum real-time priority
exec taskset -c ${HFT_CORES} nice -n -20 "\$@"
EOF
chmod +x /usr/local/bin/hft-run

echo "============================================================"
echo "  [7/10] INSTALLING OFFICIAL GOOGLE CHROME"
echo "============================================================"
if ! command -v google-chrome &>/dev/null; then
    wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y /tmp/chrome.deb
    rm -f /tmp/chrome.deb
    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable || true
fi

echo "============================================================"
echo "  [8/10] CONFIGURING XRDP ON CUSTOM PORT :${RDP_PORT}"
echo "============================================================"
apt-get install -y xrdp xorgxrdp
adduser xrdp ssl-cert 2>/dev/null || true

sed -i "s/^port=3389/port=${RDP_PORT}/" /etc/xrdp/xrdp.ini
sed -i 's/^crypt_level=.*/crypt_level=high/' /etc/xrdp/xrdp.ini
sed -i 's/^bitmap_compression=.*/bitmap_compression=true/' /etc/xrdp/xrdp.ini
sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini

sed -i 's/^#idle_timeout=.*/idle_timeout=0/' /etc/xrdp/sesman.ini 2>/dev/null || true
sed -i 's/^#disconnected_timeout=.*/disconnected_timeout=0/' /etc/xrdp/sesman.ini 2>/dev/null || true

sed -i "s/^#Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config

systemctl restart xrdp
systemctl enable xrdp
systemctl restart ssh

echo "============================================================"
echo "  [9/10] HARDENED FIREWALL & FAIL2BAN"
echo "============================================================"
systemctl enable fail2ban
systemctl restart fail2ban

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'Private SSH Port'
ufw allow ${RDP_PORT}/tcp comment 'Private XRDP Desktop'
ufw --force enable

echo "============================================================"
echo "  [10/10] DIRECTORY STRUCTURE & PERMISSIONS"
echo "============================================================"
mkdir -p /opt/knox /var/knox/data /var/knox/logs /var/knox/staging
chown -R ${TRADER_USER}:${TRADER_USER} /opt/knox /var/knox
chmod 700 /var/knox/staging

echo ""
echo "============================================================"
echo "  SETUP COMPLETE! SET YOUR DESKTOP PASSWORD NOW"
echo "============================================================"
echo "Enter a strong password for user '${TRADER_USER}':"
passwd ${TRADER_USER}

echo ""
echo "------------------------------------------------------------"
echo "SUCCESS! How to connect from your Windows PC:"
echo "1. Remote Desktop (Win + R -> mstsc)"
echo "2. Computer: YOUR_SERVER_IP:${RDP_PORT}"
echo "3. Username: ${TRADER_USER}"
echo "------------------------------------------------------------"
