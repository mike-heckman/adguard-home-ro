# AdGuard Pi Golden Image Setup

This guide details how to create a "Golden Image" for an AdGuard node. This image can be flashed to any SD card, and uniquely configured via simple text files placed on the `boot` partition (which is easily accessible from any Windows, Mac, or Linux computer).

## Part 1: Building the Golden Node

1. Flash a small (e.g., 8GB) MicroSD card with **Raspberry Pi OS Lite (64-bit)**.
2. Boot it in a Raspberry Pi and connect via SSH.
3. **Hardware Optimization:** Disable unused hardware (Wi-Fi, Bluetooth, HDMI) for power and heat reduction:
   ```bash
   sudo vim /boot/firmware/config.txt
   ```
   Add these lines to the very bottom:
   ```text
   dtoverlay=disable-wifi
   dtoverlay=disable-bt
   hdmi_blanking=1
   ```
4. Install the standard dependencies:
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y curl git htop vim ufw apache2-utils
   ```
4. Grant the `adguard` user passwordless sudo (essential for remote management since the password randomizes on boot):
   ```bash
   echo "adguard ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_adguard-nopasswd
   ```
5. Install AdGuard Home:
   ```bash
   curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
   ```

### Creating the AdGuard Sync Trigger Service

Create a generic sync trigger service. The IP/Port here don't matter, as our first-boot script will overwrite them later based on what the user puts in the boot partition.

1. `sudo vim /etc/systemd/system/adguard-sync-trigger.service`
2. Add the configuration from [`../files/adguard-sync-trigger.service`](../files/adguard-sync-trigger.service). If you are building this from the repository, you can copy it directly:
   ```bash
   sudo cp ../files/adguard-sync-trigger.service /etc/systemd/system/adguard-sync-trigger.service
   ```
3. Enable the service: `sudo systemctl enable adguard-sync-trigger.service`

### Creating the First-Boot Automator Script

This script will run every time the Pi boots. It will look at the `boot` partition (mounted at `/boot/firmware` in the OS) for custom configuration files. If it finds them, it injects the configuration and disables them.

1. Create the script: `sudo vim /usr/local/bin/bootstrap-node.sh`
2. Copy the script from [`../files/bootstrap-node.sh`](../files/bootstrap-node.sh):
   ```bash
   sudo cp ../files/bootstrap-node.sh /usr/local/bin/bootstrap-node.sh
   ```
3. Make it executable: `sudo chmod +x /usr/local/bin/bootstrap-node.sh`

4. Create a systemd service to run this early in the boot process by copying it from [`../files/bootstrap-node.service`](../files/bootstrap-node.service):
   ```bash
   sudo cp ../files/bootstrap-node.service /etc/systemd/system/bootstrap-node.service
   ```
5. Enable the bootstrap service: `sudo systemctl enable bootstrap-node.service`

### Creating the Update Trigger Script

This script safely disables the overlay and remounts the boot partition read-write so the auto-update cron can run successfully.

1. Copy the script from [`../files/adguard-update-trigger.sh`](../files/adguard-update-trigger.sh):
   ```bash
   sudo cp ../files/adguard-update-trigger.sh /usr/local/bin/adguard-update-trigger.sh
   ```
2. Make it executable: `sudo chmod +x /usr/local/bin/adguard-update-trigger.sh`

### Configuring System Boot Order & Defaults

Since the bootstrap script generates SSH keys, we must force the SSH daemon to wait for it. We also want to set the default keyboard to US to prevent localization warnings.

1. Create a systemd drop-in for SSH:
   ```bash
   sudo mkdir -p /etc/systemd/system/ssh.service.d
   cat << 'EOF' | sudo tee /etc/systemd/system/ssh.service.d/override.conf
   [Unit]
   After=bootstrap-node.service
   Wants=bootstrap-node.service
   EOF
   ```
2. Set the default keyboard layout to US:
   ```bash
   sudo sed -i 's/XKBLAYOUT="gb"/XKBLAYOUT="us"/' /etc/default/keyboard
   ```

---

## Part 2: Sysprep and Shrink (Creating the \`.img.gz\`)

Now that the OS is perfectly configured, it's time to scrub the unique data and package it.

1. **Scrub the Image (Run on the Pi):**
   ```bash
   sudo truncate -s 0 /etc/machine-id
   sudo rm /var/lib/dbus/machine-id
   sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
   sudo rm /etc/ssh/ssh_host_*
   cat /dev/null > ~/.bash_history
   
   # Mask services that cause boot failures on OverlayFS
   sudo systemctl mask systemd-remount-fs.service
   sudo systemctl mask rpi-setup-loop@var-swap.service
   
   # Enable the read-only overlay right before shutdown
   sudo raspi-config nonint enable_overlayfs
   
   sudo poweroff
   ```

2. **Clone the image from the thumb‑drive to an SD card (Run on your Linux machine)**
   Remove the thumb‑drive (source) from the Pi and insert it into your Linux computer.
   Find both devices with `lsblk` – the thumb‑drive will appear as something like `/dev/sda`
   and the target SD card as `/dev/mmcblk0` (or `/dev/sdX` if you use a USB‑SD reader).
   ```bash
   # CAUTION: double‑check the device names!
   #   source       = /dev/sda   (the thumb‑drive you built on)
   #   destination  = /dev/mmcblk0   (the SD card you want to flash)
   sudo dd if=/dev/sda of=/dev/mmcblk0 bs=4M status=progress conv=fsync
   ```
   The `conv=fsync` flag ensures all buffers are flushed before the command returns.

3. **Shrink the Image:**
   Use the open-source PiShrink script to compress out all the empty space. **CRITICAL:** You must use the `-s` flag to disable auto-expanding! If the image auto-expands on first boot, it injects a script into `/etc/rc.local` that removes itself and reboots. Because OverlayFS is enabled, that removal happens in RAM, meaning it will infinitely reboot forever.
   ```bash
   wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
   chmod +x pishrink.sh
   sudo ./pishrink.sh -s -z ~/adguard-home-ro.img
   ```
   You now have a highly compressed `adguard-home-ro-1.0.0.img.gz` ready to share.

---

## Part 3: Monitoring & Metrics - Prometheus (Optional)

Because your `adguard-home-ro` nodes are stateless and run their logs in volatile RAM, integrating them with an external Prometheus database is the best way to safely retain long-term historical query data.

1. **Enable the Prometheus Exporter in AdGuard**
   Because your sync master is the Source of Truth, you only need to do this once. Log into the adguard-master Web UI, go to **Settings -> General Settings**, scroll to the bottom, and check **Enable Prometheus metrics**. (By default, it will serve these metrics on port 9662).
   
   The `adguardhome-sync` engine will automatically push this configuration to your read-only nodes.

2. **Update your Prometheus Config**
   Add a new scrape job to the `prometheus.yml` file in your monitoring stack:
   ```yaml
   scrape_configs:
     - job_name: 'adguard-nodes'
       scrape_interval: 15s
       metrics_path: '/metrics'
       static_configs:
         - targets: 
           - '172.16.2.20:9662'
           - '172.16.2.21:9662'
   ```

3. **Add a Grafana Dashboard**
   Go into Grafana and import a community dashboard for AdGuard Home. Dashboard ID `13330` or `14371` (from grafana.com/dashboards) are very popular options that will instantly parse those metrics and give you a beautiful, aggregated view of all DNS queries across your entire network!

## Part 4: Provisioning a New Node

The setup and provisioning instructions for deploying a new node using this image have been moved to the main [README.md](../README.md).
