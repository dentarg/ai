# Troubleshooting

[README](../README.md)

## Attach to a container or VM

```shell
bin/pod                # list running containers
bin/pod last           # shell in the newest container
bin/pod <container>    # shell in a specific container
bin/vm                 # shell in a VM for the current project
bin/vm list
```

Use `--keep-vm` when launching a VM you want to inspect after exit. See
[virtual machines](virtual-machines.md) for failed builds and guest diagnostics.

## mitmproxy

Start it capturing everything:

```bash
mitmdump --mode regular --listen-port 8080 --ssl-insecure --set flow_detail=3 -w claude.flow
```

mitmproxy generates its CA at `~/.mitmproxy/mitmproxy-ca-cert.pem` on first run.

```bash
export NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem
export HTTPS_PROXY=http://127.0.0.1:8080
```

Start the agent

```bash
claude
```

Output the (partially) binary dump as text (`--mode` picking another port is important if proxy already running)

```bash
mitmdump --mode regular@8082 --set flow_detail=3 -r claude.flow --set export_format=curl
```

## Network and Podman diagnostics

`tcpdump`

```shell
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN --net=container:<container> nicolaka/netshoot tcpdump -i eth0
```

`podman`

```shell
# to see current settings
podman machine inspect

# when we can't build because we're out of space
podman system prune --all

# initial setup, or after `podman machine reset`:
# inits the VM (300 GB disk, 8 GB RAM), enables zram swap, and persists
# kernel.keys.maxkeys / maxbytes so we don't hit the keyring quota
# ("crun: join keyctl ... Disk quota exceeded")
bin/setup-vm
```
