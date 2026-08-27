#!/bin/bash

# deps: git

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
	echo "Error: Do not run this script as root. Run as regular user with sudo/doas access." >&2
	exit 1
fi

if command -v doas &>/dev/null; then
	doas="doas"
else
	doas="sudo"
fi

VOID_PACKAGES_DIR="$HOME/void-packages"
BRAVE_DIR="$VOID_PACKAGES_DIR/srcpkgs/brave-bin"
PKG_REPO="$VOID_PACKAGES_DIR/hostdir/binpkgs"

# Clone void-packages if not already present
if [ ! -d "$VOID_PACKAGES_DIR" ]; then
	echo "Cloning void-packages to $VOID_PACKAGES_DIR..."
	git clone https://github.com/void-linux/void-packages "$VOID_PACKAGES_DIR"
else
	echo "$VOID_PACKAGES_DIR already exists, updating..."
	git -C "$VOID_PACKAGES_DIR" pull
fi

echo "Running binary-bootstrap..."
"$VOID_PACKAGES_DIR/xbps-src" binary-bootstrap

# Clone brave-bin if not already present
if [ ! -d "$BRAVE_DIR" ]; then
	echo "Installing Brave browser..."
	git clone https://github.com/soanvig/brave-bin "$BRAVE_DIR"
else
	echo "Brave template already exists, updating..."
	git -C "$BRAVE_DIR" pull
fi

"$VOID_PACKAGES_DIR/xbps-src" pkg brave-bin
$doas xbps-install -y --repository "$PKG_REPO" -ff brave-bin

[ ! -e /usr/local/bin/brave ] && $doas ln -s /opt/brave.com/brave/brave /usr/local/bin/brave

echo "installed! is it there yet? :)"
