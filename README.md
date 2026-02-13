# basic-setup

[![Deploy admin_init.sh to GitHub Pages](https://github.com/anshibanov/basic-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/anshibanov/basic-setup/actions/workflows/ci.yml)

Скрипт первичной настройки Linux-сервера: создание привилегированного пользователя `admin_init` с SSH-доступом по ключам, отключение парольной аутентификации и уведомление через [ntfy.sh](https://ntfy.sh).

## Быстрый старт

Выполните на новом сервере от имени root:

```bash
curl -sSL https://anshibanov.github.io/basic-setup/admin_init.sh | sudo bash
```

Скрипт развёрнут через GitHub Pages и доступен по прямой ссылке.

## Что делает скрипт

1. **Создаёт пользователя** `admin_init` со случайно сгенерированным паролем
2. **Настраивает sudo** — беспарольный доступ через `/etc/sudoers.d/`
3. **Устанавливает SSH-ключи** — добавляет авторизованные публичные ключи для `admin_init` (и для пользователя `ubuntu`, если он существует)
4. **Отключает парольную аутентификацию SSH** — оставляет только вход по ключам
5. **Обнаруживает Proxmox VE** — если сервер работает на Proxmox, добавляет пользователя с ролью Administrator в PVE
6. **Шифрует пароль** с помощью [Age](https://age-encryption.org) и отправляет уведомление на ntfy.sh с информацией о сервере

## Требования

Скрипт рассчитан на Debian/Ubuntu. Необходимые пакеты:

| Пакет | Назначение |
|-------|------------|
| `openssl` | Генерация и хеширование пароля |
| `sudo` | Настройка привилегий |
| `curl` | Определение внешнего IP, отправка уведомлений |
| `iproute2` | Определение внутреннего IP (команда `ip`) |
| `openssh-server` | SSH-сервер |
| `age` | Шифрование пароля (опционально — скрипт попытается установить автоматически) |

## Структура репозитория

```
.
├── admin_init.sh               # Основной скрипт настройки сервера
├── CLAUDE.md                    # Инструкции для Claude Code
├── DECRYPT.md                   # Инструкция по расшифровке пароля
├── README.md                    # Этот файл
├── .gitignore
└── .github/
    └── workflows/
        └── ci.yml               # CI/CD: тесты + деплой на GitHub Pages
```

## Шифрование пароля

Сгенерированный пароль шифруется с помощью [Age](https://age-encryption.org) перед отправкой через ntfy.sh.

- Если `age` не установлен — скрипт попытается установить его автоматически
- Если установка не удалась — пароль не шифруется, в уведомление добавляется предупреждение
- В любом случае пароль сохраняется на сервере в `/root/.admin_init_password.txt`

Подробная инструкция по расшифровке: **[DECRYPT.md](DECRYPT.md)**

### Быстрая расшифровка

```bash
# Скопируйте готовую команду из уведомления ntfy.sh и выполните:
echo "-----BEGIN AGE ENCRYPTED FILE-----
...
-----END AGE ENCRYPTED FILE-----" | age -d -i ~/.age/key.txt
```

## CI/CD

GitHub Actions workflow (`.github/workflows/ci.yml`) выполняет:

### Тестирование

При каждом push и pull request в `main` скрипт запускается в Docker-контейнерах:

- **Debian** (`debian:latest`)
- **Ubuntu** (`ubuntu:latest`)

### Деплой

После успешного прохождения тестов (только при push в `main`) скрипт публикуется на GitHub Pages.

## Локальное тестирование

```bash
# Тест на Debian
docker run --rm -v $(pwd):/app -w /app debian:latest bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl sudo curl iproute2 openssh-server age > /dev/null && \
  ./admin_init.sh"

# Тест на Ubuntu
docker run --rm -v $(pwd):/app -w /app ubuntu:latest bash -c "\
  apt-get -qq update > /dev/null && \
  apt-get -qq install -y openssl sudo curl iproute2 openssh-server age > /dev/null && \
  ./admin_init.sh"
```

## Безопасность

- Пароль шифруется Age-шифрованием перед отправкой через ntfy.sh
- SSH парольная аутентификация отключается автоматически
- Конфигурация sshd проверяется (`sshd -t`) перед применением — при ошибке изменения откатываются
- Файл пароля на сервере доступен только root (`chmod 600`)
- Скрипт идемпотентен — безопасен при повторном запуске

## Особенности работы

- Скрипт использует `set -e` — при ошибке в критических операциях выполнение прекращается
- Некритические операции (уведомления, шифрование) обёрнуты в обработку ошибок и не прерывают работу скрипта
- При обнаружении Proxmox VE пользователь автоматически добавляется в PVE с ролью Administrator
- Если на сервере есть пользователь `ubuntu`, SSH-ключи добавляются и ему
