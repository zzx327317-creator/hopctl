#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/fw"

cat > "$tmp/bin/mock-iptables" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
family=${0##*/}
state="$MOCK_FW/$family"
mkdir -p "$state"
[[ ${1:-} == -w ]] && shift 2
[[ ${1:-} == -t && ${2:-} == nat ]] && shift 2
op=${1:-}; shift || true
chain=${1:-}; shift || true
case $op:$chain in
  -S:HOPCTL)
    [[ -f $state/rules ]] || exit 1
    printf '%s\n' '-N HOPCTL'
    cat "$state/rules"
    ;;
  -N:HOPCTL) [[ ! -f $state/rules ]] || exit 1; : > "$state/rules" ;;
  -C:PREROUTING) [[ -f $state/jump ]] ;;
  -I:PREROUTING) touch "$state/jump"; printf 'jump\n' >> "$state/mutations" ;;
  -C:HOPCTL)
    line="-A HOPCTL $*"
    grep -Fxq -- "$line" "$state/rules"
    ;;
  -A:HOPCTL)
    if [[ $family == mock-ip6tables && ${MOCK_FAIL6_PORT:-} == 5000 && " $* " == *' --dport 5000 '* ]]; then
      exit 1
    fi
    printf '%s\n' "-A HOPCTL $*" >> "$state/rules"
    printf 'add\n' >> "$state/mutations"
    ;;
  -F:HOPCTL) : > "$state/rules"; printf 'flush\n' >> "$state/mutations" ;;
  *) printf 'unexpected mock call: %s %s %s\n' "$op" "$chain" "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/mock-iptables"
cp "$tmp/bin/mock-iptables" "$tmp/bin/mock-ip6tables"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/mock-flock"
chmod +x "$tmp/bin/mock-flock"

export HOPCTL_TEST_MODE=1
export HOPCTL_CONFIG_DIR="$tmp/config"
export HOPCTL_LOCK_FILE="$tmp/hopctl.lock"
export HOPCTL_IPTABLES4="$tmp/bin/mock-iptables"
export HOPCTL_IPTABLES6="$tmp/bin/mock-ip6tables"
export HOPCTL_FLOCK="$tmp/bin/mock-flock"
export MOCK_FW="$tmp/fw"

bash "$root/hopctl" add udp 2000-2999 4443
[[ $(wc -l < "$tmp/config/rules.tsv") -eq 1 ]]
grep -Fq -- $'1\tudp\t2000\t2999\t4443' "$tmp/config/rules.tsv"
for family in mock-iptables mock-ip6tables; do
  grep -Fq -- '-p udp -m udp --dport 2000:2999' "$tmp/fw/$family/rules"
done

before=$(wc -l < "$tmp/fw/mock-iptables/mutations")
bash "$root/hopctl" add udp 2000-2999 4443
bash "$root/hopctl" apply
after=$(wc -l < "$tmp/fw/mock-iptables/mutations")
[[ $before -eq $after ]] || { echo 'idempotence failed' >&2; exit 1; }

bash "$root/hopctl" add both 3000-3999 4443
for family in mock-iptables mock-ip6tables; do
  [[ $(grep -c 'hopctl:2:' "$tmp/fw/$family/rules") -eq 2 ]]
done

menu_output=$(printf '2\n0\n' | bash "$root/hopctl")
grep -Fxq '  1) 添加转发规则' <<< "$menu_output"
grep -Fxq '  2) 查看规则状态' <<< "$menu_output"
grep -Fxq '  3) 删除指定规则' <<< "$menu_output"
grep -Fxq '  4) 校验并修复规则' <<< "$menu_output"
grep -Fxq '  0) 退出' <<< "$menu_output"
grep -Fxq '      公网端口：2000-2999' <<< "$menu_output"
grep -Fxq '      服务端口：4443' <<< "$menu_output"

if bash "$root/hopctl" add udp 2500-3500 4443 >/dev/null 2>&1; then
  echo 'overlap accepted' >&2; exit 1
fi

# Simulate firewall flush/reboot: empty both dedicated chains and remove jumps.
for family in mock-iptables mock-ip6tables; do
  : > "$tmp/fw/$family/rules"
  rm -f "$tmp/fw/$family/jump"
done
list_output=$(bash "$root/hopctl" list)
printf '%s\n' "$list_output"
grep -Fq '缺失' <<< "$list_output"
bash "$root/hopctl" apply
for family in mock-iptables mock-ip6tables; do
  [[ -f $tmp/fw/$family/jump ]]
  [[ $(grep -c '^-A HOPCTL' "$tmp/fw/$family/rules") -eq 3 ]]
done

bash "$root/hopctl" delete 1
[[ $(wc -l < "$tmp/config/rules.tsv") -eq 1 ]]
for family in mock-iptables mock-ip6tables; do
  ! grep -Fq 'hopctl:1:' "$tmp/fw/$family/rules"
  [[ $(grep -c 'hopctl:2:' "$tmp/fw/$family/rules") -eq 2 ]]
done

export MOCK_FAIL6_PORT=5000
if bash "$root/hopctl" add tcp 5000 443 >/dev/null 2>&1; then
  echo 'IPv6 failure incorrectly reported success' >&2; exit 1
fi
[[ $(wc -l < "$tmp/config/rules.tsv") -eq 1 ]]
for family in mock-iptables mock-ip6tables; do
  ! grep -Fq -- '--dport 5000' "$tmp/fw/$family/rules"
  [[ $(grep -c 'hopctl:2:' "$tmp/fw/$family/rules") -eq 2 ]]
done

echo 'PASS: dual stack, UDP/TCP, idempotence, recovery, selective delete, IPv6 rollback'
