# Remote deployment and administration

## Supported answer

Threat Claim Monitor can run on a remote server, but the committed Compose file
is a localhost-only reference deployment, not a public production deployment.
PostgreSQL has no host port and n8n binds to `127.0.0.1`; another computer cannot
open the editor directly.

The recommended V1 remote-administration pattern is a private VPN or an SSH
tunnel. It preserves the loopback boundary and requires no public n8n port.

## Private administration with an SSH tunnel

Prerequisites on the server:

- a supported and patched Linux host with Docker Engine and Compose v2;
- repository and `.env` stored outside public or synchronized directories;
- inbound SSH restricted by firewall, identity, and preferably VPN;
- protected off-device backups and separate preservation of
  `N8N_ENCRYPTION_KEY`;
- enough memory for the services and, if used, the selected model.

Use the normal [getting-started](getting-started.md) and
[workflow-deployment](workflow-deployment.md) procedures from an SSH session on
the server, and create a [verified backup](backup-and-restore.md) before moving
an existing installation.

Start the unchanged stack on the server. From the administrator workstation,
open a tunnel:

```sh
ssh -N -L 15678:127.0.0.1:5678 ADMIN_USER@SERVER_HOST
```

Keep that terminal open and browse to <http://localhost:15678>. Authentication
still occurs in n8n; SSH controls who can reach the local editor port. Do not
change the Compose binding to `0.0.0.0` and do not publish PostgreSQL.
The server-side port in the tunnel command is 5678 because that is the default
`N8N_PORT`; replace it when the server's `.env` uses another host port.

Outbound source collection, Foundry requests, SMTP, Teams, and generic webhook
delivery can work from the server if its egress policy permits them. Incoming
public webhooks cannot reach a loopback-only instance through a private
administrator tunnel; exposing an inbound webhook requires the separate HTTPS
design below.

## Local inference on a Linux server

The Compose file maps `host.docker.internal` to the Docker host gateway. Ollama
may run natively on the server, but GPU support, firewall rules, model digest,
and host binding must be validated on that server. Do not expose Ollama to the
Internet. Microsoft Foundry can instead be selected explicitly when its data
processing scope, credential, quota, and cost have been approved.

The repository release evidence covers Windows 11 and Apple Silicon, not a
specific Linux distribution or GPU. A server rollout therefore needs a clean
installation test and recorded runtime evidence before it is relied upon.

## Public HTTPS deployment is a separate architecture

Do not expose the current HTTP port directly. A public or shared deployment
requires a reviewed override or separate Compose definition with at least:

- a DNS name and TLS termination at a maintained reverse proxy;
- n8n configured with the external `N8N_HOST`, `N8N_PROTOCOL=https`,
  `N8N_EDITOR_BASE_URL`, and `WEBHOOK_URL` values;
- the exact trusted-proxy count through `N8N_PROXY_HOPS` and forwarded headers;
- secure cookies enabled;
- n8n reachable only from the reverse proxy, with PostgreSQL still internal;
- firewall restriction, operating-system patching, account review, 2FA, rate
  limiting, monitoring, alerting, and a tested recovery procedure;
- external task runners and a dedicated review of Code-node isolation instead
  of the reference deployment's internal runner mode;
- a decision for multi-user permissions, availability objectives, upgrades,
  log retention, and organization-approved encrypted backup storage.

Follow n8n's official [SSL setup](https://docs.n8n.io/hosting/securing/set-up-ssl/),
[reverse-proxy webhook](https://docs.n8n.io/hosting/configuration/configuration-examples/webhook-url/),
[endpoint environment-variable](https://docs.n8n.io/hosting/configuration/environment-variables/endpoints/),
and [security audit](https://docs.n8n.io/hosting/securing/security-audit/)
documentation. These references explain n8n's platform settings; they do not
constitute a reviewed Threat Claim Monitor production deployment.

## Administration and deployment boundary

For V1, update the remote instance manually through a controlled maintenance
window:

1. review and merge a pull request;
2. create and move a verified backup to protected storage;
3. fetch the reviewed tag or commit on the server;
4. apply missing migrations once in order;
5. update images and restart services;
6. run repository, health, source, provider, and notification checks;
7. roll back through a forward fix or verified restore if validation fails.

Do not expose the disabled n8n public API merely to automate deployment. n8n's
built-in source-control environments are plan-dependent and do not remove the
need to protect credentials, migrate PostgreSQL, or verify workflow publication
state.

## Go/no-go summary

| Intended use | Current status |
|---|---|
| Remote single administrator over SSH tunnel or approved VPN | Feasible after Linux/server runtime validation |
| Outbound monitoring with local or explicitly selected cloud inference | Feasible with reviewed egress and credentials |
| Public incoming webhook behind HTTPS reverse proxy | Not provided by the reference Compose file; separate review required |
| Internet-facing multi-user production service | Not approved by V1 documentation or runtime evidence |
| Public PostgreSQL or Ollama port | Prohibited |
