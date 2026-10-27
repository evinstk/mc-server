# Minecraft (Paper) on Oracle Cloud Always Free ARM

Files here:

| File | Purpose |
|---|---|
| `docker-compose.yml` | Paper server (`itzg/minecraft-server`) + restic backup sidecar (`itzg/mc-backup`) + Caddy proxy for the BlueMap web UI |
| `Caddyfile` | HTTPS + basic auth in front of BlueMap (`minecraft.tannerevins.com`) |
| `.env.example` | Template for secrets/settings. Copy to `.env` on the server |
| `scripts/server-setup.sh` | Run on the VM: installs Docker, opens iptables, persists it |

## Read first: Oracle caveats

**1. Capacity lottery.** A1 instances often fail with `Out of host capacity`, especially in Ashburn and Phoenix.
- Your **home region is permanent**, chosen at signup. US options: Ashburn, Phoenix, San Jose, Chicago. San Jose and Chicago are usually less contended, so pick by capacity first, then latency to your players.
- Try different **availability domains** (if the region has several) and try smaller shapes (e.g. 2 OCPU / 12 GB), which you can resize later.
- Retrying at off-peak hours helps. Scripted retry via the OCI CLI is common if the console keeps failing.
- **Upgrading the account to Pay As You Go** (credit card, still $0 if you stay inside Always Free limits) is the most effective fix. PAYG accounts get A1 capacity far more reliably, and it also removes the reclamation risk below. Set a budget alert at $1 as a guardrail.

**2. Idle reclamation.** Oracle may reclaim Always Free compute instances that are idle for 7 days, defined as the 95th-percentile of CPU, network, and (for A1) memory utilization all under 20%.
- A Paper server with a 10 GB heap and `AlwaysPreTouch` (part of Aikar flags) will probably stay above 20% memory, but don't count on it.
- Real fix: upgrade to PAYG (reclamation applies to Always Free tenancies). Verify the current policy in Oracle's docs, since it has changed before.
- Also: Oracle can terminate accounts/instances, so **off-platform backups are not optional**.

**3. Other gotchas**
- Keep within Always Free totals: 4 OCPU / 24 GB A1 total, 200 GB block storage total (boot volume counts), 10 TB/month egress.
- Use a **Reserved public IP** (free while attached) so the address survives instance recreation.
- Ubuntu images on OCI have a restrictive iptables INPUT chain *in addition to* the VCN security list. Both must allow 25565 (steps 3 and 4).

## Step 1: Account and region

1. Sign up at oracle.com/cloud/free. Choose your home region carefully (see above).
2. Optional but recommended: Billing > Upgrade to Pay As You Go. Create a budget with a $1 alert.

## Step 2: Create the instance

Console > Compute > Instances > Create instance:
- **Image**: Canonical Ubuntu 24.04 (aarch64) (Change image > Ubuntu).
- **Shape**: Ampere > `VM.Standard.A1.Flex`, **4 OCPU / 24 GB**.
- **Networking**: create new VCN/public subnet (the wizard does this), **assign public IPv4**.
- **SSH keys**: upload your public key (`~/.ssh/id_ed25519.pub`) or let Oracle generate one.
- **Boot volume**: 100-200 GB (custom size).
- Create. If you hit `Out of host capacity`, see caveat 1.

Then: Networking > IP management > Reserved public IPs > create one, and attach it to the instance's VNIC (detach the ephemeral one first via the instance's VNIC > IPv4 addresses > Edit).

## Step 3: Open 25565 in the VCN security list

Networking > Virtual cloud networks > your VCN > Subnets > public subnet > Security > default security list > **Add ingress rules**:
- Source type CIDR, Source CIDR `0.0.0.0/0`
- IP protocol TCP, Destination port `25565`, source port left blank

(Bedrock/Geyser would need UDP 19132; not needed for Java.)

## Step 4: SSH in, install Docker, open iptables

```fish
# from your Mac, in this directory
set IP <reserved-public-ip>
rsync -av --exclude data --exclude .env --exclude secrets ./ ubuntu@$IP:~/mc-server/
ssh ubuntu@$IP
```

On the server:
```bash
cd ~/mc-server
bash scripts/server-setup.sh
exit    # log out and back in so the docker group applies
```

Verify the rule sits *above* the REJECT line: `sudo iptables -L INPUT -n --line-numbers`.

## Step 5: Configure and start

```bash
ssh ubuntu@$IP
cd ~/mc-server
cp .env.example .env
nano .env                       # whitelist, ops, rcon password, backup creds
docker compose up -d
docker compose logs -f mc       # wait for "Done (...)! For help, type "help""
```

Test from your Mac: `nc -vz $IP 25565`, then connect with the Minecraft client.
(Whitelist is on; add players live with `docker compose exec mc rcon-cli whitelist add Name`.)

## Step 6: Off-platform backups

1. Use your existing GCS bucket (Standard class is fine; the repo lives under the `mc-server/` prefix). Create a dedicated service account with `roles/storage.objectAdmin` on **that bucket only**, then download a JSON key:
   ```fish
   gcloud iam service-accounts create mc-backup --project YOUR_PROJECT
   gcloud storage buckets add-iam-policy-binding gs://YOUR_BUCKET \
     --member serviceAccount:mc-backup@YOUR_PROJECT.iam.gserviceaccount.com \
     --role roles/storage.objectAdmin
   gcloud iam service-accounts keys create gcs-key.json \
     --iam-account mc-backup@YOUR_PROJECT.iam.gserviceaccount.com
   ```
   Copy it to the server as `~/mc-server/secrets/gcs-key.json` (`scp`, then `chmod 600`) and delete the local copy. Don't put it in this directory's synced files; `secrets/` is git-ignored but rsync would still send it.
2. Fill `RESTIC_REPOSITORY`, `GOOGLE_PROJECT_ID` and `RESTIC_PASSWORD` in `.env`. Save `RESTIC_PASSWORD` in your password manager too.
3. Restart and test immediately rather than waiting for the interval:
   ```bash
   docker compose up -d
   docker compose exec backup backup now
   docker compose logs backup
   docker compose exec backup restic snapshots
   ```
4. **Test a restore** at least once:
   ```bash
   docker compose exec backup restic restore latest --target /tmp/restore-test
   docker compose exec backup ls /tmp/restore-test/data
   ```
   For a real restore: `docker compose down`, move `data/` aside, restore into a fresh `data/`, `docker compose up -d`.

Defaults: every 2 h (skipped when nobody is online), keeping 24 hourly / 7 daily / 4 weekly / 6 monthly. Adjust `PRUNE_RESTIC_RETENTION` in the compose file.

## Step 7: Tuning

Set in `docker-compose.yml`: `VIEW_DISTANCE=10`, `SIMULATION_DISTANCE=6`.
- Lower view distance first if TPS drops with many players (8 is a good fallback). Simulation distance costs more CPU than view distance, so 6 is a good place to stay.
- Check TPS in-game or console: `docker compose exec mc rcon-cli tps` (Paper).
- Paper-specific knobs live in `data/config/paper-global.yml` and `paper-world-defaults.yml` after first start. Change those only if you see a problem.
- Heap is 10 GB. With 24 GB total you could go to 12-14 GB, but bigger heaps with Aikar flags don't help small servers and increase GC pauses.

## Step 8: BlueMap (3D/isometric web map)

BlueMap is installed as a Paper plugin via `MODRINTH_PROJECTS` in `docker-compose.yml`. Its web UI listens on port 8100, published on the server's loopback only; Caddy exposes it publicly (see below).

1. First start generates the config but won't render until you accept Mojang's client-jar download (BlueMap needs it for textures). On the server:
   ```bash
   docker compose up -d
   sed -i 's/accept-download: false/accept-download: true/' data/plugins/BlueMap/core.conf
   docker compose exec mc rcon-cli bluemap reload
   docker compose exec mc rcon-cli bluemap       # status
   ```
2. Rendering starts on its own once the download is accepted, and afterwards BlueMap re-renders chunks as players change them. Check progress and map IDs with:
   ```bash
   docker compose exec mc rcon-cli bluemap maps    # IDs: world, world_the_nether, world_the_end
   docker compose exec mc rcon-cli bluemap         # status / running tasks
   ```
   To trigger work manually: `bluemap update <map-id>` (changed chunks) or `bluemap force-update <map-id>` (everything). The first full render of a big world can take a long time. RCON output shows raw `§x` colour codes; ignore them.
3. Publish it at https://minecraft.tannerevins.com via Caddy (see "Public access" below). For a quick private look instead, tunnel: `ssh -N -L 8100:localhost:8100 ubuntu@$IP` and open http://localhost:8100.

### Public access (Caddy)

1. **DNS:** A record `minecraft.tannerevins.com` pointing at the reserved public IP.
2. **VCN security list:** add ingress rules for TCP 80 and 443 from `0.0.0.0/0` (same steps as 25565). Port 80 is needed for the Let's Encrypt challenge.
3. **iptables on the VM:** re-run `bash scripts/server-setup.sh` (idempotent; it now opens 80 and 443 too).
4. **Login:** in `.env` set `MAP_USER` and `MAP_PASSWORD_HASH` (keep the single quotes):
   ```bash
   docker run --rm caddy caddy hash-password
   ```
5. `docker compose up -d`, then check `docker compose logs caddy` for the certificate being issued and open the URL. Don't restart repeatedly if it fails; Let's Encrypt rate-limits failed attempts, so confirm DNS and ports first.

BlueMap itself stays bound to loopback; only Caddy is reachable from the internet.

Notes:
- **Isometric look:** the web UI has Flat, Perspective and Free-flight modes. For a true isometric angle, use Perspective and zoom out far, or tilt via the controls. Maps are defined in `data/plugins/BlueMap/maps/*.conf` (one per dimension by default).
- **Visibility:** the public map shows everything explored, including builds and base coordinates. It's behind the Caddy login; hide areas in `data/plugins/BlueMap/maps/*.conf` if needed.
- **Backups:** map tiles live in `data/bluemap/` and are excluded from backups since they're regenerable. Config in `data/plugins/BlueMap/` is still backed up.
- Rendering uses CPU and RAM alongside the game. Run big renders when nobody is online, and use `bluemap stop` / `bluemap start` to pause it if TPS drops.

## Operations

```bash
docker compose logs -f mc                  # logs
docker compose exec mc rcon-cli            # interactive console
docker compose pull && docker compose up -d   # update images (do a backup first)
sudo apt update && sudo apt upgrade -y     # OS updates; reboot occasionally
```
