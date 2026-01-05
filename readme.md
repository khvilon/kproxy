## HAProxy SNI Router (Proxmox / LXC / Alpine)

Минимальный, воспроизводимый проект для маршрутизации входящих **HTTP** и **HTTPS (TLS passthrough)** по доменному имени при **одном внешнем IP-адресе**.

Проект рассчитан на домашние/небольшие инфраструктуры, где:
- есть **один внешний IP**,
- внутри сети несколько сервисов/машин,
- каждый сервис сам управляет своим TLS (сертификаты, Nginx/Apache/встроенные веб‑серверы),
- нужна простая “пограничная” точка входа, которую легко пересоздать.

Пример кейса - дома сервер с виртуалками, благодаря данному решению можно без доп портов легко ходить на каждый сервис по поддомену. В том чисте, получение отдельными сервисами своих сертификатов Let’s Encrypt.

---

### Быстрый старт (запуск + диагностика)

**Где запускать:** внутри LXC/VM с **Alpine Linux + OpenRC**, **от root**.

1) Подготовьте маршруты (пример):
- возьмите `routes_example.txt` как шаблон,
- положите файл в `/etc/haproxy/routes.txt` (или используйте свой путь).

2) Запустите скрипт:

```sh
chmod +x ./setup-haproxy-sni.sh
./setup-haproxy-sni.sh /etc/haproxy/routes.txt
```

Скрипт сам:
- установит пакеты,
- проверит `routes.txt`,
- сгенерирует `/etc/haproxy/haproxy.cfg` (с бэкапом),
- провалидирует конфиг,
- перезапустит HAProxy и покажет слушающие порты + примеры тестов.

**Диагностика (самое полезное в первые минуты):**

```sh
# валидность конфига
haproxy -c -f /etc/haproxy/haproxy.cfg

# статус/рестарт сервиса
rc-service haproxy status
rc-service haproxy restart

# слушающие порты
ss -lntp | grep haproxy || netstat -lntp | grep haproxy

# HTTP (роутинг по Host)
curl -v http://<IP_CT>/ -H 'Host: api.example.com'

# TLS passthrough (роутинг по SNI)
openssl s_client -connect <IP_CT>:443 -servername git.example.com -brief
```

---

### Что делает проект

Проект разворачивает HAProxy, который:
- принимает входящие соединения на **HTTP** (обычно 80) и **TLS** (обычно 443),
- маршрутизирует:
  - **HTTP** — по заголовку `Host`,
  - **TLS** — по **SNI** (TLS passthrough, без расшифровки),
- проксирует соединение на нужный внутренний сервис.

Важно:
- HAProxy **не завершает TLS** и **не управляет сертификатами**,
- каждый сервис продолжает терминировать TLS у себя.

---

### Формат маршрутов (`routes.txt`)

Одна строка — одно правило:

```text
<proto> <listen_port> <host> <backend_ip> <backend_port>
```

Где:
- **proto**: `tls` или `http`
- **listen_port**: порт, который слушает HAProxy
- **host**:
  - для `tls` — домен из SNI
  - для `http` — значение `Host` (скрипт матчинг также вариант `host:listen_port`)
- **backend_ip/backend_port**: куда проксировать (IP/хост и порт сервиса)

Пример:

```text
# proto listen host                  backend_ip     backend_port
tls    443    git.example.com        192.168.0.21   443
tls    443    home.example.com       192.168.0.22   443

http   80     old.example.com        192.168.0.30   8080
http   80     api.example.com        192.168.0.31   80
```

---

### Поведение по умолчанию (важно про “неизвестные домены”)

Если `Host`/`SNI` **не совпал ни с одним правилом**, трафик уходит в “blackhole” backend (`127.0.0.1:1`) — чтобы **не проксировать случайно** на “первый попавшийся” сервис.

---

### Архитектура (типовой кейс: один внешний IP)

```text
                Internet
                    |
             (один внешний IP)
                    |
                [ Router ]
              80 / 443 → NAT
                    |
            ┌─────────────────┐
            │ Proxmox Host    │
            │                 │
            │  LXC Container  │
            │  Alpine Linux   │
            │  HAProxy        │
            │  (SNI / Host)   │
            └────────┬────────┘
                     |
        ┌────────────┼────────────┐
        |             |            |
   VM / CT        VM / CT       VM / CT
   git.example    home.example  api.example
   :443           :443          :80 / :443
   (own TLS)      (own TLS)     (own HTTP/TLS)
```

---

### Что делает `setup-haproxy-sni.sh`

- Устанавливает: `haproxy`, `tzdata`, `ca-certificates`, `busybox-extras`
- Настраивает timezone (переменная окружения `TZ_NAME`, по умолчанию `Europe/Vilnius`)
- Валидирует `routes.txt`
- Генерирует `/etc/haproxy/haproxy.cfg` (и делает backup старого конфига)
- Проверяет конфиг (`haproxy -c -f ...`)
- Добавляет сервис в автозапуск и перезапускает HAProxy (OpenRC)

---

### Ограничения (осознанные)

- **TLS passthrough** работает только для протоколов с TLS+SNI; “raw TCP”/SSH по домену не маршрутизируются.
- Нет централизованных сертификатов: TLS живёт на бэкендах.
- Нет wildcard `*.example.com` по умолчанию — только явные правила в `routes.txt`.
- Это не security‑gateway: не firewall/WAF/VPN/IDS.

---

### Когда проект НЕ подходит

- Нужен централизованный TLS + автоматический Let’s Encrypt
- Нужна сложная HTTP‑логика (auth, rewrites, headers)
- Нужна динамическая конфигурация/частые изменения через API/UI

В таких случаях лучше смотреть в сторону полноценного reverse proxy с TLS termination (Traefik/Caddy/Nginx) или edge‑решений.