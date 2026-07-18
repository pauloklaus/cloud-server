# CloudServer

Stack Docker com Traefik (TLS via Cloudflare DNS-01), WireGuard (VPN + DNS interno), AdGuard Home e serviços auxiliares. Serviços administrativos ficam acessíveis **somente via VPN**; alguns hosts públicos ficam abertos na internet.

## Serviços

| Serviço | Host | Acesso |
|---------|------|--------|
| Traefik dashboard | `traefik.${DOMAIN}` | VPN |
| AdGuard Home | `dns.${DOMAIN}` | VPN |
| Portainer | `portainer.${DOMAIN}` | VPN |
| LibreSpeed | `speed.${DOMAIN}` | Público |
| Uptime Kuma | `uptime.${DOMAIN}` | Público |
| PairDrop | `send.${DOMAIN}` | Público |
| WireGuard (endpoint) | `guard.${DOMAIN}:${WG_PORT}/udp` | Público (UDP) |

O middleware Traefik `vpn-peer` restringe origem a `VPN_SUBNET` e ao IP do container WireGuard (`WIREGUARD_IP/32`, por causa do SNAT).

## Arquitetura

```text
Cliente VPN ──DNS──►  VPN_GATEWAY:53 (CoreDNS no WireGuard)
                           │
                           ▼
                     AdGuard (ADGUARD_IP:53)
                           │ rewrites → VPN_GATEWAY
                           ▼
Cliente VPN ──HTTPS──► VPN_GATEWAY:443
                           │ DNAT + SNAT (scripts)
                           ▼
                     Traefik (TRAEFIK_IP) ──► backends
```

- **DNS:** peers usam `PEERDNS=${VPN_GATEWAY}`. CoreDNS encaminha para o AdGuard na rede `internal_services_net`.
- **HTTPS “só VPN”:** rewrites no AdGuard apontam hosts privados para `VPN_GATEWAY`. O container WireGuard faz DNAT `80/443` → Traefik e SNAT para que o retorno TCP funcione; o Traefik enxerga origem `WIREGUARD_IP`.
- **Split tunnel:** `AllowedIPs = VPN_SUBNET` basta para DNS + HTTPS via `VPN_GATEWAY`. **Não** coloque o mesmo IP do `Endpoint` em `AllowedIPs` (quebra o handshake).

Defaults de rede (`.env.template`):

| Papel | Variável | Default |
|-------|----------|---------|
| Sub-rede VPN | `VPN_SUBNET` / `VPN_NETWORK` | `172.18.0.0/24` / `172.18.0.0` |
| Gateway / DNS no túnel | `VPN_GATEWAY` | `172.18.0.1` |
| Rede Docker interna | `SVC_SUBNET` | `172.19.0.0/24` |
| AdGuard | `ADGUARD_IP` | `172.19.0.2` |
| WireGuard | `WIREGUARD_IP` | `172.19.0.3` |
| Traefik | `TRAEFIK_IP` | `172.19.0.10` |

Evite `172.17.0.0/16` (bridge padrão do Docker).

---

## Pré-requisitos

- Docker Engine + plugin Compose (`docker compose`)
- Domínio no Cloudflare e token API com permissão **Zone → DNS → Edit** (challenge DNS-01)
- Pacote `gettext-base` (comando `envsubst`) no host
- Porta UDP de `WG_PORT` liberada no firewall (mapeada para `51820` no container)

### Rede externa do Traefik

```bash
docker network create proxy_network
```

### Porta 53 no host (opcional)

A stack **não** publica a porta 53 no host (DNS só dentro da VPN). Se no futuro você mapear `53`, desative o stub do `systemd-resolved` se houver conflito.

---

## Subida da stack

### 1. Variáveis de ambiente

```bash
cp .env.template .env
```

Preencha no mínimo:

```env
DOMAIN=example.com
CF_DNS_API_TOKEN=...
ACME_EMAIL=admin@example.com
WG_PEERS=notebook,celular
WG_PORT=51820
```

`WG_PEERS` é a lista de nomes dos peers (separados por vírgula). `WG_PORT` é a porta UDP pública no host (vai para o `Endpoint` dos peers). Os defaults de rede em `.env.template` podem permanecer se não colidirem com a LAN.

### 2. CoreDNS

```bash
./scripts/render-config.sh
```

Gera `wireguard/config/coredns/Corefile` a partir do template (`forward` → `ADGUARD_IP:53`). Rode de novo sempre que mudar `ADGUARD_IP`.

### 3. AdGuard

```bash
cp adguard/conf/AdGuardHome.yaml.template adguard/conf/AdGuardHome.yaml
```

Ajuste usuário/senha (hash bcrypt ou configure na UI) e os **rewrites** para os hosts privados, apontando para `VPN_GATEWAY`:

```yaml
filtering:
  rewrites:
    - domain: 'traefik.example.com'
      answer: 172.18.0.1
      enabled: true
    - domain: 'dns.example.com'
      answer: 172.18.0.1
      enabled: true
    - domain: 'portainer.example.com'
      answer: 172.18.0.1
      enabled: true
```

`AdGuardHome.yaml` não vai para o Git (veja `.gitignore`).

### 4. Certificados Traefik

```bash
mkdir -p traefik
touch traefik/acme.json
chmod 600 traefik/acme.json
```

### 5. Template WireGuard (NAT HTTP/HTTPS)

O arquivo `wireguard/config/templates/server.conf` deve chamar os scripts de DNAT/SNAT no `PostUp`/`PostDown` (já incluído no repositório). Em instalação **já existente**, confira `wireguard/config/wg_confs/wg0.conf`:

```ini
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; /scripts/apply-web-nat.sh
PostDown = /scripts/remove-web-nat.sh; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
```

Não duplique linhas `PostUp`/`PostDown`: acrescente os scripts às linhas existentes.

### 6. DNS no Cloudflare

Crie registros **A** (ou CNAME) para os hosts da tabela de serviços, apontando para o IP público da VPS.

| Host | Proxy Cloudflare |
|------|------------------|
| `speed`, `uptime`, `send`, `guard` | Laranja (proxied) ok, se preferir |
| `traefik`, `dns`, `portainer` | **DNS only** (cinza) — senão o Traefik vê IP da Cloudflare e o `IPAllowList` bloqueia |

Certificados usam **DNS-01**; não dependem de HTTP na porta 80 para emitir.

### 7. Subir

```bash
docker compose up -d
docker compose ps
docker compose logs -f traefik wireguard adguard
```

Peers gerados ficam em `wireguard/config/peer_<nome>/` (QR code e `.conf`). Importe no cliente WireGuard.

Após alterar `Corefile` ou `wg0.conf`:

```bash
docker compose up -d --force-recreate wireguard
```

---

## Cliente WireGuard

### DNS

```ini
[Interface]
DNS = 172.18.0.1
```

(use o valor de `VPN_GATEWAY`)

### Split tunnel (recomendado para hosts privados)

```ini
[Peer]
AllowedIPs = 172.18.0.0/24
```

O compose define `ALLOWEDIPS=0.0.0.0/0` na geração dos peers (túnel completo). Para split tunnel, edite o `.conf` do peer ou o template `wireguard/config/templates/peer.conf` / variável `ALLOWEDIPS` e regenere.

### Túnel completo

```ini
[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
```

Exige encaminhamento/NAT no servidor para o restante do tráfego.

### Navegador

Desative DNS-over-HTTPS / “DNS seguro” no navegador; caso contrário os rewrites do AdGuard são ignorados.

---

## Firewall (UFW)

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow ${WG_PORT}/udp   # valor do .env
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
```

Com full tunnel no host, pode ser necessário `DEFAULT_FORWARD_POLICY="ACCEPT"` em `/etc/default/ufw`.

---

## Validação

No servidor:

```bash
docker compose ps
docker exec -it wireguard wg show
docker exec -it wireguard sh -c "nc -zv ${ADGUARD_IP:-172.19.0.2} 53"
docker exec -it wireguard sh -c "iptables -t nat -S | grep -E 'DNAT|SNAT'"
```

No cliente (VPN ligada):

```bash
nslookup google.com 172.18.0.1
nslookup dns.example.com 172.18.0.1
curl -vk https://dns.example.com
curl -vk https://speed.example.com   # público; funciona sem VPN
```

---

## Troubleshooting

| Sintoma | Causa comum |
|---------|-------------|
| Ao conectar a VPN, ping ao IP público some | `AllowedIPs` inclui o mesmo IP do `Endpoint` (`/32`). Remova, desconecte e reconecte. |
| `SERVFAIL` no DNS da VPN | `Corefile` sem `forward` para `ADGUARD_IP`; AdGuard sem upstream; rede interna quebrada. |
| `403` em `traefik` / `dns` / `portainer` | Sem VPN; Cloudflare laranja no host privado; rewrite não aponta para `VPN_GATEWAY`. |
| Timeout / `connection refused` em `VPN_GATEWAY:443` | Scripts NAT não rodaram (`PostUp`, volume `/scripts`, recreate do `wireguard`); Traefik parado. |
| `Address already in use` ao subir | Conflito de IP fixo na `internal_services_net`: `docker compose down` e remova a rede antiga se necessário. |

Bootstrap do AdGuard sem VPN: o compose não publica a UI no host. Use o YAML template, ou publique temporariamente a porta `80`/`3000` do container, ou faça SSH tunnel até o IP do AdGuard na rede Docker.

---

## Dados persistentes

| Caminho | Conteúdo |
|---------|----------|
| `traefik/acme.json` | Certificados Let's Encrypt |
| `wireguard/config/` | Chaves, peers, `wg0.conf`, CoreDNS |
| `wireguard/scripts/` | DNAT/SNAT (`apply-web-nat.sh` / `remove-web-nat.sh`) |
| `adguard/conf/`, `adguard/work/` | Config e estado do AdGuard |
| `portainer/data/` | Portainer |
| `uptime-kuma/data/` | Uptime Kuma |
| `librespeed_data/` | LibreSpeed |

---

## Referências

- [Traefik — IPAllowList](https://doc.traefik.io/traefik/v3.0/middlewares/http/ipallowlist/)
- [LinuxServer — WireGuard](https://docs.linuxserver.io/images/docker-wireguard)
- [AdGuard Home — Docker](https://github.com/AdguardTeam/AdGuardHome/wiki/Docker)
