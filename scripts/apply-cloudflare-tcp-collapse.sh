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


path = 'include/net/netns/ipv4.h'
text = read(path)
if 'sysctl_tcp_collapse_max_bytes' not in text:
    marker = '\tu8 sysctl_tcp_retrans_collapse;\n'
    if marker not in text:
        marker = '\tint sysctl_tcp_adv_win_scale;'
    text = text.replace(marker, marker + '\tunsigned int sysctl_tcp_collapse_max_bytes;\n', 1)
write(path, text)

path = 'include/trace/events/tcp.h'
text = read(path)
if 'tcp_collapse_max_bytes_exceeded' not in text:
    event = '''
DEFINE_EVENT(tcp_event_sk, tcp_collapse_max_bytes_exceeded,

	TP_PROTO(struct sock *sk),

	TP_ARGS(sk)
);

'''
    text = text.replace('TRACE_EVENT(tcp_retransmit_synack,', event + 'TRACE_EVENT(tcp_retransmit_synack,', 1)
write(path, text)

path = 'net/ipv4/sysctl_net_ipv4.c'
text = read(path)
if 'tcp_collapse_max_bytes' not in text:
    entry = '''
	{
		.procname	= "tcp_collapse_max_bytes",
		.data		= &init_net.ipv4.sysctl_tcp_collapse_max_bytes,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_douintvec_minmax,
	},
'''
    match = re.search(r'\n\t\{\n\t\t\.procname\s*=\s*"tcp_retrans_collapse",.*?\n\t\},\n', text, re.S)
    if match:
        text = text[:match.end()] + entry + text[match.end():]
    else:
        text = text.replace('\n\t{ }\n};', entry + '\n\t{ }\n};', 1)
write(path, text)

path = 'net/ipv4/tcp_input.c'
text = read(path)
if 'sysctl_tcp_collapse_max_bytes' not in text:
    text = re.sub(
        r'(static int tcp_prune_queue\([^)]*\)\n\{\n\s*struct tcp_sock \*tp = tcp_sk\(sk\);\n)',
        r'\1\tstruct net *net = sock_net(sk);\n',
        text,
        count=1,
    )
    guard = '''
	if (net->ipv4.sysctl_tcp_collapse_max_bytes &&
	    atomic_read(&sk->sk_rmem_alloc) > net->ipv4.sysctl_tcp_collapse_max_bytes) {
		trace_tcp_collapse_max_bytes_exceeded(sk);
		goto do_not_collapse;
	}

'''
    text = text.replace('\n\ttcp_collapse_ofo_queue(sk);\n', '\n' + guard + '\ttcp_collapse_ofo_queue(sk);\n', 1)
    text = text.replace('\n\t/* If we are really being abused,', '\ndo_not_collapse:\n\n\t/* If we are really being abused,', 1)
write(path, text)

path = 'net/ipv4/tcp_ipv4.c'
text = read(path)
if 'sysctl_tcp_collapse_max_bytes = 0' not in text:
    marker = '\n\tnet->ipv4.sysctl_tcp_syn_linear_timeouts = 4;\n'
    if marker in text:
        text = text.replace(marker, '\n\tnet->ipv4.sysctl_tcp_collapse_max_bytes = 0;\n' + marker.lstrip('\n'), 1)
    else:
        text = text.replace('\n\treturn 0;\n}', '\n\tnet->ipv4.sysctl_tcp_collapse_max_bytes = 0;\n\n\treturn 0;\n}', 1)
write(path, text)
PY
