<h1 align="center">Share Proxmox Backup Server</h1>

![Alice and Bob swap encrypted backups through a direct tunnel](assets/hero.svg)

> _Store your encrypted backups with a friend. Your friend stores their encrypted backups with you._

Swap encrypted Proxmox Backup Server (PBS) backups with friends. Your Proxmox host backs up to your own PBS server. Your PBS server pushes the backups to the PBS server of your friend.

Each person runs one PBS server in an LXC container. Tailscale connects the two PBS servers. The backup data goes directly between them in an encrypted tunnel.

Your Proxmox host encrypts the backups before they leave the host. Your friend stores them and cannot read them.

In your PBS, make one remote and one push sync job for each friend that stores your backups. Two friends give you two offsite copies.

## ✔ Requirements before start

Make sure you have the following (PBS LXC container) installed and a Tailscale account:

- [Proxmox Backup Server](https://community-scripts.org/scripts/proxmox-backup-server) 3.3 or later.
- [Tailscale](https://tailscale.com/download/linux) account

> This guide only helps you to configure PBS assuming that is an LXC. It does not install it, you need to do it before hand ⤴.

## 1️⃣ Start on your Proxmox host (assuming PBS is an LXC)

As a container shares the kernel of the host. Only the host can give it `/dev/net/tun`.

_Make sure the host has the device_

```
ls -l /dev/net/tun || modprobe tun
```

_Add the device to the PBS LXC container and reboot it. Set `PBS_CTID` to the container ID_

```bash
PBS_CTID=<id of pbs>
```

```bash
grep -q net/tun /etc/pve/lxc/$PBS_CTID.conf || printf "%s\n" \
  "lxc.cgroup2.devices.allow: c 10:200 rwm" \
  "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" \
  >> /etc/pve/lxc/$PBS_CTID.conf
pct reboot $PBS_CTID
```

## 2️⃣ On PBS:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/frangeris/share-pbs/main/setup-pbs.sh)"
```

The script asks for two folders: one for your backups and one for the backups of your friend. Enter a mounted folder or a folder in the container. If a folder does not exist, the script makes it.

## 3️⃣ Permissions (Tailscale)

> [!CAUTION]
> Disable key expiry on the PBS node. If a key expires, the backups stop.

In the Tailscale admin console, go to **Machines** and disable key expiry on the PBS node.

Go to **Access controls** and open the JSON editor. Delete the allow-all grant `{"src": ["*"], "dst": ["*"], "ip": ["*"]}` and add these entries:

```json
"grants": [
    ...
    {"src": ["autogroup:shared"], "dst": ["<replace pbs ip>"], "ip": ["8007"]},
],

"tests": [
    ...
    {"src": "<your email>", "accept": ["<replace pbs ip>:8007"]},
],
```

Replace the placeholders with your Tailscale email and the Tailscale IP of the PBS node.

> [!IMPORTANT]
> Do not tag the PBS node. A tagged node cannot connect to the node that your friend shares with you.
>
> Go back to **Machines**. Share the PBS node with your friend and accept the PBS node that your friend shares with you.

## 4️⃣ Make the datastores

In the PBS web interface:

1. Go to **Datastore**. Select **Add Datastore**. Enter a name and enter the folder for your backups as **Backing Path**. This is the local datastore. It stores your backups.
2. Make a second datastore with the folder for the backups of your friend as **Backing Path**. This is the incoming datastore. It stores the backups of your friend.

   ![Add a datastore](assets/pbs-add-datastore.png)

## 5️⃣ Connect Proxmox to PBS

In the PBS web interface:

1. Go to **Configuration**, **Access Control**, **User Management**. Select **Add** and make a user for Proxmox.

   ![Add a PBS user](assets/pbs-add-user.png)

2. Go to **Permissions**. Select **Add**, **User Permission**. Enter the path `/datastore/<local datastore>`, the user, and the role `DatastoreBackup`.

   ![Add the permission](assets/pbs-add-permission.png)

3. Go to **Dashboard**. Select **Show Fingerprint** and copy the fingerprint.

   ![Show the fingerprint](assets/pbs-fingerprint.png)

In the Proxmox web interface:

4. Go to **Datacenter**, **Storage**, **Add**, **Proxmox Backup Server**.
5. Enter an ID, the IP of your PBS, the user `<user>@pbs`, the password, the name of the local datastore, and the fingerprint.
6. Select **Auto-generate a client encryption key** and select **Add**.

   ![Add the PBS storage](assets/pve-add-storage.png)

> [!CAUTION]
> Without an encryption key, your friend can read the backups. If you lose the key, you cannot read the backups.
> Save `/etc/pve/priv/storage/<ID>.enc` in a safe place.

## 6️⃣ Make a backup job

1. Go to **Datacenter**, **Backup**. Select **Add**.
2. In **Storage**, select the PBS storage.
3. Select the schedule. Select a small VM or container for the first test.
4. Select **Create**.

   ![Add the backup job](assets/pve-add-backup-job.png)

5. Select the job and select **Run now**.

   ![Run the backup job](assets/pve-run-backup-job.png)

6. Select the PBS storage and go to **Backups**. Make sure that the backup is in the list.

   ![Backups in the storage](assets/pve-backups-list.png)

## 7️⃣ Send the backups to your friend

In the PBS web interface:

1. Go to **Configuration**, **Access Control**, **User Management**. Select **Add** and make a user for your friend.
2. Go to **Permissions**. Select **Add**, **User Permission**. Enter the path `/datastore/<incoming datastore>`, the user of your friend, and the role `DatastoreBackup`.
3. Send these values to your friend privately: the user, the password, the name of the incoming datastore, and the fingerprint of your PBS. Get the same values from your friend.
4. Go to **Configuration**, **Remotes**. Select **Add**. Enter an ID, the Tailscale IP of the PBS node of your friend, the user, the password, and the fingerprint. Find the IP in **Machines** in the Tailscale admin console.

   ![Add the remote](assets/pbs-add-remote.png)

5. Go to **Datastore** and select the local datastore. Go to **Sync Jobs**. Select **Add** and make a push sync job. Select the remote, enter the name of the incoming datastore of your friend, and set the schedule. Select the option `encrypted-only`.

   ![Add the sync job](assets/pbs-add-sync-job.png)

6. Select the job and select **Run now**. Make sure that the task ends with `TASK OK`.

## 8️⃣ Restore a backup

1. Select the PBS storage and go to **Backups**.
2. Select the backup and select **Restore**.
3. For a test, enter a new ID. Do not restore over the original.

   ![Restore the backup](assets/pve-restore.png)

4. Select **Restore**.

<details>
<summary><h2>Prefer doing a manual install? ↓</h2></summary>

Same steps as the script, by hand.

### PBS LXC

In the PBS LXC, as `root`:

```bash
mkdir -p <folder for your backups> <folder for incoming backups>

# Skip this line if the file does not exist. Without a subscription this repository returns 401.
mv /etc/apt/sources.list.d/pbs-enterprise.sources /etc/apt/sources.list.d/pbs-enterprise.sources.disabled

apt-get update
apt-get install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up
tailscale ip -4
```

Do not tag this node. Do not use `--accept-routes`.

</details>

## Access

- The PBS web interface is at `https://<ip>:8007`.
- For the first login, use the user `root` and the realm `Linux PAM standard authentication`. The password is the `root` password of the LXC. To set it, run `pct exec <CTID> passwd` on the host.
- PBS users are separate from PVE users. In **Configuration**, **Access Control**, make a user `admin@pbs` with the role `Admin` for daily use.

## Recovery

If your PBS server is lost, make a new PBS server. Add the PBS server of your friend as a remote. Make a pull sync job from the incoming datastore of your friend to a new datastore. You need your encryption key.

## Limits

- A restore from the copy of your friend reads the data from the home of your friend. The upload speed of your friend limits the restore time.
- Only the encryption key in PVE protects the backups. The option `encrypted-only` stops the push of backups without encryption.
- The access rules for your user also apply to the PBS node. It can reach your other nodes.
