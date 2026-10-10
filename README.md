# wg-qr-setup

WireGuard client configurator for Arch Linux / CachyOS: import a connection from a QR-code image, manage `wg-quick` interfaces. Enforces MTU 1280 (fixes TLS/cert breakage on restricted paths).

## Requirements

- `wireguard-tools`, `zbar` (auto-installed via pacman if missing)
- root (`sudo`)

## Usage

```bash
sudo ./wg_setup.sh                 # interactive menu
sudo ./wg_setup.sh import ~/vpn-qr.png wg0
sudo ./wg_setup.sh start wg0
sudo ./wg_setup.sh stop wg0
sudo ./wg_setup.sh restart wg0
sudo ./wg_setup.sh status wg0
sudo ./wg_setup.sh delete wg0 [--yes]
sudo ./wg_setup.sh list
```

Configs live in `/etc/wireguard/<iface>.conf` (mode 600) with `MTU = 1280`.
