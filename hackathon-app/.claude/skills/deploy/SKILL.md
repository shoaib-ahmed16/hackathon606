---
name: deploy
description: Build and deploy the app with Docker (primary), or Vercel/Netlify/static hosting -- SPA routing, build-time env vars, nginx, compose. Use when asked to deploy, containerize, share a live link, or prepare the production build.
---

# Deploy

## Docker (primary)

Files: `Dockerfile` (node build -> nginx), `nginx.conf` (SPA fallback, gzip, asset caching), `.dockerignore`, `docker-compose.yml`.

```bash
docker build -t hackathon-app \
  --build-arg VITE_API_URL=https://api.example.com \
  --build-arg VITE_WS_URL=wss://api.example.com/ws .
docker run -p 8080:80 hackathon-app        # http://localhost:8080
# or: docker compose up --build              (reads VITE_API_URL / VITE_WS_URL from the shell or a root .env)
```

- **`VITE_*` vars are baked at build time**: change them -> rebuild the image (`--build-arg`). `.env` is NOT copied into the image (`.dockerignore`).
- CORS: either the backend allows the site's origin, or uncomment the `/api/` proxy in `nginx.conf` and build with `VITE_API_URL=/api`.
- On https sites use `wss://` and an https API (mixed content is blocked).
- Keep the image build green: if `npm ci` fails the lockfile is out of sync -> run `npm i` locally and commit `package-lock.json`.

## Other hosts

`npm run build` -> `dist/`. SPA routing is preconfigured: `vercel.json` (Vercel) and `public/_redirects` (Netlify). Set env vars in the host dashboard.

## Before sharing the link

Log in on the deployed URL, reload a deep link (e.g. `/posts`) to confirm routing, check the console for CORS / mixed-content errors. Never put secrets in `VITE_*` variables.
