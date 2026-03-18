# PowerNetWebsite

**PowerNetWebsite** is a lightweight, static marketing experience that showcases the PowerNet product vision through performant HTML, CSS, and client-side JavaScript assets. It ships with both host-based Nginx configuration and a Docker workflow so the same bundle can run on a managed server or inside a container.

## Getting started (Docker)
1. Install Docker Engine and either Docker Compose v1 or Docker Compose v2 on the machine that will serve the site.
2. From the repository root, run `./deploy.sh` without any extra arguments. By default `DEPLOY_ENV` now defaults to `production`, so the script immediately prompts for the hostname/SSL details and then starts the Docker Compose service defined in `docker-compose.yml`, which uses the bundled `Dockerfile` (an `nginx:alpine` image with the static site copied into `/usr/share/nginx/html`).
Prior to launching Docker Compose, `deploy.sh` checks the requested [`DOCKER_PORT`](#environment-variables) (default 8080) and will automatically slide the binding to the next free port all the way up to 65535, so you do not have to manually edit `.env` just to work around a conflict.

## Host-based deployment (nginx present)
If `nginx` is already installed on the host, `./deploy.sh` now keeps the actual site inside Docker and writes a reverse proxy block that forwards requests to the container (listen 80 and 443, same `DOCKER_PORT` binding passed to the Compose service). It validates the new proxy, reloads `nginx`, and still prompts for the hostname/SSL choices so the generated TLS cert matches the requested `server_name`; the full string you type is persisted and used in `server_name`, while the certificate files use a safe “primary host.”

## Production setup and SSL
`./deploy.sh` treats production as the default path. The first run prompts for `PRODUCTION_HOSTNAME` and whether to enable HTTPS. If HTTPS is enabled, a self-signed certificate is generated locally with SAN entries for every hostname you typed, copied into `/etc/ssl/powernet` (or another directory set via `HOST_SSL_CERT_DIR`), and the paths are recorded as `PRODUCTION_SSL_CERT_PATH` / `PRODUCTION_SSL_KEY_PATH`. These values are persisted in `.env`, and the certificate is regenerated automatically if the hostname list changes later.

> **Security note:** `.env` is ignored by Git (`.gitignore` already contains it) and is intended to hold host-specific configuration (hostname, SSL choices, and certificate locations). Do not commit `.env` or the generated certificates to source control.

## Environment variables
| Variable | Description |
| --- | --- |
| `DEPLOY_ENV` | Deployment mode marker. The script now defaults to `production` if this is omitted. |
| `PRODUCTION_HOSTNAME` | The FQDN that appears in the `server_name` directive. Recorded on first production run. |
| `PRODUCTION_ENABLE_SSL` | `true`/`false` flag; controls whether the host `nginx` configuration listens on 443 with TLS. |
| `PRODUCTION_SSL_CERT_PATH` / `PRODUCTION_SSL_KEY_PATH` | Absolute paths to the TLS assets. Populated automatically once SSL is enabled. |
| `PRODUCTION_SSL_HOSTS` | Internal tracking value used by `deploy.sh` to regenerate the self-signed certificate when the hostname list changes. |
| `HOST_NGINX_CONF` | Optional override for the path of the generated proxy server block (default `/etc/nginx/conf.d/powernet-site.conf`). |
| `HOST_SSL_CERT_DIR` | Optional override for where certificates should live when generated (default `/etc/ssl/powernet`). |
| `DOCKER_PORT` | Port on the host that `docker-compose.yml` binds the `powernet-site` service to; the deploy script auto-finds the next free port and saves it back into `.env` when the preferred port is busy. |

## Docker compose & Nginx
The repository ships with:
- `Dockerfile`: builds from `nginx:1.27-alpine`, copies the static bundle, and exposes port 80.
- `docker-compose.yml`: defines a single `powernet-site` service that exposes 8080 on the host.

Use `docker compose up -d --build` (or `docker-compose` v1) if you prefer to run the container directly instead of through `deploy.sh`.

## Next steps
1. Review `.env.example` for optional overrides (if supplied later) and keep `.env` secret.
2. Run `./deploy.sh` after rebuilding assets to ensure both the Docker image and host configs embrace the latest bundle.
3. If you need a trusted TLS certificate, replace the self-signed files that the script generates with files issued by your CA and update the corresponding `.env` entries.
