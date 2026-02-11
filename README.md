# Server Infrastructure

Shared reverse proxy and SSL termination for all apps on the server. Runs independently from any application.

## Server Layout

```
/opt/
├── infra/          ← this repo
├── fc/deploy/      ← fc-project app services
└── other-app/      ← future projects
```

## Server Preparation (one-time, as root)

These steps set up a bare Ubuntu 24 LTS server before any repos are cloned.

### 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

### 2. Create the deploy user and grant permissions

```bash
# Create user (if it doesn't exist)
adduser deploy

# Allow deploy user to run Docker without sudo
usermod -aG docker deploy

# Create directories and give ownership to deploy
mkdir -p /opt/infra /opt/fc
chown deploy:deploy /opt/infra /opt/fc
```

After this, log in as `deploy` (or `su - deploy`) for all remaining steps.

### 3. Set up GitHub access for cloning

The `deploy` user needs to pull from your private GitHub repos. Two options:

**Option A — SSH deploy key (recommended):**

```bash
# As the deploy user:
ssh-keygen -t ed25519 -C "deploy@server" -f ~/.ssh/github_deploy -N ""

# Print the public key:
cat ~/.ssh/github_deploy.pub
```

Add this public key to your **GitHub account** → Settings → SSH and GPG keys → New SSH key.
(Adding it to your account lets one key access all your repos. GitHub deploy keys are per-repo
and don't allow the same key on multiple repos, so an account-level key is simpler for 6 repos.)

Configure SSH to use it:

```bash
cat >> ~/.ssh/config << 'EOF'
Host github.com
  IdentityFile ~/.ssh/github_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

Test: `ssh -T git@github.com` — should say "Hi <username>!".

**Option B — HTTPS with Personal Access Token:**

```bash
# Generate a PAT on GitHub: Settings → Developer settings → Personal access tokens
# → Fine-grained tokens → with "Contents: Read-only" on your repos

# Clone using HTTPS (Git will prompt for password — paste the PAT):
git clone https://github.com/YOU/infra.git /opt/infra

# To avoid re-entering the token, cache it:
git config --global credential.helper store
# (stores in plaintext at ~/.git-credentials — acceptable for a deploy user)
```

Option A is more secure and doesn't expire. Option B is quicker to set up.

### 4. Configure SSH for GitHub Actions

GitHub Actions deploys by SSHing into the server as the `deploy` user. Generate a separate key for this:

```bash
# On your local machine (not the server):
ssh-keygen -t ed25519 -C "github-actions" -f ~/.ssh/fc_deploy_action -N ""

# Copy the public key to the server:
ssh-copy-id -i ~/.ssh/fc_deploy_action.pub deploy@<SERVER_IP>
```

Then add to each GitHub repo (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `SERVER_IP` | Server public IP |
| `SERVER_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | Contents of `~/.ssh/fc_deploy_action` (the **private** key) |

## Initial Setup

```bash
# As the deploy user:
git clone git@github.com:YOU/infra.git /opt/infra
cd /opt/infra

# Get SSL certificates (one-time)
bash scripts/init-letsencrypt.sh

# Use --staging flag to test with Let's Encrypt staging first:
bash scripts/init-letsencrypt.sh --staging
```

The init script will:
1. Download recommended TLS parameters
2. Start nginx with an HTTP-only bootstrap config
3. Run certbot to obtain certificates via webroot challenge
4. Swap in the full SSL config and reload nginx

## Certificate Renewal

Add to crontab:

```
0 4 1 * * cd /opt/infra && docker compose run --rm certbot renew && docker compose exec nginx-proxy nginx -s reload
```

## Adding a New App

1. Create a config file in `nginx/conf.d/`, e.g. `myapp.conf`:

```nginx
server {
    listen 443 ssl;
    server_name myapp.example.com;

    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://myapp-container:PORT;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

2. In the app's `docker-compose.yml`, join the shared network:

```yaml
services:
  myapp:
    # ...
    networks:
      - reverse-proxy

networks:
  reverse-proxy:
    external: true
```

3. Obtain a certificate for the new domain:

```bash
cd /opt/infra
docker compose run --rm certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  --email admin@example.com --agree-tos --no-eff-email \
  -d myapp.example.com
```

4. Add the HTTP→HTTPS redirect for the new domain to the `listen 80` block in your conf file, or create a separate one.

5. Reload nginx:

```bash
docker compose exec nginx-proxy nginx -s reload
```

## GitHub Actions Secrets

| Secret | Value |
|--------|-------|
| `SERVER_IP` | Server public IP |
| `SERVER_USER` | Deploy user (must be in `docker` group) |
| `SSH_PRIVATE_KEY` | SSH key authorized on the server |
