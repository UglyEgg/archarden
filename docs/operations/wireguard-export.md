# WireGuard Export

`wg export` creates a bundle of client configs for download and import.

## Design intent

The admin plane is expected to be VPN-first. Exporting configs cleanly is therefore a first-class operational need, not an afterthought.

## Common gotchas

- wrong `AllowedIPs` generation breaks routing
- provider firewall blocks UDP 51820
- client resolves service names incorrectly
- operator tests browser access before confirming handshake state
