#!/bin/bash

if [ -z "$USERNAME" ]; then
	USERNAME="spirit"
fi

cp /usr/share/xbps.d/*-repository-*.conf /etc/xbps.d/

xbps-install -Suy xbps
xbps-install -uy
xbps-install -y base-system
xbps-remove -y base-voidstrap
xbps-reconfigure -fa

useradd -m -G wheel -s /bin/bash $USERNAME
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

xbps-install -y opendoas
bash -c "echo 'permit nopass $USERNAME as root' > /etc/doas.conf"

if [[ "$1" == "--wsl" ]]; then
cat <<EOF > /etc/wsl.conf
[user]
default=$USERNAME
EOF
fi
