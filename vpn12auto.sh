#!/usr/bin/env bash
#
# Переключение исходящего IP для VPN-подсетей и 3proxy.
# IP определяются автоматически, но их можно передать вручную.
#
# Применить (IP определятся сами):
#   ./vpn12.sh
# Применить с явными IP:
#   ./vpn12.sh <ОСНОВНОЙ_IP> <ДОПОЛНИТЕЛЬНЫЙ_IP>
#   ./vpn12.sh 1.1.1.1 2.2.2.2
# Только проверить, что настройка выполнена (ничего не меняет):
#   ./vpn12.sh --check
#   ./vpn12.sh --check 1.1.1.1 2.2.2.2
#
# IP можно задать и переменными окружения:
#   PRIMARY_IP=1.1.1.1 SECONDARY_IP=2.2.2.2 IFACE=eth0 ./vpn12.sh

set -euo pipefail

# ---------- Режим ----------
CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=1
  shift
fi

# ---------- Автоопределение (аргументы и переменные окружения приоритетнее) ----------
detect_iface() {
  ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true
}
detect_primary() {
  ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}
detect_secondary() {
  ip -4 -o addr show dev "$IFACE" scope global \
    | awk '{split($4,a,"/"); print a[1]}' | grep -vx "$PRIMARY_IP" | head -n1 || true
}

AUTO=0
[[ -z "${1:-}${2:-}${PRIMARY_IP:-}${SECONDARY_IP:-}" ]] && AUTO=1

IFACE="${IFACE:-$(detect_iface)}"; IFACE="${IFACE:-eth0}"
PRIMARY_IP="${1:-${PRIMARY_IP:-$(detect_primary)}}"            # Основной
SECONDARY_IP="${2:-${SECONDARY_IP:-$(detect_secondary)}}"      # Дополнительный

# ---------- Настройки ----------
VPN_SUBNETS=("10.7.0.0/24" "10.8.0.0/24" "10.9.0.0/24" "10.10.0.0/24")
POLICY_SUBNET="10.10.0.0/24"   # у этой подсети MASQUERADE с -m policy (IKEv2)

VPN_DIR="/opt/vpn-manager-docker"
VPN_SCRIPTS=("wg.py" "ovpn.py" "ikev2.py")
COMPOSE_SERVICES=(wireguard openvpn ikev2)
PROXY_CFG="/etc/3proxy/3proxy.cfg"
PROXY_CONTAINER="vpn-3proxy"
# --------------------------------

[[ $EUID -eq 0 ]] || { echo "Запустите от root" >&2; exit 1; }

ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
if [[ -z $PRIMARY_IP || -z $SECONDARY_IP ]]; then
  echo "Не удалось определить IP автоматически (интерфейс: $IFACE)." >&2
  echo "Передайте их вручную: $0 <ОСНОВНОЙ_IP> <ДОПОЛНИТЕЛЬНЫЙ_IP>" >&2
  exit 1
fi
for ip in "$PRIMARY_IP" "$SECONDARY_IP"; do
  [[ $ip =~ $ip_re ]] || { echo "Некорректный IP: $ip" >&2; exit 1; }
done
if [[ $PRIMARY_IP == "$SECONDARY_IP" ]]; then
  echo "Основной и дополнительный IP совпадают: $PRIMARY_IP" >&2
  exit 1
fi

# ---------- Проверка ----------
run_check() {
  local fail=0 net f svc

  ok()  { echo "  ✓ $1"; }
  bad() { echo "  ✗ $1"; fail=$((fail + 1)); }

  echo "==> Проверка (основной: $PRIMARY_IP, дополнительный: $SECONDARY_IP)"

  local rules
  rules="$(iptables -t nat -S POSTROUTING)"

  for net in "${VPN_SUBNETS[@]}"; do
    if grep -qE -e "-s $net .*-j SNAT --to-source $SECONDARY_IP" <<<"$rules"; then
      ok "iptables: SNAT $net -> $SECONDARY_IP"
    else
      bad "iptables: нет SNAT $net -> $SECONDARY_IP"
    fi
    if grep -qE -e "-s $net .*-j MASQUERADE" <<<"$rules"; then
      bad "iptables: MASQUERADE для $net всё ещё есть"
    else
      ok "iptables: MASQUERADE для $net удалён"
    fi
  done

  for f in "${VPN_SCRIPTS[@]}"; do
    local path="$VPN_DIR/vpn-scripts/$f"
    if [[ ! -f $path ]]; then
      bad "$f: файл не найден"
    elif grep -q "MASQUERADE" "$path"; then
      bad "$f: остался MASQUERADE"
    elif ! grep -q -e "-j SNAT --to-source $SECONDARY_IP" "$path"; then
      bad "$f: нет SNAT --to-source $SECONDARY_IP"
    else
      ok "$f: SNAT --to-source $SECONDARY_IP"
    fi
  done

  if [[ -f $PROXY_CFG ]]; then
    grep -qE "^internal[[:space:]]+$PRIMARY_IP\$" "$PROXY_CFG" \
      && ok "3proxy: internal $PRIMARY_IP" || bad "3proxy: internal не равен $PRIMARY_IP"
    grep -qE "^external[[:space:]]+$SECONDARY_IP\$" "$PROXY_CFG" \
      && ok "3proxy: external $SECONDARY_IP" || bad "3proxy: external не равен $SECONDARY_IP"
  else
    bad "3proxy: файл $PROXY_CFG не найден"
  fi

  local running
  running="$(cd "$VPN_DIR" && docker compose ps --status running --services 2>/dev/null || true)"
  for svc in "${COMPOSE_SERVICES[@]}"; do
    if grep -qx "$svc" <<<"$running"; then
      ok "контейнер $svc запущен"
    else
      bad "контейнер $svc не запущен"
    fi
  done
  if [[ "$(docker inspect -f '{{.State.Running}}' "$PROXY_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
    ok "контейнер $PROXY_CONTAINER запущен"
  else
    bad "контейнер $PROXY_CONTAINER не запущен"
  fi

  echo
  if (( fail == 0 )); then
    echo "Итог: всё настроено ✓"
    return 0
  else
    echo "Итог: проблем найдено: $fail ✗"
    return 1
  fi
}

echo "Интерфейс:         $IFACE"
echo "Основной IP:       $PRIMARY_IP"
echo "Дополнительный IP: $SECONDARY_IP"
(( AUTO )) && echo "(IP определены автоматически)"
echo

if (( CHECK_ONLY )); then
  run_check
  exit $?
fi

if (( AUTO )); then
  echo "Применение начнётся через 5 секунд. Если IP определены неверно, нажмите Ctrl+C"
  echo "и запустите скрипт с явными IP: $0 <ОСНОВНОЙ_IP> <ДОПОЛНИТЕЛЬНЫЙ_IP>"
  sleep 5
  echo
fi

# ---------- 1. Удаляем MASQUERADE ----------
echo "==> Удаляем правила MASQUERADE"
for net in "${VPN_SUBNETS[@]}"; do
  if [[ $net == "$POLICY_SUBNET" ]]; then
    rule=(-s "$net" -o "$IFACE" -m policy --dir out --pol none -j MASQUERADE)
  else
    rule=(-s "$net" -o "$IFACE" -j MASQUERADE)
  fi
  if iptables -t nat -C POSTROUTING "${rule[@]}" 2>/dev/null; then
    iptables -t nat -D POSTROUTING "${rule[@]}"
    echo "  удалено: $net"
  else
    echo "  не найдено (пропуск): $net"
  fi
done

# ---------- 2. Добавляем SNAT ----------
echo "==> Добавляем правила SNAT -> $SECONDARY_IP"
for net in "${VPN_SUBNETS[@]}"; do
  # убираем старые SNAT этой подсети (на случай другого --to-source), затем добавляем новый
  while read -r old; do
    [[ -n $old ]] && iptables -t nat ${old/-A/-D}
  done < <(iptables -t nat -S POSTROUTING | grep -E -e "-s $net .*-o $IFACE .*-j SNAT" || true)
  iptables -t nat -A POSTROUTING -s "$net" -o "$IFACE" -j SNAT --to-source "$SECONDARY_IP"
  echo "  добавлено: $net"
done

# ---------- 3. Правим скрипты VPN-менеджера ----------
echo "==> Правим скрипты в $VPN_DIR/vpn-scripts"
for f in "${VPN_SCRIPTS[@]}"; do
  path="$VPN_DIR/vpn-scripts/$f"
  if [[ -f $path ]]; then
    cp -n "$path" "$path.bak"
    sed -i \
      -e "s/-j MASQUERADE/-j SNAT --to-source $SECONDARY_IP/g" \
      -e "s/\(-j SNAT --to-source\) [0-9.]\+/\1 $SECONDARY_IP/g" \
      "$path"
    echo "  обновлён: $f"
  else
    echo "  файл не найден: $path" >&2
  fi
done

# ---------- 4. Перезапускаем контейнеры ----------
echo "==> Перезапуск контейнеров: ${COMPOSE_SERVICES[*]}"
( cd "$VPN_DIR" && docker compose restart "${COMPOSE_SERVICES[@]}" )

# ---------- 5. 3proxy ----------
echo "==> Правим $PROXY_CFG"
if [[ -f $PROXY_CFG ]]; then
  cp -n "$PROXY_CFG" "$PROXY_CFG.bak"
  sed -i -E \
    -e "s/^internal[[:space:]]+.*/internal $PRIMARY_IP/" \
    -e "s/^external[[:space:]]+.*/external $SECONDARY_IP/" \
    "$PROXY_CFG"
  docker restart "$PROXY_CONTAINER"
else
  echo "  файл не найден: $PROXY_CFG" >&2
fi

# ---------- 6. Итоговая проверка ----------
echo
sleep 3
run_check
