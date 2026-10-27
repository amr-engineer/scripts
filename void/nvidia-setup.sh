#!/bin/bash

if command -v doas &> /dev/null; then
	doas="doas"
else
	doas="sudo"
fi

if command -v lspci &> /dev/null && lspci | grep -i nvidia &> /dev/null; then
	echo "NVIDIA GPU detected. Installing NVIDIA drivers..."
	$doas xbps-install -y nvidia nvidia-libs-32bit

	# Add nvidia modules to be loaded at boot
	if ! grep -q "nvidia" /etc/modules-load.d/nvidia.conf 2>/dev/null; then
		$doas mkdir -p /etc/modules-load.d
		$doas sh -c 'printf "nvidia\nnvidia_modeset\nnvidia_uvm\nnvidia_drm\n" > /etc/modules-load.d/nvidia.conf'
	fi

	# Configure Xorg for NVIDIA
	$doas nvidia-xconfig

	# Add nvidia settings to xinitrc
	insert $HOME/.xinitrc 'nvidia-settings' 'nvidia-settings --load-config-only &'

	echo "NVIDIA drivers installed. Reboot required for full functionality."
else
	echo "No NVIDIA GPU detected. Skipping installation."
fi
