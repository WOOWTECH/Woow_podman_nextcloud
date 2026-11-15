# N100 deployment fixes and Nextcloud 35 maintenance

The source now pins **Nextcloud 35.0.3-apache**, the version already validated on
the N100 after 34.0.6 and 35.0.1. The original user/data/URLs survived; schema check
returned `[]`; a physical reboot passed. Evidence lives in
WOOWTECH/Woow_ubuntu_version_control, distribution/docs/reboot-acceptance.md and
existing-device-upgrades.md. That evidence applies to the distribution deployment;
the consolidated standalone installer is covered by the source tests below, not a
second production cutover.

## Staged existing-device upgrade

Use `upgrade.sh`, not `install.sh`, for a version transition. First take a full
cold backup; its credentials and user files must stay private.

```sh
scripts/backup.sh --cold
# Current 34.x older than 34.0.6: complete this step first.
WOOW_NEXTCLOUD_IMAGE=docker.io/library/nextcloud:34.0.6-apache scripts/upgrade.sh
# Then use the reviewed default 35.0.3.
scripts/upgrade.sh
```

The override accepts only reviewed 34.0.6 and 35.0.3 Apache images. Existing gates
still refuse downgrades, skipped major versions and PostgreSQL major transitions;
a 34 -> 35 transition before 34.0.6 is refused before downtime. Earlier majors
need their supported intermediate releases. Cold backup and automatic rollback
remain in place. Unrelated apps are no longer silently updated by `app:update
--all`: check compatibility and update them explicitly. Cron now skips runs until
config.php reports installation complete, even if the container already exists.

## Optional Office gateway

Keep the original application port and add a second same-origin gateway. Set the
following in ~/.config/nextcloud/nextcloud.env, using a real reachable authority:

```ini
WOOW_OFFICE_ENABLED=1
OFFICE_BIND=0.0.0.0
OFFICE_PORT=18081
OFFICE_ORIGIN=http://nextcloud.example.test:18081
```

Run `scripts/install.sh`, then `scripts/configure-office.sh`. Add the authority to
Nextcloud's trusted domains with occ for an existing instance. Office and gateway
belong to nextcloud.target: group stop/start and cold-backup recovery include both.
A bounded 2 GiB tmpfs for Collabora's jail avoids document-load refusal when the
root disk is nearly full; it consumes memory, not new data-disk capacity.

The installer generates the Office password as a Podman secret. Backups include
that secret and the gateway configuration. To restore on a new host, restore the
private environment/secrets and install matching units before restoring files
and database. Original app HOST_BIND/HOST_PORT remain unchanged.

Activation installs SHA-pinned richdocuments **12.0.2**, checks archive paths,
types, size, version and compatibility, and invokes Nextcloud's signature check.
It refuses a different installed Office version; upgrading one is an explicit
maintenance operation. application-artifacts.json retains the earlier 12.0.1 pin
for provenance. For Cloudflare/HTTPS, configure trusted proxies and overwrite
settings; the gateway forwards X-Forwarded-Proto, which must come from trusted
frontends. Verify opening, editing and saving a real document at the chosen URL.

## Review-gated maintenance tools

None of these run automatically. Keep a full verified cold backup first.

* `prepare-nextcloud-text.py --server-archive nextcloud-35.0.3.tar.bz2 --output text.tgz`
  extracts official signed Text 9.0.2 from a SHA-pinned server archive. It rejects
  unsafe entries and does not modify running services. After an explicit app
  installation, run `occ integrity:check-app text`.
* `repair-nextcloud-invites.php`: only Nextcloud 35.0.1 missing federated_invites.
  Run inside the app container with Nextcloud bootstrapped. Default SQL preview;
  `--apply` replays one official migration only after checking its planned DDL is
  limited to the missing table, indexes and unique constraint.
* `repair-nextcloud-sharing-index.py --backup /private/full-backup`: only 35.0.3,
  Sharing 1.0.5, the exact obsolete index and an empty legacy table. Default preview;
  `--apply` verifies backup checksums, records rollback DDL, locks the table and
  checks emptiness/constraint ownership before removing just that index. A different
  version or unexpected/nonempty schema is refused, including under `python -O`.

## Tests

Quadlet/systemd dry runs, real installer render/selection tests, original-port
preservation, target membership, invalid URL/port refusal, Office archive rejection,
schema-repair CLI with a Podman double (including refusal under Python optimization),
rootless config backup, legacy rollback and version-reading tests. Physical
multi-application reboot evidence refers to the earlier distribution implementation;
external Office routes and arbitrary third-party apps need deployment-specific
acceptance. No new customer service or credentials were changed for this backport.
