#!/bin/bash

[ -f "/boot/firmware/adguard-update-pending" ] && RUNNING_READWRITE=true
CONFIG_FILE="/boot/firmware/adguard-config.txt"
SSH_KEYS="/boot/firmware/authorized_keys"
SYSTEM_KEYS="/boot/firmware/ssh_keys"

# 1. Local Fallback Password Generation
# Generate a new random password on every boot (writes to RAM if in read-only mode)
LOCAL_PASS=$(openssl rand -base64 9)
echo "adguard:$LOCAL_PASS" | chpasswd

# Display the password on the HDMI console login screen
# Use /etc/issue.d/ for a cleaner drop-in approach supported by agetty
mkdir -p /etc/issue.d
echo -e "Local Console Password: $LOCAL_PASS\n" > /etc/issue.d/adguard.issue
chmod 0600 /etc/issue.d/adguard.issue

# 2. Inject SSH Keys if they exist
if [ -f "$SSH_KEYS" ]; then
    mkdir -p /home/adguard/.ssh
    touch /home/adguard/.ssh/authorized_keys
    
    # Append keys only if they are not already present
    while IFS= read -r key; do
        if [ -n "$key" ] && ! grep -qF "$key" /home/adguard/.ssh/authorized_keys; then
            echo "$key" >> /home/adguard/.ssh/authorized_keys
        fi
    done < "$SSH_KEYS"
    
    chown -R adguard:adguard /home/adguard/.ssh
    chmod 700 /home/adguard/.ssh
    chmod 600 /home/adguard/.ssh/authorized_keys
fi

# 3. Apply Custom Node Configuration if it exists
if [ -f "$CONFIG_FILE" ]; then
    # Read the variables from the config file
    source "$CONFIG_FILE"
    
    # Apply Static IP via NetworkManager
    if [ -n "$STATIC_IP" ] && [ -n "$ROUTER_IP" ]; then
        nmcli c mod "Wired connection 1" ipv4.addresses "$STATIC_IP/24" ipv4.gateway "$ROUTER_IP" ipv4.dns "$ROUTER_IP" ipv4.method manual
        nmcli c up "Wired connection 1"
    fi

    # Update Sync Trigger Target
    if [ -z "${RUNNING_READWRITE}" ] && [ -n "$SYNC_IP" ] && [ -n "$SYNC_PORT" ]; then
        sed -i "s/http:\/\/.*\/api/http:\/\/$SYNC_IP:$SYNC_PORT\/api/" /etc/systemd/system/adguard-sync-trigger.service
        systemctl daemon-reload
    fi
     # Set AdGuard Web UI Credentials
     if [ -z "${RUNNING_READWRITE}" ] && [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
         RESTART_ADGUARD=false
         
         if [ -n "$ADGUARD_USERNAME" ]; then
             sed -i "s/name: .*/name: $ADGUARD_USERNAME/" /opt/AdGuardHome/AdGuardHome.yaml
             RESTART_ADGUARD=true
         fi
         
         if [ -n "$ADGUARD_PASSWORD" ]; then
             if [[ "$ADGUARD_PASSWORD" != \$2* ]]; then
                 # Generate bcrypt hash (extracting just the hash part)
                 BCRYPT_HASH=$(htpasswd -B -n -b u "$ADGUARD_PASSWORD" | cut -d ':' -f 2)
                 RAW_PASSWORD=true
             else
                 BCRYPT_HASH="$ADGUARD_PASSWORD"
             fi
             
             ESCAPED_HASH=$(printf '%s\n' "$BCRYPT_HASH" | sed -e 's/[\/&]/\\&/g')
             sed -i "s/password: .*/password: $ESCAPED_HASH/" /opt/AdGuardHome/AdGuardHome.yaml
             RESTART_ADGUARD=true
         fi
         
         if [ "$RESTART_ADGUARD" = true ]; then
             systemctl restart --no-block AdGuardHome
         fi
     fi
     
     # Set Hostname
    if [ -n "$NODE_HOSTNAME" ]; then
        CURRENT_HOSTNAME=$(cat /etc/hostname)
        hostnamectl set-hostname "$NODE_HOSTNAME"
        sed -i "s/$CURRENT_HOSTNAME/$NODE_HOSTNAME/g" /etc/hosts
    fi

    # Configure Auto-Update Cron (Overlay FS aware)
    if [ -z "${RUNNING_READWRITE}" ] && [ -n "${UPDATE_CRON}" ]; then
        # Phase 1: Cron triggers the script to disable overlay, set flag, and reboot
        echo "${UPDATE_CRON} root /usr/local/bin/adguard-update-trigger.sh" > /etc/cron.d/adguard-update
        chmod 0644 /etc/cron.d/adguard-update
    fi
fi

if [ -d "${SYSTEM_KEYS}" ]; then
    # Subsequent Boots: Restore keys from boot partition
    cp ${SYSTEM_KEYS}/ssh_host_* /etc/ssh/ 2>/dev/null || true
    chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    cp ${SYSTEM_KEYS}/machine-id /etc/machine-id 2>/dev/null || true
fi

if [ ! -d "${SYSTEM_KEYS}" ] || [ -n "${RAW_PASSWORD}" ] || [ -n "${RUNNING_READWRITE}" ]; then
    # Temporarily remount boot partition as read-write for first-boot initializations
    mount -o remount,rw /boot/firmware 2>/dev/null || true

    if [ -n "${RAW_PASSWORD}" ]; then
        # Overwrite plaintext in the config file with the hash
        ESCAPED_HASH=$(printf '%s\n' "$BCRYPT_HASH" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/^ADGUARD_PASSWORD=.*/ADGUARD_PASSWORD=\"$ESCAPED_HASH\"/" "$CONFIG_FILE"
    fi

    # 0. Persist SSH Host Keys and Machine ID
    if [ ! -d "${SYSTEM_KEYS}" ]; then
        # First Boot: Generate keys and save to boot partition
        ssh-keygen -A
        systemd-machine-id-setup
        mkdir -p "${SYSTEM_KEYS}"
        cp /etc/ssh/ssh_host_* "${SYSTEM_KEYS}/" 2>/dev/null || true
        cp /etc/machine-id "${SYSTEM_KEYS}/" 2>/dev/null || true
    fi

    if [ -n "${RUNNING_READWRITE}" ]; then
        # Clear the flag
        # Record the update time
        rm -f /boot/firmware/adguard-update-pending
    fi

    # Lock the boot partition back to read-only
    mount -o remount,ro /boot/firmware 2>/dev/null || true
fi
    
# 4. Handle Phase 2 of Overlay FS Updates
if [ -n "${RUNNING_READWRITE}" ]; then
    echo "Running system updates now..."
    # Wait for network connectivity
    echo "Waiting for network connectivity..."
    until ping -c1 8.8.8.8 &>/dev/null; do sleep 5; done
    
    # Run updates (System packages + AdGuard Home binary)
    echo "Updating system packages..."
    apt-get update && apt-get upgrade -y

    echo "Updating AdGuard Home..."
    /opt/AdGuardHome/AdGuardHome -s update
    
    # Record the update time
    date > /last-update
    chmod 0644 /last-update
    
    # Clear the flag, re-enable overlay, and lock it back down
    echo "Setting system back into overlayfs..."
    raspi-config nonint enable_overlayfs

    echo "Rebooting to complete the update..."
    reboot
fi
