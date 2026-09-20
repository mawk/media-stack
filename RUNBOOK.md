# Runbook: Restarting & Rebuilding the Stack

Quick reference for "something's wrong, how do I restart/rebuild this" — as opposed to
`README.md`, which covers first-time setup.

This stack normally runs via the `media-stack.service` systemd unit
(`/etc/systemd/system/media-stack.service`), which always uses `--profile=vpn`. All commands
below assume that profile unless noted.

## 1. Soft restart (try this first)

Restarts containers in place. Fastest option, fixes most "a service is stuck/unresponsive"
problems.

```bash
sudo systemctl restart media-stack.service
```

Equivalent to `docker compose --profile vpn down` followed by `up -d` — this is a **graceful**
stop (containers get SIGTERM and time to shut down cleanly) before recreation.

To restart just one container instead of the whole stack:

```bash
docker compose --profile vpn restart jellyfin
```

Note: There's a script in the scrips/ dir that can be kicked off to do exactly this:
`scripts/restart-stack.sh`

## 2. Full teardown

Stops and removes every container. **Does not touch your data** — everything under
`data/` (movies, config, qBittorrent state, Jellyfin library/db, etc.) is a bind mount from
the host, not a Docker volume, so it survives container removal untouched.

```bash
cd /home/michaelr/media-stack
sudo systemctl stop media-stack.service
```

Or manually, if you're not going through systemd:

```bash
docker compose --profile vpn --profile no-vpn down
```

(Use both profiles together — `vpn` and `no-vpn` share several services, and compose needs
both profiles active to resolve the `vpn` service dependency even when you only care about
one side. See `docker-compose.yml` comments.)

## 3. Full rebuild from scratch

Use this when containers are in a genuinely broken state (corrupted container filesystem,
stuck after an image update, or you just want a clean slate) — not for routine restarts.

```bash
cd /home/michaelr/media-stack
sudo systemctl stop media-stack.service

# Pull latest images for everything in the vpn profile
docker compose --profile vpn pull

# Recreate every container from scratch
docker compose --profile vpn up -d --force-recreate

# Or just start it back up the normal way, which the unit already does on boot:
sudo systemctl start media-stack.service
```

The external Docker network (`mynetwork`, bridge, `172.20.0.0/16`) is recreated
automatically by the systemd unit's `ExecStartPre` if it's missing — you don't need to
create it by hand. If you're running compose manually outside the unit and `mynetwork`
doesn't exist yet:

```bash
docker network create --driver bridge --subnet 172.20.0.0/16 --gateway 172.20.0.1 mynetwork
```

### Gotcha: qBittorrent "WebUI unreachable" after a forced/unclean rebuild

qBittorrent uses a Qt `QLockFile` at
`data/config/qbittorrent/qBittorrent/lockfile` to detect a prior stale instance. If the
*previous* container was killed uncleanly (crashed host, `docker kill`, `docker rm -f` on a
running container) rather than shut down gracefully, that lockfile can be left behind
pointing at a container hostname that no longer exists. The new container then refuses to
start its WebUI and silently crash-loops (nothing useful in `docker logs`, only in
`data/config/qbittorrent/qBittorrent/logs/qbittorrent.log`).

Fix — delete the lockfile directly on the host (no need to `docker exec`, since it's a bind
mount) and restart:

```bash
rm -f /home/michaelr/media-stack/data/config/qbittorrent/qBittorrent/lockfile
docker restart qbittorrent
```

A graceful stop (`systemctl stop media-stack.service` / `docker compose down`, both used
above) lets qBittorrent clean up this file itself on exit, so this normally doesn't come up
— it's specifically an *unclean shutdown* risk.

## 4. Checking what's actually running

```bash
docker compose --profile vpn ps
docker logs <container> --tail 100
docker logs <container> -f          # follow live
```

Container names match the service names in `docker-compose.yml` (`jellyfin`, `vpn`,
`qbittorrent`, `radarr`, `sonarr`, `prowlarr`, `seerr`, `nginx`, `flaresolverr`). The
`recommendarr` service is a separate opt-in profile, not started by `media-stack.service` —
start it explicitly with `docker compose --profile recommendarr up -d` if you want it.

## Note on the 2026-08-22 NVIDIA driver incident

None of the above would have prevented that specific failure — it wasn't a Docker/compose
problem, it was the host's NVIDIA driver being mid-upgrade (`pacman` had torn down the old
kernel module before the new one finished building), so `/dev/dri/card1` briefly didn't
exist. No amount of `docker compose down`/`up` fixes a missing device node; only finishing
the driver install (and ideally a reboot) does.

What *would* have helped: knowing that's what a `CDI device injection failed: ... no such
file or directory` error means, so the instinct is "check `pacman -Qi nvidia-open-dkms` and
`journalctl -u docker`" instead of "start ripping GPU passthrough out of the compose file."
If you hit that error again:

```bash
# Confirm the driver is actually mid-update / mismatched
pacman -Qi nvidia-open-dkms
journalctl -u docker --since "10 min ago" | grep -i cdi

# Once the driver package has finished installing, regenerate the CDI spec
# and restart Docker so it picks up the new device nodes (or just reboot):
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo systemctl restart docker
sudo systemctl restart media-stack.service
```

## Note on the 2026-09-20 stale CDI spec incident

Jellyfin sat in `Created` (exit 127) and `nginx` crash-looped with `host not found in upstream
"jellyfin"`. Root cause was in `journalctl -u media-stack.service`:

```
failed to fulfil mount request: open /usr/lib/libnvidia-egl-wayland.so.1.1.21: no such file or directory
```

A pacman upgrade bumped `nvidia-utils` and `egl-wayland`/`egl-wayland2`, but `/etc/cdi/nvidia.yaml`
still pointed at the old library filenames. The packaged `nvidia-ctk-cdi.hook` doesn't regenerate
the spec — it only string-substitutes the `nvidia-utils` version number — so renamed libs, device
majors and new libs were missed. nginx was just collateral; fix Jellyfin and it recovers.

Quick diagnosis — any spec entry that no longer exists on disk means the spec is stale:

```bash
grep -oP 'hostPath: \K\S+' /etc/cdi/nvidia.yaml | while read -r p; do [ -e "$p" ] || echo "MISSING: $p"; done
```

### Auto-regenerating the CDI spec (pacman hook)

`scripts/pacman-hooks/` holds a hook that does a full `nvidia-ctk cdi generate` after NVIDIA/EGL
package upgrades, so this can't recur silently:

- `nvidia-cdi-regen` — generates into a temp dir, refuses to install the result if it's empty or
  references files that don't exist (the old spec stays in place), then atomically replaces
  `/etc/cdi/nvidia.yaml`.
- `zz-nvidia-cdi-regen.hook` — triggers on `nvidia-utils`, `nvidia-container-toolkit`,
  `libnvidia-container`, `opencl-nvidia`, `egl-gbm`, `egl-wayland`, `egl-wayland2`. The `zz-` prefix
  is deliberate: pacman runs hooks in filename order and this must run *after* the packaged
  `nvidia-ctk-cdi.hook`.

**Install** (needs root; re-run this if you change either file in the repo):

```bash
cd ~/media-stack
sudo install -Dm755 scripts/pacman-hooks/nvidia-cdi-regen /usr/local/bin/nvidia-cdi-regen
sudo install -Dm644 scripts/pacman-hooks/zz-nvidia-cdi-regen.hook /etc/pacman.d/hooks/zz-nvidia-cdi-regen.hook
```

`/etc/pacman.d/hooks/` is pacman's default `HookDir`; you don't need to edit `pacman.conf` (just
make sure the `HookDir` line there is still commented out or points at that directory).

The same script is also the manual fix for a stale spec right now:

```bash
sudo /usr/local/bin/nvidia-cdi-regen
sudo systemctl restart media-stack.service   # add `sudo systemctl restart docker` first if Jellyfin still fails
```

**Verify the install:**

```bash
# 1. Both files are in place, and identical to the repo copies (no output from diff = good)
ls -l /usr/local/bin/nvidia-cdi-regen /etc/pacman.d/hooks/zz-nvidia-cdi-regen.hook
diff ~/media-stack/scripts/pacman-hooks/nvidia-cdi-regen /usr/local/bin/nvidia-cdi-regen
diff ~/media-stack/scripts/pacman-hooks/zz-nvidia-cdi-regen.hook /etc/pacman.d/hooks/zz-nvidia-cdi-regen.hook

# 2. It sorts after the packaged hook (zz-... must be the last line)
printf '%s\n' /usr/share/libalpm/hooks/nvidia-ctk-cdi.hook /etc/pacman.d/hooks/zz-nvidia-cdi-regen.hook | xargs -n1 basename | sort

# 3. Dry run against a scratch path (no root; real spec untouched). Expect "regenerated ..."
mkdir -p /tmp/cditest && CDI_SPEC=/tmp/cditest/nvidia.yaml /usr/local/bin/nvidia-cdi-regen

# 4. The live spec has no dangling references (no MISSING lines = good)
grep -oP 'hostPath: \K\S+' /etc/cdi/nvidia.yaml | while read -r p; do [ -e "$p" ] || echo "MISSING: $p"; done

# 5. The GPU stack actually starts
docker inspect jellyfin --format '{{.State.Status}}'     # expect: running
docker compose --profile vpn ps
```

**Verify it fires on a real upgrade** (after the next `pacman -Syu` that touches an NVIDIA/EGL
package — the only end-to-end test, since it can't be triggered without a real transaction):

```bash
grep -E "nvidia-ctk-cdi.hook|zz-nvidia-cdi-regen.hook|nvidia-cdi-regen" /var/log/pacman.log | tail
```

Expect `running 'nvidia-ctk-cdi.hook'...` followed by `running 'zz-nvidia-cdi-regen.hook'...` and
`nvidia-cdi-regen: regenerated /etc/cdi/nvidia.yaml`, in that order. Then run check 4 and confirm
Jellyfin is `running`. If you instead see `nvidia-cdi-regen: ... keeping existing`, the old spec
was preserved on purpose: the usual cause is the new driver's kernel module not being loaded yet,
so reboot and run `sudo /usr/local/bin/nvidia-cdi-regen`.
