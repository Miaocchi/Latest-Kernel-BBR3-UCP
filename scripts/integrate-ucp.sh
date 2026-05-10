#!/usr/bin/env bash
set -euo pipefail

: "${UCP_REPO:=https://github.com/liulilittle/ucp.git}"
: "${UCP_REF:=}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  echo "python3 or python is required" >&2
  exit 1
fi

if [ -n "$UCP_REF" ]; then
  git clone --depth 1 --branch "$UCP_REF" "$UCP_REPO" "$workdir/ucp"
else
  git clone --depth 1 "$UCP_REPO" "$workdir/ucp"
fi
ucp_commit="$(git -C "$workdir/ucp" rev-parse --short=12 HEAD)"
echo "Using UCP source ${UCP_REPO}@${ucp_commit}"

install -m 0644 "$workdir/ucp/linux/tcp_ucp.c" net/ipv4/tcp_ucp.c

"$python_bin" - <<'PY'
import re
from pathlib import Path

tcp_h = Path('include/net/tcp.h')
ucp_c = Path('net/ipv4/tcp_ucp.c')

tcp_api = tcp_h.read_text(encoding='utf-8')
text = ucp_c.read_text(encoding='utf-8')
has_tso_segs = bool(re.search(r'[;\n]\s*(?:u32|void)\s*\(\*tso_segs\)\s*\(', tcp_api))
has_min_tso_segs = bool(re.search(r'[;\n]\s*u32\s*\(\*min_tso_segs\)\s*\(', tcp_api))

if re.search(r'void\s*\(\*cong_control\)\s*\(\s*struct sock \*sk\s*,\s*u32 ack\s*,\s*int flags?\s*,', tcp_api):
    old = 'static void ucp_main(struct sock* sk, const struct rate_sample* rs)\n{\n'
    new = ('static void ucp_main(struct sock* sk, u32 ack, int flags, '\
           'const struct rate_sample* rs)\n{\n'
           '    (void)ack;\n'
           '    (void)flags;\n')
    if old in text:
        text = text.replace(old, new, 1)

if has_tso_segs and not has_min_tso_segs:
    if 'static void ucp_tso_segs(' not in text and 'static u32 ucp_tso_segs(' not in text:
        match = re.search(r'\nstatic u32 ucp_tso_segs_goal\(struct sock\* sk\)\n\{.*?\n\}\n', text, re.S)
        if not match:
            raise RuntimeError('Could not find ucp_tso_segs_goal')
        insert_at = match.end()

        if re.search(r'u32\s*\(\*tso_segs\)\s*\(', tcp_api):
            wrapper = '''
/**
 * ucp_tso_segs - TCP CC callback for TSO segment sizing.
 * @sk: socket
 * @mss_now: current MSS, unused because UCP calculates from tp->mss_cache
 *
 * Return: target TSO segment count.
 */
static u32 ucp_tso_segs(struct sock* sk, unsigned int mss_now)
{
    (void)mss_now;
    return ucp_tso_segs_goal(sk);
}

'''
        elif re.search(r'void\s*\(\*tso_segs\)\s*\([^;]*u32\s*\*', tcp_api, re.S):
            wrapper = '''
/**
 * ucp_tso_segs - Kernel 7.0 TCP CC callback for TSO segment sizing.
 * @sk: socket
 * @mss_now: current MSS, unused because UCP calculates from tp->mss_cache
 * @segs: in/out TSO segment count
 */
static void ucp_tso_segs(struct sock* sk, u32 mss_now, u32* segs)
{
    u32 goal;

    (void)mss_now;
    goal = ucp_tso_segs_goal(sk);
    if (*segs < goal)
        *segs = goal;
}

'''
        elif re.search(r'void\s*\(\*tso_segs\)\s*\([^;]*u32\s*[,)]', tcp_api, re.S):
            wrapper = '''
/**
 * ucp_tso_segs - Kernel 7.0 TCP CC callback for TSO segment sizing.
 * @sk: socket
 * @mss_now: current MSS, unused because UCP calculates from tp->mss_cache
 * @segs: caller-provided segment count
 */
static void ucp_tso_segs(struct sock* sk, u32 mss_now, u32 segs)
{
    (void)mss_now;
    (void)segs;
    ucp_tso_segs_goal(sk);
}

'''
        else:
            raise RuntimeError('Unsupported tcp_congestion_ops.tso_segs signature')

        text = text[:insert_at] + wrapper + text[insert_at:]
    text = text.replace('.min_tso_segs = ucp_min_tso_segs,',
                        '.tso_segs = ucp_tso_segs,')

ucp_c.write_text(text, encoding='utf-8')
PY

if ! grep -q 'CONFIG_TCP_CONG_UCP)' net/ipv4/Makefile; then
  if grep -q 'CONFIG_TCP_CONG_BBR)' net/ipv4/Makefile; then
    sed -i '/CONFIG_TCP_CONG_BBR)/a obj-$(CONFIG_TCP_CONG_UCP) += tcp_ucp.o' net/ipv4/Makefile
  else
    printf '\nobj-$(CONFIG_TCP_CONG_UCP) += tcp_ucp.o\n' >> net/ipv4/Makefile
  fi
fi

"$python_bin" - <<'PY'
from pathlib import Path

kconfig = Path('net/ipv4/Kconfig')
text = kconfig.read_text(encoding='utf-8')

ucp_config = '''
config TCP_CONG_UCP
	tristate "UCP TCP"
	depends on TCP_CONG_ADVANCED
	default n
	help
	  Universal Communication Protocol TCP congestion control from
	  https://github.com/liulilittle/ucp.
'''

if 'config TCP_CONG_UCP' not in text:
    marker = 'config TCP_CONG_BBR\n'
    if marker in text:
        start = text.index(marker)
        next_config = text.find('\nconfig ', start + len(marker))
        endif = text.find('\nendif', start + len(marker))
        insert_at = next_config if next_config != -1 and (endif == -1 or next_config < endif) else endif
    else:
        insert_at = text.find('\nchoice\n\tprompt "Default TCP congestion control"')
    if insert_at == -1:
        raise RuntimeError('Could not find insertion point for TCP_CONG_UCP')
    text = text[:insert_at] + '\n' + ucp_config + text[insert_at:]

if 'config DEFAULT_UCP' not in text:
    marker = 'config DEFAULT_BBR\n'
    if marker in text:
        start = text.index(marker)
        next_config = text.find('\nconfig ', start + len(marker))
        insert_at = next_config if next_config != -1 else start
        default_ucp = '''
config DEFAULT_UCP
	bool "UCP" if TCP_CONG_UCP=y
	help
	  Use the UCP TCP congestion control algorithm as default.
'''
        text = text[:insert_at] + '\n' + default_ucp + text[insert_at:]

default_map = 'default "bbr" if DEFAULT_BBR\n'
if default_map in text and 'default "ucp" if DEFAULT_UCP' not in text:
    text = text.replace(default_map, '\tdefault "ucp" if DEFAULT_UCP\n' + default_map, 1)
elif 'default "cubic"\n' in text and 'default "ucp" if DEFAULT_UCP' not in text:
    text = text.replace('default "cubic"\n', '\tdefault "ucp" if DEFAULT_UCP\n\tdefault "cubic"\n', 1)
elif 'default "ucp" if DEFAULT_UCP' in text:
    text = text.replace('\tdefault "ucp" if DEFAULT_UCP\n', '')
    if default_map in text:
        text = text.replace(default_map, '\tdefault "ucp" if DEFAULT_UCP\n' + default_map, 1)
    else:
        text = text.replace('default "cubic"\n', '\tdefault "ucp" if DEFAULT_UCP\n\tdefault "cubic"\n', 1)

kconfig.write_text(text, encoding='utf-8')
PY
