#!/usr/bin/env bash
#
# Переключение исходящего IP для VPN-подсетей и 3proxy.
# Использование:
#   ./switch-vpn-ip.sh <ОСНОВНОЙ_IP> <ДОПОЛНИТЕЛЬНЫЙ_IP>
#   ./switch-vpn-ip.sh 1.1.1.1 2.2.2.2
#
# Можно и через переменные окружения:
#   PRIMARY_IP=1.1.1.1 SECONDARY_IP=2.2.2.2 ./switch-vpn-ip.sh

set -euo pipefail

# ---------- Настройки ----------
PRIMARY_IP="${1:-${PRIMARY_IP:-1.1.1.1}}"       # Основной
SECONDARY_IP="${2:-${SECONDARY_IP:-2.2.2.2}}"   # Дополнительный
IFACE="${IFACE:-eth0}"
VPN_SUBNETS=("10.7.0.0/24" "10.8.0.0/24" "10.9.0.0/24" "10.10.0.0/24")
POLICY_SUBNET="10.10.0.0/24"   # у этой подсети MASQUERADE с -m policy (IKEv2)

VPN_DIR="/opt/vpn-manager-docker"
VPN_SCRIPTS=("wg.py" "ovpn.py" "ikev2.py")
COMPOSE_SERVICES=(wireguard openvpn ikev2)
PROXY_CFG="/etc/3proxy/3proxy.cfg"
PROXY_CONTAINER="vpn-3proxy"
# --------------------------------

ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
for ip in "$PRIMARY_IP" "$SECONDARY_IP"; do
  [[ $ip =~ $ip_re ]] || { echo "Некорректный IP: $ip" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Запустите от root" >&2; exit 1; }

echo "Основной IP:       $PRIMARY_IP"
echo "Дополнительный IP: $SECONDARY_IP"
echo

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
  done < <(iptables -t nat -S POSTROUTING | grep -E -- "-s $net .*-o $IFACE .*-j SNAT" || true)
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
  grep -E '^(internal|external)' "$PROXY_CFG"
  docker restart "$PROXY_CONTAINER"
else
  echo "  файл не найден: $PROXY_CFG" >&2
fi

echo
echo "Готово. Проверка: iptables -t nat -S POSTROUTING"
