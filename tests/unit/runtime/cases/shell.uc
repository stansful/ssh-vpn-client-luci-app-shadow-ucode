'use strict';

import { readfile } from 'fs';
import { ok, run, done } from 'rt';

const FILES = '/src/shadow-vpn/files';
const SHELL = [
	[ 'etc/init.d/shadow-vpn', '#!/bin/sh /etc/rc.common' ],
	[ 'etc/hotplug.d/iface/99-shadow-vpn', '#!/bin/sh' ],
	[ 'etc/uci-defaults/80-shadow-vpn', '#!/bin/sh' ],
	[ 'usr/libexec/shadow-vpn/gate-set', '#!/bin/sh' ],
	[ 'usr/libexec/shadow-vpn/xray-run', '#!/bin/sh' ],
	[ 'usr/libexec/shadow-vpn/fw4-hook', '#!/bin/sh' ]
];
const UCODE = [ 'usr/libexec/shadow-vpn/apply', 'usr/libexec/shadow-vpn/job', 'usr/libexec/shadow-vpn/tunnel-check',
	'usr/libexec/shadow-vpn/update' ];

// a trailing comment on the shebang breaks it on Linux (lab)
for (let f in SHELL) {
	let first = split(readfile(`${FILES}/${f[0]}`) ?? '', '\n')[0];

	ok(`shell/${f[0]}: plain shebang`, first == f[1], first);

	let r = run(`sh -n ${FILES}/${f[0]}`);

	ok(`shell/${f[0]}: busybox ash parses it`, r.rc == 0, r.out);
}

for (let f in UCODE) {
	let lines = split(readfile(`${FILES}/${f}`) ?? '', '\n');

	ok(`shell/${f}: ucode shebang and strict mode`, lines[0] == '#!/usr/bin/ucode' && lines[1] == "'use strict';");
}

done();
