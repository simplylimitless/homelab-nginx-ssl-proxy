# homelab-nginx-ssl-proxy

Minimal nginx reverse proxy with SSL termination, packaged as a Docker image.
Routes internal homelab services behind a single TLS endpoint.

**Supported architectures:** `linux/amd64`, `linux/arm64`

## Quick Start

```yaml
# docker-compose.yml
services:
  proxy:
    image: ghcr.io/simplylimitless/homelab-nginx-ssl-proxy:latest
    container_name: nginx-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      # Site configuration files
      - ./sites:/etc/nginx/sites-available:ro
      - ./sites-enabled:/etc/nginx/sites-enabled:ro
      # SSL certificates — directory must mirror server_name paths
      - ./certs:/etc/letsencrypt/live:ro
      # Optional: L4/stream configs for non-HTTP protocols (e.g. RTSP)
      - ./streams-enabled:/etc/nginx/streams-enabled:ro
    environment:
      - TZ=America/Los_Angeles
```

```bash
mkdir -p sites sites-enabled certs
```

## Configuration

### The .conf file

Each proxied service gets one `.conf` file in `sites/`. Symlink it into
`sites-enabled/` to activate — nginx only loads files from that directory.

```bash
# Create sites/mysite.conf using the template below, then symlink it in
ln -sf ../sites/mysite.conf sites-enabled/mysite.conf
```

### Template

```nginx
# ------------------------------------------------------------------
#  mysite.internal  — Your Application Name
# ------------------------------------------------------------------

server {
    listen       80;
    server_name  mysite.local;       # <-- change to your hostname / domain

    # Redirect all HTTP → HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen       443 ssl http2;
    server_name  mysite.local;       # <-- must match the block above

    # --- SSL certificates ---
    # Path convention: /etc/letsencrypt/live/<server_name>/<cert-file>
    # Place your PEM files in certs/<server_name>/ on the host.
    ssl_certificate      /etc/letsencrypt/live/mysite.local/fullchain.pem;
    ssl_certificate_key  /etc/letsencrypt/live/mysite.local/privkey.pem;

    # --- Security headers ---
    add_header X-Frame-Options   SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # --- Proxy settings ---
    location / {
        proxy_pass         http://myservice:8080;  # <-- container or host:port
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # WebSocket support (optional — keep for apps that need it)
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
```

### Key fields to customize

| Field              | Where               | What to put                                       |
|--------------------|---------------------|---------------------------------------------------|
| `server_name`      | both `server {}`     | The hostname or domain for this service            |
| `ssl_certificate`  | `listen 443` block   | Path to the fullchain PEM (see SSL section below)  |
| `ssl_certificate_key` | `listen 443` block | Path to the private-key PEM                       |
| `proxy_pass`       | `location /`         | Internal address — use Docker service names or `http://host.docker.internal:<port>` |

## SSL Certificates

### Directory layout

Nginx expects certificates under `/etc/letsencrypt/live/<server_name>/` (the
standard Let's Encrypt convention the template references). On the host, mount
your cert directory to that path:

```
certs/
├── mysite.local/
│   ├── fullchain.pem     # certificate chain
│   └── privkey.pem       # private key
├── dashboard.local/
│   ├── fullchain.pem
│   └── privkey.pem
└── monitoring.local/
    ├── fullchain.pem
    └── privkey.pem
```

Each subdirectory is named after the `server_name` in the config. Nginx does
not auto-lookup — you must set the paths explicitly in each `.conf` file, but
keeping the naming convention makes it easy to find the right cert.

### Getting certificates

**Option A — Let's Encrypt (certbot)**
If your services are reachable on the public internet:

```bash
docker run --rm -it \
  -v ./certs:/etc/letsencrypt/live \
  certbot/certbot \
  certonly --standalone -d mysite.local -d dashboard.local
```

**Option B — Internal CA / self-signed**
For purely internal services, generate self-signed certs or use your
organization's internal CA:

```bash
# Self-signed (for testing/internal only)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/mysite.local/privkey.pem \
  -out certs/mysite.local/fullchain.pem \
  -subj "/CN=mysite.local"
```

**Option C — Pre-existing certificates**
If you already have certs from your CA, just place them in the correct
`certs/<server_name>/` subdirectory as `fullchain.pem` and `privkey.pem`.

### TLS settings

The image enforces **TLSv1.2 only** (no SSLv3, TLSv1.0, or TLSv1.1) via
`ssl_protocols TLSv1.2` in the main nginx.conf. All configs inherit this.

## Activating / Deactivating Sites

```bash
# Activate a site
ln -sf ../sites/mysite.conf sites-enabled/mysite.conf

# Deactivate (remove the symlink)
rm sites-enabled/mysite.conf

# Reload nginx after changes (if running in Docker without restart)
docker exec nginx-proxy nginx -s reload
```

## Stream (L4) Proxying

For non-HTTP, TCP/UDP-level protocols (e.g. RTSP, raw TCP passthrough),
`nginx.conf` wraps `/etc/nginx/streams-enabled/*.conf` in a top-level
`stream {}` block. Files placed there follow the same activate/deactivate
convention as `sites-enabled`, but each `.conf` file is a bare `server {}`
block (no `http`-style `location` directives):

```nginx
# streams-enabled/rtsp.conf
server {
    listen     8554;
    proxy_pass rtsp-backend:8554;
}
```

This directory is optional — omit the `./streams-enabled` volume mount
entirely if you have no non-HTTP services to proxy.

## Directory Summary

```
.                          ← project root
├── sites/                 ← write your .conf files here
│   ├── mysite.conf
│   └── other-service.conf
├── sites-enabled/         ← symlinks into sites/ (nginx reads this dir)
│   └── mysite.conf → ../sites/mysite.conf
├── certs/                 ← SSL certificate files (Let's Encrypt layout)
│   └── mysite.local/
│       ├── fullchain.pem
│       └── privkey.pem
├── streams-enabled/       ← optional: L4/stream configs (RTSP, raw TCP, etc.)
│   └── rtsp.conf
├── nginx.conf             ← main config (pinned in the image)
└── README.md
```

## Dockerfile

Build from source instead of pulling the pre-built image:

```bash
docker build -t homelab-nginx-ssl-proxy .
```

The published image is multi-arch (`linux/amd64`, `linux/arm64`). To build
multi-arch locally with buildx:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t homelab-nginx-ssl-proxy .
```
