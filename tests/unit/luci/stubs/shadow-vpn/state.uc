'use strict';

// Test stand-in for shadow-vpn.state (CONTRACTS §8).
import { readfile, writefile, mkdir } from 'fs';
import { RUN } from 'shadow-vpn.const';

function load(path, dflt) {
	try {
		return json(readfile(path) ?? '') ?? dflt;
	}
	catch (e) {
		return dflt;
	}
}

function read() {
	return load(RUN + '/state.json', null);
}

function write(patch) {
	const st = { ...(read() ?? {}), ...patch };

	mkdir(RUN, 0o700);
	writefile(RUN + '/state.json', sprintf('%J', st));

	return st;
}

function attention_list() {
	return load(RUN + '/attention.json', []);
}

function attention_add(code, message, extra) {
	const list = attention_list();

	push(list, { id: `${code}-${length(list) + 1}`, code, message, since: time(), extra });
	mkdir(RUN, 0o700);
	writefile(RUN + '/attention.json', sprintf('%J', list));
}

function attention_dismiss(id) {
	writefile(RUN + '/attention.json', sprintf('%J', filter(attention_list(), a => a.id != id)));
}

function attention_clear(code) {
	writefile(RUN + '/attention.json', sprintf('%J', filter(attention_list(), a => a.code != code)));
}

function job_read(id) {
	return load(`${RUN}/jobs/${id}.json`, null);
}

function job_write(id, patch) {
	mkdir(RUN + '/jobs', 0o700);
	writefile(`${RUN}/jobs/${id}.json`, sprintf('%J', { ...(job_read(id) ?? { id }), ...patch }));
}

function uptime() {
	return int(split(readfile('/proc/uptime') ?? '0', ' ')[0]);
}

export { read, write, attention_list, attention_add, attention_dismiss, attention_clear, job_read, job_write, uptime };
