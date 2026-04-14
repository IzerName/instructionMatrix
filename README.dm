# 🛠️ Развёртывание Matrix (Synapse) на своём сервере
*Рекомендуемый стек: Docker Compose + PostgreSQL + Nginx + Element Web*

---

## 📋 Требования
| Компонент | Минимум | Рекомендуется |
|-----------|---------|---------------|
| ОС | Ubuntu 22.04 / 24.04 | Ubuntu 24.04 LTS |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 ГБ | 8 ГБ |
| Диск | 20 ГБ SSD | 50 ГБ NVMe |
| Домен | `matrix.yourdomain.com` | Отдельный поддомен для сервера |
| Порты | `80`, `443`, `22` (открыты) | `3478/udp`, `5349/tcp` для TURN (звонки) |

---

## 📦 Шаг 1: Подготовка сервера
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

---

## 🐳 Шаг 2: Установка Docker & Docker Compose
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
sudo apt install -y docker-compose-plugin  # v2 команда: `docker compose`
```

---

## 📁 Шаг 3: Создание структуры проекта
```bash
mkdir -p /opt/matrix/{synapse-data,postgres-data,nginx/conf.d,nginx/certs}
cd /opt/matrix
```

Создайте файл `docker-compose.yml`:
```yaml
services:
  postgres:
    image: postgres:15-alpine
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: STRONG_DB_PASSWORD
      POSTGRES_DB: synapse
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    networks:
      - matrix-net

  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      SYNAPSE_SERVER_NAME: matrix.yourdomain.com
      SYNAPSE_REPORT_STATS: "no"
    volumes:
      - ./synapse-data:/data
    networks:
      - matrix-net
    expose:
      - "8008"

  nginx:
    image: nginx:alpine
    container_name: matrix-nginx
    restart: unless-stopped
    depends_on:
      - synapse
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/certs:/etc/nginx/certs
    networks:
      - matrix-net

networks:
  matrix-net:
    driver: bridge
```

---

## ⚙️ Шаг 4: Генерация и правка конфига Synapse
```bash
docker compose run --rm -v $(pwd)/synapse-data:/data synapse generate
```

Отредактируйте файл `./synapse-data/homeserver.yaml`:

```yaml
# Найдите и замените/раскомментируйте:
server_name: "matrix.yourdomain.com"
public_baseurl: "https://matrix.yourdomain.com/"

# 🔹 База данных (замените пароль на свой)
database:
  name: psycopg2
  args:
    user: synapse
    password: STRONG_DB_PASSWORD
    database: synapse
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10

# 🔹 Регистрация (включите временно для создания первого аккаунта)
enable_registration: true
# ⚠️ После создания админа верните `false`!

# 🔹 Медиа и загрузки
media_store_path: "/data/media_store"
uploads_path: "/data/uploads"

# 🔹 Ограничение частоты запросов (рекомендуется)
rc_messages_per_second: 0.2
rc_message_burst_count: 10.0
```

---

## 🔐 Шаг 5: Nginx + Let's Encrypt (HTTPS)
Создайте файл `./nginx/conf.d/matrix.conf`:
```nginx
server {
    listen 80;
    server_name matrix.yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name matrix.yourdomain.com;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Matrix Client/Server API
    location /_matrix/ {
        proxy_pass http://synapse:8008;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}
```

Получите SSL-сертификат:
```bash
sudo apt install -y certbot
sudo certbot certonly --nginx -d matrix.yourdomain.com
sudo cp /etc/letsencrypt/live/matrix.yourdomain.com/fullchain.pem ./nginx/certs/
sudo cp /etc/letsencrypt/live/matrix.yourdomain.com/privkey.pem ./nginx/certs/
sudo chown -R 101:101 ./nginx/certs  # права для nginx в alpine
```

🔁 **Автообновление сертификатов:**
```bash
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'docker compose restart nginx'") | crontab -
```

---

## 🚀 Шаг 6: Запуск сервера
```bash
cd /opt/matrix
docker compose up -d
docker compose logs -f synapse  # убедитесь, что нет ошибок подключения к БД
```

---

## 👤 Шаг 7: Создание первого пользователя
```bash
docker exec -it synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u admin \
  -p STRONG_PASSWORD \
  -a \
  http://localhost:8008
```
> ⚠️ **Важно:** Сразу после этого верните в `homeserver.yaml`: `enable_registration: false` и перезапустите: `docker compose restart synapse`

---

## 📱 Шаг 8: Подключение клиента Element
1. Откройте [app.element.io](https://app.element.io)
2. Нажмите **Sign in** → **Edit** → укажите `https://matrix.yourdomain.com`
3. Войдите под созданным аккаунтом
4. В настройках включите **Двухфакторную аутентификацию** и настройте **восстановление ключей шифрования**

*(Опционально)* Можно развернуть свой `element-web` через Docker, но `app.element.io` безопаснее и автоматически обновляется.

---

## 🌐 Шаг 9: Включение федерации
Чтобы ваш сервер мог общаться с другими Matrix-серверами, добавьте `.well-known` в Nginx (в тот же блок `server`):
```nginx
    location /.well-known/matrix/server {
        return 200 '{ "m.server": "matrix.yourdomain.com:443" }';
        add_header Content-Type application/json;
    }
    location /.well-known/matrix/client {
        return 200 '{ "m.homeserver": { "base_url": "https://matrix.yourdomain.com" } }';
        add_header Content-Type application/json;
    }
```
Проверьте: `curl -s https://matrix.yourdomain.com/.well-known/matrix/server`

---

## 🔒 Безопасность и обслуживание
| Задача | Команда / Действие |
|--------|-------------------|
| Бэкап БД | `docker exec matrix-postgres pg_dump -U synapse synapse > backup_$(date +%F).sql` |
| Бэкап данных | `tar czf synapse-backup_$(date +%F).tar.gz ./synapse-data` |
| Обновление | `docker compose pull && docker compose up -d` |
| Мониторинг | `docker stats`, `htop`, настройка `prometheus` + `grafana` |
| Защита от сканирования | Установите `fail2ban`, закройте порт `8008` в `ufw` |

---

## 🆘 Частые проблемы
| Симптом | Решение |
|---------|---------|
| `Connection refused` к PostgreSQL | Проверьте пароли в `docker-compose.yml` и `homeserver.yaml`, убедитесь, что сервисы в одной сети `matrix-net` |
| Ошибка CORS в Element | Убедитесь, что `public_baseurl` совпадает с доменом Nginx, проверьте заголовки `proxy_set_header` |
| Медленная отправка сообщений | Увеличьте `cp_max` в конфиге БД, проверьте нагрузку на диск (IOPS), включите `worker` при высокой нагрузке |
| Не работает регистрация | `enable_registration: true` + проверка, что `docker compose restart synapse` выполнен после правки конфига |

---

✅ **Готово!** У вас работает полностью автономный Matrix-сервер.  
Для настройки моста к Telegram (`mautrix-telegram`), голосовых звонков (`coturn`) или интеграции ботов — создавайте отдельные сервисы в том же `docker-compose.yml` и подключайте к сети `matrix-net`.
