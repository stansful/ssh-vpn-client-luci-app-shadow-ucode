'use strict';
// Runtime area: config, secrets, state, metrics, xray render, gate-set, fw4-hook heals, apply render,
// tunnel-check, uci-defaults, the helpers' shebangs and the updater. Each case runs in its own ucode process against the
// real modules of every area. Cases that change the container (/etc/shadow-vpn, /var/run/shadow-vpn, nft,
// ip rules) put everything back; run.sh's container is thrown away anyway.

import { dirname, glob } from 'fs';

const HERE = dirname(sourcepath());
const MODS = `${HERE}/../../shadow-vpn/files/usr/share/ucode`;
const CASES = [ 'config', 'secrets', 'state', 'metrics', 'xray', 'gate', 'heal', 'apply_render', 'converge', 'tunnel_check',
	'uci_defaults', 'shell', 'update' ];

let failed = 0;

for (let name in CASES) {
	let rc = system(`ucode -L ${MODS} -L ${HERE}/runtime/lib ${HERE}/runtime/cases/${name}.uc`);

	if (rc != 0) {
		failed++;

		if (rc > 1)
			print(`not ok runtime/${name}: case exited with ${rc}\n`);
	}
}

exit(failed ? 1 : 0);
