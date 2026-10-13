# pfd-saas — deployment

Install and run **pfd-saas**, a personal finance planner for India, with Docker.
The application source is private; this repository holds only what you need to
install and operate it. The app itself is the public image
`ghcr.io/beedev/pfd-saas` (Apple silicon, Intel and AMD — Mac, Windows or Linux).

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

## Windows — one command

Open **PowerShell** (Start menu → type `powershell`) and run:

```powershell
irm https://raw.githubusercontent.com/beedev/pfd-saas-deploy/main/setup-windows.ps1 | iex
```

It does the same seven steps as the Mac script:

1. Installs **WSL 2** if it is missing — Docker on Windows runs Linux
   containers inside it. Windows asks for permission, then you **restart the
   PC and run the command again**; the second run continues from there.
2. Installs Docker Desktop (with `winget`, Windows' built-in installer) and
   starts it. If Docker does not start, sign out of Windows and back in, then
   run the command again.
3. Downloads the image and starts the app on http://localhost:3000.
4. On a first install: creates your Personal account, turns on the
   Transformation tracker, and optionally saves an OpenAI key.
5. Keeps it running: Docker starts when you sign in, a watchdog repairs Docker
   or the app every 5 minutes (Task Scheduler → `pfd-saas` → `watchdog`), and
   the database is backed up on the 1st of every month to
   `%USERPROFILE%\pfd-backups`.

**Upgrade:** run the same command again. Your data stays in the Docker volume
`pfd_saas_data`.

**Logs:** `%USERPROFILE%\pfd-watchdog\watchdog.log` and `backup.log`.

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
| `setup-windows.ps1` | install or upgrade on Windows 10 / 11 |
| `windows/watchdog.ps1` | restarts Docker or the app when they hang (installed by `setup-windows.ps1`) |
| `windows/backup.ps1` | monthly database backup (installed by `setup-windows.ps1`) |
| `windows/run-hidden.vbs` | runs the two scripts above from Task Scheduler without a console window |
| `install.sh` | generic installer for Linux / other Docker hosts |
