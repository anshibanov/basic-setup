#!/usr/bin/env bash

# Скрипт останавливается при любой ошибке
set -e

# Проверяем, что скрипт запущен из-под root
if [[ $EUID -ne 0 ]]; then
  echo "Пожалуйста, запустите этот скрипт от имени root (или через sudo)."
  exit 1
fi

# Генерируем случайный пароль
PASS=$(openssl rand -base64 12)

# Проверяем, существует ли уже пользователь admin_init
if id "admin_init" &>/dev/null; then
    echo "Пользователь admin_init уже существует. Пропускаем создание..."
else
    # Создаем пользователя admin_init с домашней директорией и bash-шеллом
    useradd -m -s /bin/bash -p "$(openssl passwd -1 "$PASS")" admin_init
    echo "Пользователь admin_init успешно создан."
fi

# Добавляем пользователя в группу sudo
usermod -aG sudo admin_init

# Настраиваем sudo без запроса пароля
cat << EOF > /etc/sudoers.d/90-admin_init
admin_init ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/90-admin_init

# Создаем .ssh директорию и файл authorized_keys
mkdir -p /home/admin_init/.ssh
chmod 700 /home/admin_init/.ssh

cat << 'EOF' > /home/admin_init/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIhwA1TX1DmrCX/8+SwxC0s89CJhKBYAeRWcZ0ew+2Vz admin_init
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5WNDdQOhqLHcR74n3HcLcXgdfQ0vjkRm3KqPxvDAG5 ansible@servapp.ru
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJzFqnmBbzi+PAAwftRHUfUB0f8zx2Xtt5EhFsPeWAQ orange
EOF

chmod 600 /home/admin_init/.ssh/authorized_keys
chown -R admin_init:admin_init /home/admin_init/.ssh

echo "========================="
echo "Пользователь: admin_init"
echo "Сгенерированный пароль: $PASS"
echo "========================="
echo "Готово!"
