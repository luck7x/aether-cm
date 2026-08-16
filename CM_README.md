# Aether CM

This private mirror tracks the official Aether repository and adds reproducible
Linux amd64 build and VPS deployment tooling under `.cm/`.

## Recommended: GitHub Actions build

1. Open the repository's **Actions** page.
2. Select **CM Build Linux amd64**.
3. Choose **Run workflow**.
4. The workflow uploads an Actions artifact and automatically creates a
   private prerelease tagged `cm-<commit-sha>`.
5. Download the `.tar.gz` release bundle from the prerelease, or let the VPS
   fetch it through the GitHub API with a repository-scoped token.

Upload and install from WSL2 or Linux:

```bash
./.cm/upload-and-install.sh root@YOUR_VPS_IP dist-cm/aether-*.tar.gz
```

The VPS installer backs up PostgreSQL and `/etc/aether/aether-gateway.env`,
installs into a new `/opt/aether/releases/` directory, switches the
`/opt/aether/current` symlink, checks `/health` and `/readyz`, and automatically
rolls back the code symlink if startup fails.

## Local WSL2 build

Use Ubuntu under WSL2 with at least 8 GB memory and 10 GB free disk space:

```bash
./.cm/build-linux-amd64.sh
```

For a lower-memory build:

```bash
CM_LOW_MEMORY=1 ./.cm/build-linux-amd64.sh
```

Artifacts are written to `dist-cm/`.

## Sync official updates

```bash
./.cm/update-upstream.sh
```

Review and build the merge before pushing it to the private `origin` remote.
The official repository is configured as `upstream`.

## Data boundaries

Do not commit any of the following:

- `/etc/aether/aether-gateway.env`
- PostgreSQL dumps
- provider or user API keys
- WebDAV credentials
- production logs or backups
