# Branding Deployment with Docker Compose

This document explains how the branding deployment system works for Living Atlas using Docker Compose.

## Overview

The branding system consists of:
- **Dockerfile**: Multi-stage build that supports both local directories and git repositories
- **docker-compose service**: Runs the branding in production (nginx) or development mode (hot-reload)
- **Ansible integration**: Prepares build context and configures nginx vhost
- **Optional git watcher**: Monitors git repositories for changes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Ansible Playbook                          │
│  - Detects if branding_source is local path or git URL      │
│  - Copies/clones source to {{ data_dir }}/branding-build/   │
│  - Generates docker-compose configuration                    │
│  - Configures nginx vhost (proxy to branding container)     │
└─────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────┐
│                  Docker Build (buildx bake)                  │
│  Stage 1: source-local or source-git                        │
│  Stage 2: dependencies (with npm/yarn cache)                │
│  Stage 3: builder-production (npm run build)                │
│  Stage 4: production (nginx serving /build/public)          │
│  Stage 5: development (hot-reload server)                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────┐
│                  Docker Compose Services                     │
│  - branding: Main service (nginx or dev server)             │
│  - branding-git-watcher: Optional git change monitor        │
└─────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────┐
│                    Nginx Reverse Proxy                       │
│  - Proxies https://branding.example.com → branding:80       │
│  - Configured by nginx_vhost role                           │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Configure Inventory

Add to your inventory file (e.g., `la-test-local-extras.ini`):

```ini
use_branding=true
branding_source=../la-test-branding
build_images=true  # Optional: let docker-compose build the image
```

### 2. Run Deployment

```bash
cd ansible
ansible-playbook -i inventories/your-inventory docker-compose-deploy.yml
```

### 3. Build and Start

**Option A: Let docker-compose build automatically (if build_images=true)**
```bash
cd /data  # or your configured data_dir
docker compose up -d  # Builds and starts automatically
```

**Option B: Build with docker buildx bake (better for CI/CD)**
```bash
cd /data  # or your configured data_dir
docker buildx bake branding
docker compose up -d
```

**Option C: Manual build for testing**
```bash
cd docker/branding
./build-branding.sh ../../la-test-branding
```

## Configuration Variables

### Required Variables

- `use_branding`: Enable branding deployment (default: false)
- `branding_source`: Path to branding source or git URL
- `branding_hostname`: Hostname for nginx vhost

### Optional Variables

#### Source Configuration
- `branding_git_ref`: Git branch/tag/commit (default: master)
- `branding_node_version`: Node.js version (default: 18)
- `branding_version`: Docker image tag (default: latest)

#### Development Mode
- `branding_dev_mode`: Enable hot-reload (default: false)
- `branding_dev_port`: Dev server port (default: 3000)

#### Git Monitoring
- `branding_git_watch`: Monitor git repo for changes (default: false)
- `branding_git_check_interval`: Check interval in seconds (default: 300)

#### Legacy Variables
- `branding_url`: Alias for branding_hostname
- `branding_path`: Subpath (usually empty)

## Usage Examples

### Example 1: Local Development with Hot-Reload

```ini
use_branding=true
branding_source=../la-test-branding
branding_hostname=branding.local.test
branding_dev_mode=true
```

Then access the dev server at:
- http://localhost:3000 (Brunch)
- http://localhost:5173 (Vite)

Changes to source files will automatically reload in the browser.

### Example 2: Production from Git Repository

```ini
use_branding=true
branding_source=https://github.com/living-atlases/base-branding.git
branding_git_ref=v1.0.0
branding_hostname=branding.example.com
```

### Example 3: Production with Git Monitoring

```ini
use_branding=true
branding_source=https://github.com/myorg/custom-branding.git
branding_git_ref=main
branding_hostname=branding.example.com
branding_git_watch=true
branding_git_check_interval=600
```

The git watcher will check for changes every 10 minutes. When changes are detected, it signals a rebuild is needed:

```bash
docker compose up -d --build branding
```

### Example 4: Local Path Production Build

```ini
use_branding=true
branding_source=../la-test-branding
branding_hostname=branding.example.com
```

## How It Works

### 1. Ansible Preparation Phase

When you run the ansible playbook:

1. **Source Detection**: Ansible checks if `branding_source` matches regex `^(https?://|git@).*`
   - If match → git URL → sets `branding_build_source=git`
   - If no match → local path → sets `branding_build_source=local`

2. **Source Preparation**:
   - For git URLs: Clones to `/tmp/branding-git-checkout` on control machine
   - For local paths: Uses the path directly

3. **Build Context Copy**: Syncs source to `{{ data_dir }}/branding-build/`
   - Excludes: node_modules, .git, public, dist

4. **File Generation**:
   - Copies Dockerfile to `{{ data_dir }}/branding/Dockerfile`
   - Copies nginx.conf to `{{ data_dir }}/branding-build/nginx.conf`
   - Generates `{{ data_dir }}/infrastructure/branding.yml` from template

5. **Nginx Configuration**: Calls branding role which:
   - Configures nginx vhost with `proxy_pass: http://branding:80`
   - Adds branding hostname to docker internal aliases

### 2. Docker Build Phase

The Dockerfile uses multi-stage build:

```dockerfile
# Stage selection based on BUILD_SOURCE arg
FROM source-local or source-git AS source

# Install dependencies with cache mounts
FROM node:18 AS dependencies
RUN --mount=type=cache,target=/root/.npm npm ci

# Production build
FROM dependencies AS builder-production
RUN npm run build

# Development with hot-reload
FROM dependencies AS development
CMD npm run dev

# Production runtime
FROM nginx:alpine AS production
COPY --from=builder-production /build/public /usr/share/nginx/html

# Final stage selected by TARGET arg
FROM ${TARGET} AS final
```

### 3. Docker Compose Runtime

Production mode:
```yaml
branding:
  image: branding:latest
  networks:
    - la_internal
  # Nginx serving static files
```

Development mode:
```yaml
branding:
  build:
    context: ../branding-build
    target: development
  volumes:
    - ../branding-build:/build:rw  # Hot-reload
  ports:
    - "3000:3000"
```

## Troubleshooting

### Build fails with "No package.json found"

Your branding source doesn't have a package.json. Check:
- `branding_source` path is correct
- Path is relative to ansible directory
- Repository was cloned successfully

### "Module not found" during build

Dependencies not installed correctly. Try:
```bash
cd /data/branding-build
docker compose build --no-cache branding
```

### Git watcher not detecting changes

Check:
- `branding_git_watch=true` is set
- `branding_source` is a git URL (not local path)
- Check watcher logs: `docker compose logs branding-git-watcher`

### Hot-reload not working

Ensure:
- `branding_dev_mode=true` is set
- Source is mounted as volume
- Dev server is running: `docker compose logs branding`

### Nginx shows 502 Bad Gateway

The branding container is not running or not healthy:
```bash
docker compose ps branding
docker compose logs branding
```

Check that branding is in same network as nginx:
```bash
docker network inspect la_la_internal
```

## Build Cache

The Dockerfile uses BuildKit cache mounts for faster builds:
- `/root/.npm` - npm package cache
- `/root/.cache/yarn` - yarn cache

These are preserved between builds, making subsequent builds much faster.

To clear cache:
```bash
docker builder prune
```

## Files Created

After ansible run, you'll have:
```
/data/
├── branding/
│   └── Dockerfile              # Copied from docker/branding/Dockerfile
├── branding-build/
│   ├── package.json            # Your branding source
│   ├── app/                    # Your branding files
│   └── nginx.conf              # Copied from docker/branding/nginx.conf
├── infrastructure/
│   └── branding.yml            # Generated docker-compose config
└── docker-compose.yml          # Includes branding.yml
```

## Advanced: Custom nginx Configuration

If your branding needs custom nginx configuration:

1. Create `nginx.conf` in your branding repository root
2. It will be copied into the Docker image automatically

Example custom nginx.conf:
```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    location ~* \.(?:jpg|jpeg|gif|png|ico|svg|woff|woff2)$ {
        expires 1y;
    }
}
```

## See Also

- [Dockerfile](../../docker/branding/Dockerfile)
- [docker-compose template](../ansible/roles/docker-common/templates/docker-compose/infrastructure/branding.yml.j2)
- [branding role](../ansible/roles/branding/)
- [Example configuration](../la-test-inventories/branding-example.ini)
