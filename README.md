# AdGuard Home Read-Only Appliance (adguard-home-ro)

A highly resilient, zero-maintenance, read-only AdGuard Home appliance built for the Raspberry Pi.

## Why a Read-Only adguard-home-ro Image?

Running DNS infrastructure on a Raspberry Pi is fantastic, but SD card corruption from constant log writes is a notorious point of failure. This project solves that by transforming a standard Raspberry Pi OS installation into a bulletproof, ephemeral appliance.

**Key Benefits:**
1. **Zero SD Card Wear:** The root filesystem uses OverlayFS (`tmpfs`). All runtime writes, logs, and temp files are written directly into RAM and vanish on reboot. Your SD card acts strictly as read-only boot media.
2. **Immune to Corruption:** Because the disk is never written to during normal operation, sudden power losses will never corrupt the operating system.
3. **Stateless Configuration:** It relies on [adguardhome-sync](https://github.com/bakito/adguardhome-sync) running on a central NAS/server to pull blocklists and settings at boot. If your Pi dies, you simply flash a new SD card and plug it in—zero configuration required.
4. **Self-Updating:** An optional cron job can automatically disable the read-only lock, perform system and AdGuard updates securely in read-write mode, write an update timestamp to `/last-update`, and gracefully lock itself back down.

---

## External Requirements

- An instance of [**adguardhome-sync**](https://github.com/bakito/adguardhome-sync) running on your NAS or another system. This provides the `AdGuardHome.yaml` replica and your custom `adguard-config.txt` over HTTP.
- Network connectivity from the Pi to the sync server (`SYNC_IP`/`SYNC_PORT`).

---

## 1. Flashing the Image

Use the Raspberry Pi Imager to burn the adguard-home-ro image.

1. **Download** the latest [`adguard-home-ro-1.1.0.img.gz`](https://github.com/mike-heckman/adguard-home-ro/releases/download/1.1.0/adguard-home-ro-1.1.0.img.gz) file from the [Releases](https://github.com/mike-heckman/adguard-home-ro/releases) page.
2. Open **Raspberry Pi Imager**.
3. Under **CHOOSE OS**, scroll down to **Use custom** and select your downloaded `adguard-home-ro-1.1.0.img.gz`.
4. Under **CHOOSE STORAGE**, select your target SD card.
   > [!CAUTION]
   > Double-check the selected storage device! Writing to the wrong drive will permanently destroy data.
5. Click **WRITE** and confirm the prompt. Wait for the process and verification to complete.

---

## 2. Pre-Boot Configuration

Before putting the SD card into your Raspberry Pi, you need to configure its initial networking and credentials. 

1. Remove and re-insert the SD card into your computer so the `bootfs` partition mounts.
2. In the root of the `bootfs` partition, create or modify a file named `adguard-config.txt`:
   ```env
   ADGUARD_USERNAME="admin"
   ADGUARD_PASSWORD="my_secret_password"   # Automatically hashed (bcrypt) on first boot
   NODE_HOSTNAME="adguard1"
   STATIC_IP="172.16.2.20"
   ROUTER_IP="172.16.2.1"
   SYNC_IP="172.16.2.39"
   SYNC_PORT="8080"
   UPDATE_CRON="0 3 * * 0"   # Optional: Auto-updates every Sunday at 3:00 AM
   ```
3. (Optional) If you want SSH access via key authentication, drop your public keys into a file named `authorized_keys` in the root of the `bootfs` partition.
4. Safely eject the SD card from your computer.

---

## 3. First Boot & Provisioning

1. Insert the SD card into your Raspberry Pi and power it on.
2. **Wait a few minutes.** During this initial boot, the automated `bootstrap-node.sh` script will:
   - Generate unique SSH host keys and a Machine ID, saving them persistently to the boot partition.
   - Securely hash your plaintext `ADGUARD_PASSWORD` and inject it into the AdGuard configuration.
   - Configure networking and hostname based on your `adguard-config.txt`.
   - Setup the auto-update triggers.
   - Lock the root filesystem into read-only OverlayFS mode.
3. Once complete, you can log into the Pi via SSH, or access the AdGuard Home web console at the `STATIC_IP` you defined using the credentials from your config file.

---

## Auto-Updating Mechanics

If you defined an `UPDATE_CRON` schedule, the Pi will automatically handle system maintenance. 

At the scheduled time, a trigger script will bypass the read-only lock, touch a persistent update flag (`/boot/firmware/adguard-update-pending`), and reboot the Pi in Read-Write mode. Upon booting into Read-Write mode, `bootstrap-node.sh` will intercept the boot process, update all Debian packages (`apt upgrade`), update the AdGuard binary, write a timestamp to `/last-update`, and immediately lock the system back into OverlayFS before rebooting back to normal operations.

If you omit `UPDATE_CRON`, the system will remain strictly read-only forever unless you manually disable the overlay.

---

## Updating / Re-building the adguard-home-ro Image

If you need to make fundamental changes to the underlying OS or scripts (e.g., modifying `bootstrap-node.sh` or installing new apt packages):

1. Boot a Pi from the current adguard-home-ro image.
2. Run `sudo raspi-config nonint disable_overlayfs` and reboot to enter Read-Write mode.
3. Make your desired changes.
4. Run the **Sysprep** steps (see `docs/original/adguard-pi-setup.md`) to scrub unique machine data and shut down.
5. Image the SD card back to your computer.
6. Use PiShrink (https://github.com/Drewsif/PiShrink) **with the `-s -a` options to compress the image and avoid setting up the auto-expand on boot. See docs/adguard-pi-setup.md for more detail.

## Further detail

More information on building an image from scratch or setting up collected logging via prometheus and grafana is available in the [docs/original/adguard-pi-setup.md](docs/original/adguard-pi-setup.md) file.



