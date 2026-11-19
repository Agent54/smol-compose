# smolvm-network

The **host-side userspace network backend** for smolvm's virtio-net path.
It connects guest Ethernet traffic to host sockets through a smoltcp-based
gateway and the libkrun frame bridge.

This crate is intended for runtime integrators. It is not a standalone VPN,
container network manager, or VM launcher. Most users should configure networking
through the [smolvm runtime](https://github.com/smol-machines/smolvm#readme).

## Add to your project

```sh
cargo add smolvm-network
```

## Configure an egress policy

```rust
use smolvm_network::EgressPolicy;
use std::net::{IpAddr, Ipv4Addr};

fn main() {
    let allowed = vec!["203.0.113.0/24".to_string()];
    let policy = EgressPolicy::from_allowed_cidrs(Some(&allowed));
    assert!(policy.is_restricted());
    assert!(!policy.allows(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 1))));
}
```

This example only constructs and queries a policy. It neither connects a guest
nor installs a host firewall. The runtime must apply the policy to traffic.

## How traffic flows

Guest kernel → virtio-net → libkrun frame bridge → shared frame queues →
smoltcp gateway → host sockets.

The crate includes:

- Frame transport and queues between the VM bridge and network runtime.
- TCP and UDP relays, DNS forwarding, and published TCP port handling.
- CIDR/hostname egress-policy support.
- Linux-specific network-namespace/TAP integration.

See `VirtioNetworkRuntime` and its configuration types for embedding. A working
integration must supply the compatible VM-side frame transport and manage the
runtime lifecycle; adding this dependency alone does not enable networking.

On macOS, SmolVM reads the first IPv4 nameserver in the host's `/etc/resolv.conf` when
the VM starts. Host loopback resolvers are supported because DNS forwarding
runs on the host. An explicit `--dns <IPv4>` uses that address instead. Both
modes use the existing UDP/TCP forwarding path and preserve upstream response
bytes. System mode fails if no IPv4 server is configured; it does not substitute
a public resolver. Restart the VM after connecting or disconnecting a VPN to
refresh the snapshot. There is no VPN detection or live resolver bridge.
Existing machines retain their data; the guest and Docker query the gateway.
Use `machine update --name NAME --dns 1.1.1.1` on a stopped machine to set a
custom resolver, or `--system-dns` to clear it. Other platforms retain their
existing DNS defaults. This change does not alter TSI DNS behavior or implement
domain-specific macOS resolver routing.

## Scope and security

This backend is distinct from smolvm's TSI networking path. Availability depends
on the host and runtime configuration; do not infer that every smolvm platform
supports virtio-net from this library's API.

An allowlist is one layer of enforcement, not a complete sandbox. Configure
appropriate host/guest isolation and protect credentials separately.

## Links

[API documentation](https://docs.rs/smolvm-network) · [crates.io](https://crates.io/crates/smolvm-network) · [Source](https://github.com/smol-machines/smolvm/tree/main/crates/smolvm-network)

Part of [Smol Machines](https://github.com/smol-machines/smolvm). Licensed under Apache-2.0.
