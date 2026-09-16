# DOMjudge Docker

This project runs the DOMjudge 9.0.1 DOMserver and judgehost with Docker or
Podman Compose. nginx, PHP-FPM, MariaDB, the judgehost chroot, cgroups, and
systemd are managed inside the containers.

## Deployment layout

The same Compose file supports a DOMserver host and one or more separate
judgehost hosts. The containers keep application data inside `/opt/domjudge`;
there are no application bind mounts. The only host filesystem mount is the
cgroup filesystem required by systemd and the judgehost. The Judgehost waits for
the configured DOMserver URL to become reachable before starting its judgedaemon
units, so the same startup command works with Docker and Podman Compose.

### DOMserver host

Run these commands on the host that will provide the web site and MariaDB:

```bash
cd ~/domjudge-docker
./create-passwords.sh --preserve
touch zerossl-eab-kid zerossl-hmac-key
export DOMSERVER_HOSTS=domjudge.example.com

docker compose up --build domserver
# or:
podman compose up --build domserver
```

MariaDB starts automatically as a dependency of `domserver`. For the
automatically discovered public IPs and DNS names, omit
`export DOMSERVER_HOSTS=...`. To serve several names with one certificate, use a
comma-separated list:

```bash
export DOMSERVER_HOSTS=judge.example.com,oj.example.net,203.0.113.10
```

Replace the example IP with your server's real address. Every certificate target
must pass validation; a certificate for only part of the list is not accepted.

Add `export DOMSERVER_CERT=...` before `up` when a selector other than the
default `auto` is required. To run a judgehost on this same host as well, use
`docker compose up --build` or `podman compose up --build`.

The `touch` command creates empty EAB files when they are missing; existing
contents are preserved. Compose requires both files even without ZeroSSL.

For a new deployment with ZeroSSL, replace the `create-passwords.sh` and `touch`
commands above with:

```bash
./create-passwords.sh \
  --zerossl-eab-kid 'EAB_KID' \
  --zerossl-hmac-key 'EAB_HMAC_KEY'
```

### Separate MariaDB host

For a new deployment with the database on `10.0.0.10`, run on that host:

```bash
cd ~/domjudge-docker
./create-passwords.sh --preserve
export MARIADB_BIND_ADDR=10.0.0.10
export MARIADB_BIND_PORT=3306
docker compose up -d --build mariadb
```

Copy the same database password files to the DOMserver project. On the DOMserver
host, prepare the remaining credential files, then run:

```bash
cd ~/domjudge-docker
./create-passwords.sh --preserve
touch zerossl-eab-kid zerossl-hmac-key
export DOMSERVER_HOSTS=domjudge.example.com
export DOMSERVER_MARIADB_ADDR=10.0.0.10
export DOMSERVER_MARIADB_PORT=3306
docker compose up -d --build --no-deps domserver
```

The DB port must be reachable from the DOMserver host. `--no-deps` prevents
Compose from starting another MariaDB container on the DOMserver host. If a
gateway forwards a different port, set `DOMSERVER_MARIADB_PORT` to the gateway's
port and keep `MARIADB_BIND_PORT` set to MariaDB's actual listening port.

### Judgehost host

Copy this project to the CPU host. Copy the exact `judgehost-domserver-password`
file generated on the DOMserver host into the project root; it must match the
DOMserver password. The other services are not started on this host.

```bash
cd ~/domjudge-docker
install -m 0600 /secure/location/judgehost-domserver-password \
  ./judgehost-domserver-password

export DOMSERVER_HOSTS=domjudge.example.com
export DOMSERVER_HTTPS_PORT=443
export DOMSERVER_HTTP_PORT=80
export JUDGEHOST_CPU_RANGE=16-63

docker compose up --no-deps --build judgehost
# or:
podman compose up --no-deps --build judgehost
```

The Judgehost connects to the DOMserver through `DOMSERVER_HOSTS`, preferring
HTTPS when it is enabled. If the DOMserver uses a nonstandard enabled port, set
the same `DOMSERVER_HTTP_PORT` and `DOMSERVER_HTTPS_PORT` values on the
Judgehost host. `--no-deps` prevents Compose from starting MariaDB or DOMserver
on the Judgehost host.

The DOMserver and Judgehost hosts must be able to reach the selected DOMserver
port, and the DOMserver certificate must be trusted by the Judgehost when HTTPS
is used. Repeat the Judgehost-host commands with a different
`JUDGEHOST_CPU_RANGE` for each additional Judgehost.

## Credential files

`create-passwords.sh` writes these files beside the script in the project root,
regardless of the current working directory:

```text
domserver-db-root-password
domserver-db-password
judgehost-domserver-password
domserver-admin-username
domserver-admin-password
```

Without `--preserve`, all five files are overwritten on every run. The admin
username defaults to `admin`; all passwords are generated randomly. New files
have mode 0600.

Use `--preserve` to create only missing files. Existing files, including empty
files, retain their contents and permissions:

```bash
./create-passwords.sh --preserve
```

Override the administrator values with:

```bash
./create-passwords.sh --admin-name contest-admin --admin-password 'PASSWORD'
```

Compose passes the account files to the relevant containers as secrets. On the
first bootstrap, they are copied to `/opt/domjudge/setup_config/` with mode 0600
and used to initialize the accounts and internal connection settings. The admin
username is set by DOMjudge's normal default-data installation; there is no
separate administrator update utility.

After bootstrap, `setup_config` is only a record of the supplied values. Editing
it or the original input files does not change existing accounts, and restarting
a container does not import these values again. DOMjudge continues to use its
internal secret files and the existing database accounts.

DOMserver and Judgehost record successful initialization in
`/opt/domjudge/domserver/.inited` and `/opt/domjudge/judgehost/.inited`. MariaDB
checks its existing data under `/var/lib/mysql/`. A new container bootstraps its
application files; an existing database keeps its existing accounts.

Admin passwords must be at most 72 bytes, as required by DOMjudge's bcrypt
password hashing. The username `judgehost` is reserved for the REST API account.

ZeroSSL options accept the values directly and can be supplied independently:

```bash
./create-passwords.sh \
  --zerossl-eab-kid 'EAB_KID' \
  --zerossl-hmac-key 'EAB_HMAC_KEY'
```

Only the ZeroSSL files whose options are supplied are created or overwritten.
Omitting an option leaves that file untouched, even if it does not exist.
ZeroSSL use by the DOMserver requires both populated files; empty files disable
ZeroSSL in `auto` mode.

The optional EAB files are:

```text
zerossl-eab-kid
zerossl-hmac-key
```

With `--preserve`, supplying `--admin-name`, `--admin-password`,
`--zerossl-eab-kid`, or `--zerossl-hmac-key` for an existing file aborts before
any credential files are changed. Delete the named file and rerun the command.
Every such conflict uses the same message:

```text
[passwords] ERROR: FILE already exists; delete it and run this command again.
```

For a full stack start, Compose requires the five account files above. The
DOMserver uses all five; MariaDB uses the two database password files; a
Judgehost-only start uses only `judgehost-domserver-password`.

Compose also requires the two host EAB files, which may be empty when ZeroSSL is
not being used. Non-empty values are passed to the certificate utility on the
first DOMserver bootstrap and saved under `/opt/domjudge/certs/` only after a
successful ZeroSSL selection. They are not stored in `setup_config`.

All generated credential files are excluded from Git and the repository's image
build context.

Application data, certificates, the judgehost chroot, and MariaDB data remain
inside their containers. Recreating a container removes its internal data. The
only host mount is the system cgroup filesystem required by systemd and the
judgehost.

## Variables

| Variable                   | Default | Behavior                                              |
| -------------------------- | ------- | ----------------------------------------------------- |
| `DOMSERVER_HOSTS`          | `""`    | Comma-separated domains and IPv4/IPv6 addresses       |
| `DOMSERVER_BIND_ADDR`      | `*`     | Public nginx listeners: all IPv4 and IPv6 addresses   |
| `DOMSERVER_RESTRICT_HOSTS` | Unset   | Accept public requests only for listed hosts when set |

`DOMSERVER_HOSTS` replaces the old singular domain setting. When unset or empty,
automatic discovery:

1. Lists UP interfaces with usable IPv4/IPv6 addresses, excluding loopback.
2. Queries `https://api64.ipify.org` through each interface for each available
   address family. Each request is bound to that interface and bypasses proxy
   environment variables. Up to eight requests run concurrently, each with a
   ten-second limit.
3. Keeps all distinct public IPs returned, including addresses seen through NAT.
4. Looks up each IP's PTR records and adds DNS names whose A/AAAA lookup points
   back to that IP. DNS queries have a two-second timeout and one attempt.

Unreachable interfaces, malformed/private responses, and missing or failed DNS
lookups are skipped. Startup fails only when no public IP can be found, with an
instruction to set `DOMSERVER_HOSTS` explicitly. Reverse DNS finds registered
PTR names, not every domain pointing to an IP.

The resulting list contains IPs first (IPv4 before IPv6, ordered by interface),
followed by verified DNS names. Duplicate addresses and names are removed. That
same list is used for access restrictions and the single certificate. Every
target must still pass ACME validation.

Discovery and bootstrap run only on first initialization. A non-empty
`DOMSERVER_HOSTS` is used directly, without discovery. To choose particular
public or private IPs and domains, list them explicitly.

Whitespace around entries is trimmed, DNS names are lowercased, IPv6 addresses
are normalized, and duplicates are removed. Empty entries, URLs, ports,
wildcards, and malformed addresses fail before bootstrap. The first entry is the
DOMjudge base URL and the endpoint used by a remote Judgehost.

Set `DOMSERVER_BIND_ADDR` to `0.0.0.0` for all IPv4 addresses, or a specific
local IPv4/IPv6 address to restrict the public listener. Ports remain controlled
by `DOMSERVER_HTTP_PORT` and `DOMSERVER_HTTPS_PORT`.

With `DOMSERVER_RESTRICT_HOSTS` unset, other Host names and IP addresses are
accepted too, although HTTPS still needs a matching trusted certificate. Any set
value, including an empty string, `false`, or `0`, restricts public HTTP and
HTTPS requests to the resolved host list; other Hosts receive HTTP 403. An empty
host list with this flag restricts requests to the discovered IPs and DNS names.

```bash
export DOMSERVER_HOSTS=judge.example.com,oj.example.net,203.0.113.10
export DOMSERVER_RESTRICT_HOSTS=1
export DOMSERVER_BIND_ADDR=0.0.0.0
docker compose up --build domserver
```

Use `unset DOMSERVER_RESTRICT_HOSTS` to remove the restriction for a new
deployment. Public web settings are written during the first bootstrap.
`docker compose config` renders settings; the entrypoint validates them.

The loopback listener on port 8080 remains reserved for the internal API and
healthcheck, independently of public Host restrictions. With no host list, a
Judgehost on the same host uses `http://127.0.0.1:8080/`. A remote Judgehost
must set `DOMSERVER_HOSTS` to reachable server addresses and use its public
ports.

The database connection and listener use separate settings:

| Variable                 | Default     | Used by                                      |
| ------------------------ | ----------- | -------------------------------------------- |
| `DOMSERVER_MARIADB_ADDR` | `127.0.0.1` | DOMserver: database DNS name or IPv4 address |
| `DOMSERVER_MARIADB_PORT` | `3306`      | DOMserver: database connection port          |
| `MARIADB_BIND_ADDR`      | `127.0.0.1` | MariaDB: local bind address                  |
| `MARIADB_BIND_PORT`      | `3306`      | MariaDB: listening port                      |

The DOMserver settings are imported into its internal database configuration
during the first bootstrap. Existing initialized containers continue using that
configuration. `localhost` is normalized to `127.0.0.1` to keep TCP connections.
DOMjudge's colon-separated credential format cannot store an IPv6 literal; use a
DNS name when connecting over IPv6.

The MariaDB settings are passed to `mariadbd` on each start. The bind address
must belong to the database host, or be a wildcard such as `0.0.0.0`. It is
independent of the address a client uses to reach the server. Ports must be
decimal numbers from 1 through 65535; empty values are rejected. Judgehost does
not use these four settings.

`DOMSERVER_CERT` defaults to `auto`. Valid selectors are:

```text
auto
certbot-zerossl
certbot-letscrypt
acme-zerossl
acme-letscrypt
user
```

`auto` tries the selectors in that order, skipping unsupported methods, and
falls back to `user` if none succeeds. Lists containing an IP skip ZeroSSL ACME.
Lists containing private or reserved IPs skip all public ACME methods and use a
self-signed certificate covering the entire list. Explicit unsupported choices
fail with usage instructions. The selected method is recorded in
`/opt/domjudge/certs/.active`.

`certbot-zerossl` and `acme-zerossl` require both EAB files. Selecting either
one directly without both values causes `domserver-switch-cert` to fail.

`JUDGEHOST_CPU_RANGE` accepts an inclusive range such as `16-63`. Each CPU ID
starts one judgedaemon instance. If it is unset, the judgehost uses every
visible CPU from `0` through `nproc - 1`. `JUDGEHOST_CPU_RANGE=48-48` starts
`judgedaemon -n 48`.

`DOMSERVER_HTTP_PORT` defaults to 80. An empty value disables HTTP. When HTTPS
is enabled, HTTP redirects to the HTTPS port by default.

`DOMSERVER_HTTPS_PORT` defaults to 443. An empty value disables HTTPS and skips
certificate-specific validation and all automatic certificate setup during
bootstrap, including self-signed generation and renewal timer registration. If
both port variables are empty, the entrypoint fails before bootstrap.

`DOMSERVER_HTTPS_REDIRECT_TO_HTTP` defaults to `false`. Set it to `true` to make
HTTPS redirect to HTTP. Both HTTP and HTTPS must be enabled when this option is
true.

## Certificates

The active nginx links are always kept at:

```text
/opt/domjudge/certs/domserver.fullchain.pem
/opt/domjudge/certs/domserver.privkey.pem
```

All requested domains and IP addresses are included in one certificate. Let’s
Encrypt IP certificates use the `shortlived` profile (160 hours). Certbot 5.8
handles IP identifiers directly; acme.sh uses the same profile and a three-day
renewal interval. The existing twice-daily timer checks renewals.

ZeroSSL ACME is used for DNS names only. Private and reserved IP addresses
require a user-provided or self-signed certificate. Self-signed certificates
cause a browser trust warning.

`user` creates a self-signed certificate for the exact resolved list if no
certificate is supplied. A supplied certificate must cover the whole list.
Script-generated self-signed certificates are replaced when they expire or no
longer cover the list; supplied certificates are preserved.

The CLI uses `DOMSERVER_HOSTS` when non-empty. Otherwise it reuses the last
successful selection's targets from `/opt/domjudge/certs/hosts`, or discovers
public IPs and verified reverse DNS names if this is the first selection.
Override the targets explicitly when switching:

```bash
docker compose exec -e DOMSERVER_HOSTS=judge.example.com,203.0.113.10 \
  domserver domserver-switch-cert certbot-letscrypt
```

A manual `domserver-switch-cert` works even with `DOMSERVER_HTTPS_PORT=""`; it
creates/selects the certificate and configures renewal as appropriate. It does
not enable an nginx HTTPS listener.

The selector directories are:

```text
/opt/domjudge/certs/certbot-zerossl/
/opt/domjudge/certs/certbot-letscrypt/
/opt/domjudge/certs/acme-zerossl/
/opt/domjudge/certs/acme-letscrypt/
/opt/domjudge/certs/user/
```

Each successful directory contains `fullchain.pem`, `privkey.pem`, `.inited`,
`.hosts` (the target list), and `.name` (the ACME client's certificate name). A
later switch reuses an initialized certificate only if it is unexpired and
covers every requested host. Renewal uses the saved targets and name, including
when the input list is reordered. It does not reread bootstrap environment
settings.

The renewal service follows the selector in `/opt/domjudge/certs/.active`. For
each Certbot or acme.sh renewal and certificate installation operation, a
failure is retried once. If the retry also fails, the renewal service fails and
keeps the current active certificate links.

The certificate utility accepts one selector and optional ZeroSSL EAB values:

```bash
docker compose exec domserver domserver-switch-cert auto
docker compose exec domserver domserver-switch-cert user
docker compose exec domserver domserver-switch-cert acme-letscrypt
```

ZeroSSL methods read their EAB values from:

```text
/opt/domjudge/certs/zerossl-eab-kid
/opt/domjudge/certs/zerossl-hmac-key
```

If either value is missing or empty, `auto` skips the ZeroSSL methods. Selecting
`certbot-zerossl` or `acme-zerossl` directly fails with usage instructions. This
check also applies when reusing an initialized certificate.

Override either value for a ZeroSSL selection, using the stored file for any
omitted option:

```bash
docker compose exec domserver domserver-switch-cert certbot-zerossl \
  --zerossl-eab-kid 'EAB_KID' \
  --zerossl-hmac-key 'EAB_HMAC_KEY'
```

Supplied values are saved with mode 0600 only after the ZeroSSL selector
succeeds, including reuse of an initialized certificate. Failed operations leave
the stored EAB values unchanged. If `auto` falls back to Let's Encrypt or
`user`, it does not save the supplied ZeroSSL values.

When HTTPS is enabled, the first DOMserver bootstrap calls
`domserver-switch-cert`, passing non-empty ZeroSSL Compose secrets as these
options. With HTTPS disabled, it skips that call and does not read or save those
EAB inputs. Subsequent container starts keep the selected certificate and
renewal timer.

For a user certificate, copy the files into `/opt/domjudge/certs/user/` inside
the DOMserver container and run `domserver-switch-cert user`:

```bash
docker compose cp fullchain.pem domserver:/opt/domjudge/certs/user/fullchain.pem
docker compose cp privkey.pem domserver:/opt/domjudge/certs/user/privkey.pem
docker compose exec domserver domserver-switch-cert user
```

The files are inside the container and therefore need to be supplied again if
the DOMserver container is recreated.

## Runtime requirements

systemd runs as PID 1 inside the containers. The judgehost chroot and cgroup
setup require privileged/rootful Docker or Podman. Rootless containers cannot
provide the required judgehost isolation.

## Script layout

`scripts/common.sh` provides shared error output, port/domain validation,
certificate-pair checks, one retry for CA commands, and nginx stop/restore
handling. The DOMserver rejects invalid public settings before bootstrap.
Initialized application accounts continue using their stored runtime settings.
