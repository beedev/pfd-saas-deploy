# pfd-saas — deployment

Install and run **pfd-saas**, a personal finance planner for India, with Docker.
The application source is private; this repository holds only what you need to
install and operate it. The app itself is the public image
`ghcr.io/beedev/pfd-saas` (Apple silicon and Intel).

> These files are published automatically from the private source repository
> after every image build. Don't edit them here — changes will be overwritten.

## Mac — one command (recommended)

```bash
curl -fsSLo setup-mac.sh https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/setup-mac.sh
bash setup-mac.sh
```

It will:

1. Install Docker Desktop if it is missing (asks for your Mac password once).
2. Download the image and start the app on http://localhost:3000.
3. On a first install: create your Personal account, turn on the
   Transformation tracker, and optionally save an OpenAI key.
4. Keep it running: Docker starts at login, a watchdog repairs Docker every
   5 minutes if it hangs, and the database is backed up on the 1st of every
   month to `~/pfd-backups`.

**Upgrade:** run `bash setup-mac.sh` again. Your data stays — it lives in the
Docker volume `pfd_saas_data`, which the script never removes.

**Something wrong?** Run the doctor. It reports what is installed, repairs the
setup, and saves a report to `~/Desktop/pfd-doctor-report.txt`:

```bash
curl -fsSLo mac-doctor.sh https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/mac-doctor.sh
bash mac-doctor.sh            # DRY_RUN=1 bash mac-doctor.sh to only look
```

## Linux or any Docker host

```bash
curl -fsSL https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/install.sh | bash
```

Or run the image directly:

```bash
docker run -d --name pfd-saas --restart unless-stopped --stop-timeout 30 \
  -v pfd_saas_data:/data -p 3000:3000 \
  -e AUTH_URL=http://localhost:3000 \
  ghcr.io/beedev/pfd-saas:latest
```

## Security

The default sign-in is a one-click Demo / Personal chooser with **no
password**: anyone who can reach the port can open your data. Keep it on the
machine itself, or put it behind Tailscale or a VPN. Never expose the port to
the internet.

## Files

| file | purpose |
|---|---|
| `setup-mac.sh` | install or upgrade on a Mac |
| `mac-doctor.sh` | diagnose and repair a Mac install |
| `mac/watchdog.sh` | restarts Docker or the app when they hang (installed by `setup-mac.sh`) |
| `mac/backup.sh` | monthly database backup (installed by `setup-mac.sh`) |
| `install.sh` | generic installer for Linux / other Docker hosts |
