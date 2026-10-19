# etcd restore (RKE2) — to test some other time

**Status: NOT TESTED in the lab yet.** The flags below were checked against the RKE2 docs
(https://docs.rke2.io/datastore/backup_restore, page last updated Oct 7 2026). Run it in the lab
before ever relying on it in an outage, and fix this file with whatever actually happens.

## Mental model

- etcd = the cluster's database. A snapshot is a copy of the **whole** database (every namespace, Secret, RBAC, node, plus the cluster CA keys).
- Restore = replace the live database with the snapshot. It is a **node-level** operation on a server node, not a `kubectl` command.
- The cluster goes **back in time**: anything created after the snapshot is gone. The API is down while you do it.
- Velero is the opposite tool: it restores one namespace or object into a running cluster (see `commands.md` Phase 11).

## What RKE2 does during a restore (from the docs)

1. If the snapshot is in S3, download it into the snapshot dir.
2. Decompress it if needed.
3. Move the current etcd files to `/var/lib/rancher/rke2/server/db/etcd-old-<timestamp>/` (so the old data is kept).
4. Extract the snapshot and verify the checksum.
5. Start etcd and remove every member except this node.
6. Write the CA certs and other secrets from the datastore to disk.
7. Print `Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.`

Safety latch: RKE2 creates `/var/lib/rancher/rke2/server/db/reset-flag`, which blocks a second `--cluster-reset` in a row. It is removed when RKE2 starts normally.

## A. Restore from a LOCAL snapshot (single server — the lab)

Snapshots are in `/var/lib/rancher/rke2/server/db/snapshots/`. List them first:

```bash
sudo rke2 etcd-snapshot list
```

Stop RKE2, restore, start RKE2:

```bash
sudo systemctl stop rke2-server
sudo rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<SNAPSHOT-FILE>
sudo systemctl start rke2-server
```

If `config.yaml` has `etcd-s3` set, RKE2 tries to pull from S3 even for a local restore. Add `--etcd-s3=false` to the
`rke2 server` command and keep the full local path.

Only `--cluster-reset` with no restore path just resets etcd to a single member and does **not** restore anything.

## B. Restore from an S3 snapshot

Pass the S3 settings as flags on the `rke2 server` command, and give **only the snapshot filename** as the restore path
(not a full path and not `s3://...`).

```bash
sudo systemctl stop rke2-server
sudo rke2 server --cluster-reset \
  --etcd-s3 \
  --etcd-s3-bucket=<BUCKET> \
  --etcd-s3-endpoint=<HOST:PORT> \
  --etcd-s3-access-key=<KEY> \
  --etcd-s3-secret-key=<SECRET> \
  --etcd-s3-region=<REGION> \
  --etcd-s3-folder=<FOLDER-IF-ANY> \
  --cluster-reset-restore-path=<SNAPSHOT-FILENAME>
sudo systemctl start rke2-server
```

Gotchas from the docs:
- The S3 **config Secret cannot be used for a restore** (`--etcd-s3-config-secret`). The API server is down, so it can't supply the Secret. Credentials must be on the CLI or in `config.yaml`.
- `--etcd-s3-folder` must match where the snapshot was uploaded, or the file won't be found.
- `--etcd-s3-insecure` is for plain `http://` endpoints; `--etcd-s3-bucket-lookup-type=path` forces path-style URLs (needed for Floci).
- On real AWS, the node needs list, get, put and delete permission on the bucket.

Lab (Floci) version, if the lab is set up to write snapshots to S3 (bucket `nimbus-etcd-backup`, creds test/test):

```bash
sudo rke2 server --cluster-reset --etcd-s3 --etcd-s3-endpoint=192.168.122.1:4566 --etcd-s3-insecure --etcd-s3-bucket-lookup-type=path --etcd-s3-bucket=nimbus-etcd-backup --etcd-s3-access-key=test --etcd-s3-secret-key=test --etcd-s3-region=us-east-1 --cluster-reset-restore-path=<SNAPSHOT-FILENAME>
```

(Untested: the lab's RKE2 may not be configured to upload snapshots to S3 yet. Part of the test is to turn that on with
`etcd-s3: true` plus the settings above in `/etc/rancher/rke2/config.yaml`.)

## C. Multiple servers (HA)

1. Do A or B on **one** server only.
2. On every **other** server: stop `rke2-server`, delete `/var/lib/rancher/rke2/server/db`, then start it again so it rejoins.
3. Agents start normally.

## D. Restoring onto NEW hosts

Save `/var/lib/rancher/rke2/server/token` from the old node. Pass it with `--token=<VALUE>` on the restore command
(it decrypts the bootstrap data inside the snapshot). Node objects are inside the snapshot, so delete the stale old nodes afterwards.
If `config.yaml` has a token, it must match, or RKE2 won't start.

## Security (from the docs)

A snapshot contains the cluster CA private keys and all Secrets. Anyone with the file and the join token can extract them.
Only restore snapshots you trust.

## Lab test plan

1. `sudo rke2 etcd-snapshot save --name restore-test` on `nimbus-server-1`; `sudo rke2 etcd-snapshot list`.
2. Create a marker: `kubectl create namespace before-snap` **before** the snapshot, and `kubectl create namespace after-snap` **after** it.
3. Run section A with the `restore-test` snapshot.
4. Expected: `before-snap` exists, `after-snap` is gone.
5. Then repeat with section B once the lab uploads to Floci.
6. Record exact output and timings in `commands.md` as a new phase, and correct anything in this file that was wrong.

## Known error in the prod notes

`InternalAWSInfrastructure/application_cluster/setup-env.md` line 253 says:
`rke2 server --cluster-reset --etcd-snapshot-name snapshot-<timestamp>`.
**That is wrong.** `--etcd-snapshot-name` only sets the base name for *scheduled* snapshots. The restore flag is
`--cluster-reset-restore-path=<snapshot>`. (Not edited there; that repo is outside this lab.)

## Related to DD-1465

If prod's RKE2 `config.yaml` sets `etcd-s3-folder`, RKE2 uploads snapshots into that sub-folder of the shared bucket, and
Velero will mark the location `Unavailable` (the Oct 2026 incident). Worth checking the prod `config.yaml` for that setting.
