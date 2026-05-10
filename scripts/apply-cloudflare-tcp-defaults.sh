#!/usr/bin/env bash
set -euo pipefail

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  echo "python3 or python is required" >&2
  exit 1
fi

"$python_bin" - <<'PY'
import re
from pathlib import Path


def read(path):
    return Path(path).read_text(encoding='utf-8')


def write(path, text):
    Path(path).write_text(text, encoding='utf-8')


tcp_ipv4 = Path('net/ipv4/tcp_ipv4.c')
text = read(tcp_ipv4)

replacements = {
    'net->ipv4.sysctl_tcp_notsent_lowat = UINT_MAX;':
        'net->ipv4.sysctl_tcp_notsent_lowat = 131072;',
    'net->ipv4.sysctl_tcp_sack = 1;':
        'net->ipv4.sysctl_tcp_sack = 1;',
    'net->ipv4.sysctl_tcp_adv_win_scale = 1;':
        'net->ipv4.sysctl_tcp_adv_win_scale = -2;',
    'net->ipv4.sysctl_tcp_fastopen = TFO_CLIENT_ENABLE;':
        'net->ipv4.sysctl_tcp_fastopen = TFO_CLIENT_ENABLE | TFO_SERVER_ENABLE;',
    'net->ipv4.sysctl_tcp_collapse_max_bytes = 0;':
        'net->ipv4.sysctl_tcp_collapse_max_bytes = 6291456;',
}

for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new, 1)

write(tcp_ipv4, text)

tcp_c = Path('net/ipv4/tcp.c')
text = read(tcp_c)
text = re.sub(
    r'init_net\.ipv4\.sysctl_tcp_wmem\[2\] = max\([^;]+?max_wshare\);',
    'init_net.ipv4.sysctl_tcp_wmem[2] = max(64*1024*1024, max_wshare);',
    text,
    count=1,
)
text = re.sub(
    r'init_net\.ipv4\.sysctl_tcp_rmem\[2\] = max\([^;]+?max_rshare\);',
    'init_net.ipv4.sysctl_tcp_rmem[2] = max(64*1024*1024, max_rshare);',
    text,
    count=1,
)
write(tcp_c, text)
PY
