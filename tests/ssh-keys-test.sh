#!/usr/bin/env bash
# authorized_keys management: managed block, revocation, legacy layouts.
# Destructive: run only inside a disposable root container.
set -euo pipefail

if [ ! -f /.dockerenv ] || [ "$EUID" -ne 0 ]; then
    echo 'Run this test only inside a disposable root container.' >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The end-to-end part runs the whole script: it must not send notifications.
mkdir "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/curl"
chmod 755 "$work/bin/curl"
export PATH="$work/bin:$PATH"

source ./admin_init.sh

failures=0
check() {
    local description="$1"
    shift
    if "$@"; then
        echo "  OK: $description"
    else
        echo "  FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}

readonly begin_marker='# BEGIN admin_init managed keys'
readonly end_marker='# END admin_init managed keys'

make_key() {
    ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$work/$1"
    cat "$work/$1.pub"
}

# ssh-keygen is the oracle: it lists exactly the keys sshd would accept.
fingerprint() {
    ssh-keygen -lf - <<< "$1" | awk '{print $2}'
}
active_fingerprints() {
    ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
}
has_key() {
    active_fingerprints "$1" | grep -qxF "$(fingerprint "$2")"
}
lacks_key() {
    ! has_key "$1" "$2"
}
key_count_is() {
    [ "$(active_fingerprints "$1" | wc -l)" -eq "$2" ]
}
content_is() {
    diff <(printf '%s\n' "${@:2}") "$1"
}
quiet() {
    "$@" > /dev/null 2>&1
}
lacks_text() {
    ! grep -q -- "$1" "$2"
}
sync_fails() {
    ! quiet sync_authorized_keys "$@"
}

alice=$(make_key alice)
bob=$(make_key bob)
carol=$(make_key carol)
foreign=$(make_key foreign)
file="$work/authorized_keys"

echo "=== Новый файл: ключи попадают в управляемый блок ==="
rm -f "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice"$'\n'"$bob" ""
check "файл состоит из блока с двумя ключами" \
    content_is "$file" "$begin_marker" "$alice" "$bob" "$end_marker"

echo "=== Чужой ключ без завершающего перевода строки ==="
printf '%s' "$foreign" > "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice"$'\n'"$bob" ""
check "чужой ключ остался рабочим" has_key "$file" "$foreign"
check "первый управляемый ключ рабочий" has_key "$file" "$alice"
check "всего три рабочих ключа" key_count_is "$file" 3

echo "=== Миграция старого формата (ключи отдельными строками) ==="
printf '%s\n' "$alice" "$foreign" "$bob" > "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice"$'\n'"$bob" ""
check "управляемые ключи перенесены в блок без дублей" \
    content_is "$file" "$foreign" "$begin_marker" "$alice" "$bob" "$end_marker"

echo "=== Ключ, убранный из списка, отзывается ==="
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice" ""
check "убранный ключ больше не работает" lacks_key "$file" "$bob"
check "оставшийся ключ работает" has_key "$file" "$alice"
check "чужой ключ не тронут" has_key "$file" "$foreign"

echo "=== Отозванный ключ удаляется и вне блока ==="
printf '%s\n' "$foreign" "$carol" "no-pty,command=\"echo hi there\" $carol" > "$file"
sync_authorized_keys "$file" "$alice" "$carol" > "$work/sync.log" 2>&1 || true
check "отозванный ключ не работает" lacks_key "$file" "$carol"
check "строка отозванного ключа с опциями тоже удалена" lacks_text 'no-pty' "$file"
check "чужой ключ не тронут" has_key "$file" "$foreign"
check "управляемый ключ установлен" has_key "$file" "$alice"
check "отзыв виден в выводе" grep -q 'carol' "$work/sync.log"

echo "=== Ключ в обоих списках не устанавливается ==="
rm -f "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice"$'\n'"$carol" "$carol"
check "отозванный ключ не установлен" lacks_key "$file" "$carol"
check "второй ключ установлен" has_key "$file" "$alice"

echo "=== Повторная синхронизация не меняет файл ==="
printf '%s\n' "# заметка администратора" "$foreign" "" "$alice" > "$file"
sync_authorized_keys "$file" "$alice"$'\n'"$bob" "$carol" > /dev/null 2>&1 || true
cp "$file" "$work/once"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice"$'\n'"$bob" "$carol"
check "содержимое прежнее" cmp "$work/once" "$file"
check "комментарий администратора сохранён" grep -qxF "# заметка администратора" "$file"

echo "=== Закомментированный ключ не считается установленным ==="
printf '%s\n' "# $alice" > "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice" ""
check "ключ рабочий" has_key "$file" "$alice"
check "комментарий сохранён" grep -qxF "# $alice" "$file"

echo "=== Склеенная строка (последствие старой ошибки) не теряет чужой ключ ==="
printf '%s%s\n' "$foreign" "$alice" > "$file"
check "синхронизация проходит" quiet sync_authorized_keys "$file" "$alice" ""
check "чужой ключ остался рабочим" has_key "$file" "$foreign"
check "управляемый ключ рабочий" has_key "$file" "$alice"

echo "=== Повреждённый блок: ошибка, файл не тронут ==="
printf '%s\n' "$foreign" "$begin_marker" "$bob" > "$file"
cp "$file" "$work/damaged"
check "нет метки END — ошибка" sync_fails "$file" "$alice" ""
check "файл не изменён" cmp "$work/damaged" "$file"
printf '%s\n' "$foreign" "$end_marker" "$bob" > "$file"
cp "$file" "$work/damaged"
check "метка END без BEGIN — ошибка" sync_fails "$file" "$alice" ""
check "файл не изменён" cmp "$work/damaged" "$file"

echo "=== setup_ssh: пользователь с другой основной группой ==="
useradd -m -g users -s /bin/bash keys_grp
# A separate shell keeps errexit active, as in a real run.
check "setup_ssh проходит" bash -c 'source ./admin_init.sh; setup_ssh keys_grp > /dev/null'
grp_keys=/home/keys_grp/.ssh/authorized_keys
check "установлены 4 ключа" key_count_is "$grp_keys" 4
check "владелец — пользователь" test "$(stat -c %U:%G "$grp_keys" 2>/dev/null)" = keys_grp:users
check "права 600 на authorized_keys" test "$(stat -c %a "$grp_keys" 2>/dev/null)" = 600
check "права 700 на .ssh" test "$(stat -c %a /home/keys_grp/.ssh 2>/dev/null)" = 700

echo "=== Сквозной отзыв: ключ в REVOKED_SSH_KEYS исчезает у всех пользователей ==="
orange_key=$(grep ' orange$' <<< "$SSH_KEYS")
bash ./admin_init.sh > /dev/null 2>&1 || true
# An account as the previous script version left it: plain lines, no block.
printf '%s\n' "$SSH_KEYS" > /home/byak/.ssh/authorized_keys
sed "s|^readonly REVOKED_SSH_KEYS=''\$|readonly REVOKED_SSH_KEYS='$orange_key'|" admin_init.sh > "$work/revoked.sh"
check "ключ найден в SSH_KEYS" test -n "$orange_key"
check "копия скрипта получила список отзыва" grep -qF "REVOKED_SSH_KEYS='$orange_key'" "$work/revoked.sh"
check "запуск с отзывом проходит" quiet bash "$work/revoked.sh"
for user in admin_init orange byak; do
    keys="/home/$user/.ssh/authorized_keys"
    check "$user: отозванный ключ не работает" lacks_key "$keys" "$orange_key"
    check "$user: остальные три ключа работают" key_count_is "$keys" 3
done
check "запуск без отзыва проходит" quiet bash ./admin_init.sh
check "ключ возвращается, когда отзыв снят" has_key /home/byak/.ssh/authorized_keys "$orange_key"

if [ "$failures" -ne 0 ]; then
    echo "=== SSH key tests: $failures failed ===" >&2
    exit 1
fi
echo '=== SSH key tests passed ==='
