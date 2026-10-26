'use strict';

import { access, writefile, mkdir, unlink, rmdir } from 'fs';
import * as state from 'shadow-vpn.state';
import { ok, eq, run, done } from 'rt';

// state.tunnel_health() against a stand-in for xray's metrics listener (uhttpd serving a canned
// /debug/vars), so the result never depends on when xray's observatory happens to probe.
const RUN = '/var/run/shadow-vpn', WWW = '/tmp/rt-metrics';

function listening(port) {
	return run(sprintf("grep -qE '^ *[0-9]+: [0-9A-F]{8}:%04X [0-9A-F]{8}:0000 0A ' /proc/net/tcp", port)).rc == 0;
}

if (!access('/usr/lib/ucode/socket.so')) {
	print('ok metrics # skipped: ucode-mod-socket is not installed\n');
	done();
}

if (access(RUN) || listening(12348)) {
	print('ok metrics # skipped: shadow-vpn state or a metrics listener already present\n');
	done();
}

mkdir('/var/run', 0o755);
mkdir(RUN, 0o700);

eq('metrics/nothing listens: unknown', state.tunnel_health(), { alive: null, fallback: null, delay_ms: null });

writefile(`${RUN}/fallback`, 'direct\n');
run(`mkdir -p ${WWW}/debug`);

function serve(body) {
	writefile(`${WWW}/debug/vars`, (type(body) == 'string') ? body : sprintf('%J\n', body));
}

serve({});

let pid = trim(run(`sh -c "uhttpd -f -p 127.0.0.1:12348 -h ${WWW} >/dev/null 2>&1 & echo \\$!"`).out);

for (let i = 0; i < 50 && !listening(12348); i++)
	sleep(100);

if (ok('metrics/stand-in listens', listening(12348))) {
	serve({ cmdline: [ 'xray', 'run' ], observatory: { proxy: { alive: true, delay: 42, outbound_tag: 'proxy' } } });
	eq('metrics/alive, with its delay', state.tunnel_health(), { alive: true, fallback: 'direct', delay_ms: 42 });

	// protobuf JSON leaves out alive=false
	serve({ observatory: { proxy: { outbound_tag: 'proxy', last_error_reason: 'io: read/write on closed pipe' } } });
	eq('metrics/dead tunnel', state.tunnel_health(), { alive: false, fallback: 'direct', delay_ms: null });

	serve({ cmdline: [ 'xray', 'run' ], memstats: { Alloc: 1 } });
	eq('metrics/not probed yet', state.tunnel_health(), { alive: null, fallback: 'direct', delay_ms: null });

	serve('{ "observatory": ');
	eq('metrics/cut-off body', state.tunnel_health(), { alive: null, fallback: 'direct', delay_ms: null });
}

run(`kill ${pid}`);
run(`rm -rf ${WWW}`);
unlink(`${RUN}/fallback`);
rmdir(RUN);

done();
