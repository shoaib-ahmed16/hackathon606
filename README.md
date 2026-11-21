# hackathon606 – hackathonTeamYashasvi

Spring Boot security microservice (user registration, login, JWT-based authorization).
The project lives in [`hackathonTeamYashasvi/`](hackathonTeamYashasvi).

## 1. Install required software

| Tool | Version | Needed for |
|------|---------|-----------|
| JDK | 17 (17+) | build & run |
| PostgreSQL | 14+ (17 recommended) | database (local run) |
| Git | any | clone the repo |
| curl (+ `jq` optional) | any | testing the API |
| Docker + Docker Compose v2 | optional | run everything in containers |

Gradle is **not** required – the project ships with the `./gradlew` wrapper (Gradle 8.14.3 is downloaded on first run).

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk git curl jq postgresql postgresql-contrib
sudo systemctl enable --now postgresql
```

### macOS (Homebrew)

```bash
brew install openjdk@17 git curl jq postgresql@17
brew services start postgresql@17
# make JDK 17 visible to the system
sudo ln -sfn "$(brew --prefix openjdk@17)/libexec/openjdk.jdk" /Library/Java/JavaVirtualMachines/openjdk-17.jdk
```

### Windows

Install with [winget](https://learn.microsoft.com/windows/package-manager/winget/) (PowerShell as admin):

```powershell
winget install EclipseAdoptium.Temurin.17.JDK
winget install Git.Git
winget install PostgreSQL.PostgreSQL.17
```

Use `gradlew.bat` instead of `./gradlew` and set variables with `$env:NAME="value"`.

### Docker & Docker Compose (optional, required for container / cloud deployment)

Docker Compose v2 is a plugin of Docker (`docker compose ...`, no hyphen) and is installed together with Docker Engine.

**Ubuntu / Debian (official Docker repository):**

```bash
# remove conflicting old packages (ignore "not installed" messages)
for p in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y $p; done

# add Docker's apt repository
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# install Engine + CLI + Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# start on boot and run docker without sudo (log out/in afterwards)
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

(On Debian replace `ubuntu` with `debian` in the repository URLs.)

**Amazon Linux 2023 (e.g. EC2):**

```bash
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# Compose plugin
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

**macOS / Windows:** install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (includes Compose v2). On Windows enable the WSL 2 backend.

**Verify:**

```bash
docker --version
docker compose version
docker run --rm hello-world
```

### Verify the installation

```bash
java -version            # openjdk version "17..."
psql --version           # psql (PostgreSQL) 14+ 
git --version
docker compose version   # only if using Docker
```

## 2. Get the code & set up the database

```bash
git clone <repository-url> hackathon606
cd hackathon606/hackathonTeamYashasvi
```

Create the database. Set a password for the `postgres` user if you have not already (Linux: default install has none for TCP logins):

```bash
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"
sudo -u postgres psql -c "CREATE DATABASE hackathon_yashasvi;"
```

(macOS/Windows: `psql -U postgres -c "CREATE DATABASE hackathon_yashasvi;"`.)

Tables are created automatically by the Flyway migrations in `src/main/resources/db/migration` on startup; Hibernate only validates the schema.

### Configuration

Defaults live in `src/main/resources/application.yml`. Override with environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DB_NAME` | `hackathon_yashasvi` | PostgreSQL database name |
| `DB_USERNAME` | `postgres` | PostgreSQL user |
| `DB_PASSWORD` | `postgres` | PostgreSQL password |
| `JWT_SECRET_KEY` | dev key | HMAC secret for signing JWTs (**min 32 chars**; set your own outside local dev) |

```bash
export DB_NAME=hackathon_yashasvi
export DB_USERNAME=postgres
export DB_PASSWORD=postgres
export JWT_SECRET_KEY='replace-with-a-long-random-secret-of-32+chars'
```

Optional: `security.cors.allowed-origins` (comma separated, default `http://localhost:3000,http://localhost:4200`).

## 3. Build & run locally

```bash
./gradlew clean build -x test   # compile and package (skip tests)
./gradlew test                  # tests - need PostgreSQL running with the config above
./gradlew bootRun               # start the service on http://localhost:8888
```

Or run the packaged jar:

```bash
./gradlew bootJar
java -jar build/libs/hackathonTeamYashasvi-0.0.1-SNAPSHOT.jar
```

Health check: `curl http://localhost:8888/actuator/health` → `{"status":"UP"}`

IDE (IntelliJ IDEA / VS Code): open the `hackathonTeamYashasvi` folder as a Gradle project, set the project SDK to JDK 17, let Gradle sync, then run `HackathonTeamYashasvi`.

### Troubleshooting

| Problem | Fix |
|---------|-----|
| `Connection refused` on 5432 | PostgreSQL is not running – start the service |
| `password authentication failed` | `DB_USERNAME`/`DB_PASSWORD` do not match your PostgreSQL user |
| `database "hackathon_yashasvi" does not exist` | create it (step 2) or set `DB_NAME` |
| `Port 8888 already in use` | stop the other process or run with `--server.port=8889` |
| `Unsupported class file major version` / wrong Java | ensure `java -version` is 17 |
| Flyway checksum error after editing `V1` | never edit applied migrations; add `V2__...sql`, or drop the dev database |

## 4. Run with Docker Compose (alternative)

Builds the app image and starts it together with PostgreSQL (no local JDK/PostgreSQL needed):

```bash
cd hackathonTeamYashasvi
cp .env.example .env      # edit passwords; JWT_SECRET_KEY must be 32+ chars
docker compose up -d --build
docker compose logs -f app
curl http://localhost:8888/actuator/health
docker compose down        # stop (add -v to also delete the database volume)
```

## 5. Endpoints

Base URL: `http://localhost:8888`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/v1/signIn` | public | Register a new user (always created with role `USER`) |
| POST | `/api/v1/login` | public | Authenticate, returns a JWT |
| GET | `/api/v1/security/customer/{email}` | `USER` or `ADMIN` | Get a user by email |
| GET | `/api/v1/security/customers` | `ADMIN` | List all users |
| GET | `/api/v1/security/userDetails?username=` | `ADMIN` | Spring `UserDetails` for a username |
| GET | `/api/v1/security/hello` | any authenticated | Hello check |
| POST | `/api/v1/security/contact` | any authenticated | Demo POST |
| PUT | `/api/v1/security/notice` | any authenticated | Demo PUT |
| POST | `/api/v1/security/write` | any authenticated | Demo POST |

Swagger UI is permitted at `/swagger-ui/**` and `/v3/api-docs/**` only if a springdoc dependency is added (only annotations are included currently).

## 6. Testing the API (curl)

### 6.1 Register – `POST /api/v1/signIn`

```bash
curl -i -X POST http://localhost:8888/api/v1/signIn \
  -H "Content-Type: application/json" \
  -d '{
    "email": "john.doe@example.com",
    "password": "P@ssw0rd123",
    "firstName": "John",
    "lastName": "Doe",
    "countryCode": "+971",
    "number": "501234567",
    "address": "Dubai, UAE"
  }'
```

Expected: `201 Created`

```json
{
  "id": 1,
  "email": "john.doe@example.com",
  "firstName": "John",
  "lastName": "Doe",
  "countryCode": "+971",
  "number": "501234567",
  "address": "Dubai, UAE",
  "role": "USER"
}
```

> Any `role` sent in the body is ignored. The password is never returned.

### 6.2 Login – `POST /api/v1/login`

```bash
curl -i -X POST http://localhost:8888/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{
    "username": "john.doe@example.com",
    "password": "P@ssw0rd123"
  }'
```

Expected: `202 Accepted`

```json
{
  "obj": {
    "authenticated": "john.doe@example.comAuthenticated SuccessFully!!!",
    "jwtToken": "eyJhbGciOiJIUzI1NiJ9...."
  },
  "status": "ACCEPTED",
  "statusCode": 202
}
```

The token is also returned in the `Authorization` response header (without the `Bearer ` prefix).
Wrong credentials return `401` with `"Authentication Failed!!!"`.

Save the token for the next calls:

```bash
TOKEN=$(curl -s -X POST http://localhost:8888/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"username":"john.doe@example.com","password":"P@ssw0rd123"}' | jq -r '.obj.jwtToken')
```

### 6.3 Call a protected endpoint

Send the token as `Authorization: Bearer <token>`:

```bash
curl -i http://localhost:8888/api/v1/security/customer/john.doe@example.com \
  -H "Authorization: Bearer $TOKEN"

curl -i -X POST http://localhost:8888/api/v1/security/contact \
  -H "Authorization: Bearer $TOKEN"

curl -i -X PUT http://localhost:8888/api/v1/security/notice \
  -H "Authorization: Bearer $TOKEN"
```

### 6.4 Admin-only endpoints

Self-registration always creates `USER`, so promote a user directly in the database, then log in again to get a token carrying the new role:

```sql
UPDATE users_details SET role = 'ADMIN' WHERE email = 'john.doe@example.com';
```

```bash
curl -i http://localhost:8888/api/v1/security/customers \
  -H "Authorization: Bearer $TOKEN"
```

### 6.5 Expected error responses

| Scenario | Result |
|----------|--------|
| No / missing token on a protected endpoint | `401` / `403` |
| Invalid or expired token | `401 Invalid or expired token` |
| `USER` token on `/customers` | `403 Forbidden` |
| Wrong login credentials | `401` `Authentication Failed!!!` |

## 7. Optional

- **Service discovery:** run with profile `local-discovery` (`./gradlew bootRun --args='--spring.profiles.active=local-discovery'`) to register with Eureka.
- **Tracing:** Zipkin endpoint defaults to `http://localhost:9411/api/v2/spans`.
- **Token lifetime:** `jwt.security.token.validity` (milliseconds, default `360000` = 6 min).

## 7a. Chatbot (WebSocket + Anthropic Java SDK)

A terminal chat talks to the app over a WebSocket (`/ws/chat`); the app forwards each message to Claude and sends the answer back. The socket needs a JWT like every other endpoint.

1. Put your key in `hackathonTeamYashasvi/.env` (`ANTHROPIC_API_KEY=sk-ant-...`, create one at https://console.anthropic.com/settings/keys); the app loads `.env` itself when started from that folder. Optional: `ANTHROPIC_MODEL` (default `claude-opus-5-5`) and `ANTHROPIC_EFFORT` (`low`/`medium`/`high`/`xhigh`/`max`, default `medium`). Replies stream token by token, use adaptive thinking and prompt caching.
2. Start Postgres and the app (`docker compose up -d --wait postgres`, then `./gradlew bootRun`).
3. Register once: `curl -X POST localhost:8888/api/v1/signIn -H 'Content-Type: application/json' -d '{"email":"me@example.com","password":"Secret@123","firstName":"Me","lastName":"User"}'`
4. In another terminal: `./gradlew -q --console=plain chat` (prompts for email and password, or set `CHAT_USER`, `CHAT_PASSWORD`, `CHAT_URL`). Type `/quit` to leave.

## 8. Deploy to a cloud instance (AWS EC2 / Azure VM / GCP Compute Engine / DigitalOcean)

The Docker Compose setup is the recommended way to deploy: one VM runs the app and PostgreSQL containers.

### 8.1 Create the instance

- Linux VM (Ubuntu 22.04/24.04 LTS), at least **2 vCPU / 2 GB RAM** and 20 GB disk.
- Security group / firewall inbound rules:

| Port | Source | Purpose |
|------|--------|---------|
| 22 | your IP only | SSH |
| 80, 443 | anywhere | HTTP/HTTPS (reverse proxy, see 8.4) |
| 8888 | your IP only (or closed once a proxy is used) | direct API access for testing |

- **Do not open 5432.** The compose file does not publish PostgreSQL, so it is reachable only from the app container.

### 8.2 Install Docker on the instance

SSH in (`ssh -i key.pem ubuntu@<public-ip>`) and follow *Docker & Docker Compose* in section 1 (Ubuntu steps). Also install git: `sudo apt install -y git`.

### 8.3 Deploy

```bash
git clone <repository-url> hackathon606
cd hackathon606/hackathonTeamYashasvi

cp .env.example .env
nano .env                       # set strong DB_PASSWORD and a 32+ char JWT_SECRET_KEY
# generate a secret:  openssl rand -base64 48

docker compose up -d --build    # build image and start app + postgres
docker compose ps               # both services should be "healthy"
docker compose logs -f app
curl http://localhost:8888/actuator/health
```

From your machine: `curl http://<public-ip>:8888/actuator/health`.

Update to a new version:

```bash
git pull
docker compose up -d --build
```

Containers use `restart: unless-stopped`, so they come back after a reboot. Database data lives in the `postgres-data` volume and survives `docker compose down` (it is deleted by `down -v`).

### 8.4 HTTPS with a reverse proxy (recommended)

Point a DNS record at the instance, then put a TLS-terminating proxy in front of port 8888. Example with [Caddy](https://caddyserver.com/docs/install) (automatic Let's Encrypt certificates):

```bash
sudo apt install -y caddy
# /etc/caddy/Caddyfile
api.example.com {
    reverse_proxy localhost:8888
}
sudo systemctl reload caddy
```

Then close port 8888 in the firewall and use `https://api.example.com/api/v1/login`.
Set `SECURITY_CORS_ALLOWED_ORIGINS=https://your-frontend.example.com` in the `app` service environment if a browser frontend calls the API.

### 8.5 Production checklist

- Use strong, unique `DB_PASSWORD` and `JWT_SECRET_KEY`; never commit `.env` (it is gitignored). Prefer the cloud's secret manager where available.
- Back up the database: `docker compose exec postgres pg_dump -U postgres hackathon_yashasvi > backup.sql` (or use a managed PostgreSQL such as RDS / Cloud SQL / Azure Database and set `SPRING_DATASOURCE_URL`, `DB_USERNAME`, `DB_PASSWORD` instead of the bundled `postgres` container).
- Self-registration always creates `USER`; promote admins via SQL (section 6.4).
- Tracing is disabled in the container by default. To use Zipkin, run it separately and set `MANAGEMENT_TRACING_ENABLED=true` and `MANAGEMENT_ZIPKIN_TRACING_ENDPOINT`.
- Schema changes go in new Flyway files (`V2__...sql`); they run automatically on start.
- Keep the OS and images updated (`sudo apt upgrade`, `docker compose pull && docker compose up -d --build`).
