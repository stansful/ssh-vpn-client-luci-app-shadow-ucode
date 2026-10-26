'use strict';

// CLI test stand-in for state.uc: attention entries are appended to attention.json for suite.uc to read.

import { readfile, writefile } from 'fs';

const PATH = '/tmp/shv-routing-cli/attention.json';

export function attention_list() {
	return json(readfile(PATH) ?? '[]');
};

export function attention_add(code, message, extra) {
	let list = attention_list();

	push(list, { code, message, extra });
	writefile(PATH, sprintf('%J', list));
};

// id: "<code>:<key>" as the real state.uc builds it
export function attention_dismiss(id) {
	writefile(PATH, sprintf('%J', filter(attention_list(), (a) => (a.extra?.key != null ? `${a.code}:${a.extra.key}` : a.code) != id)));
};

// what the CLI logs, for suite.uc to read
export function log(level, message) {
	let path = '/tmp/shv-routing-cli/log.txt';

	writefile(path, (readfile(path) ?? '') + `${level} ${message}\n`);
};

export function set_log_level(level) {
};
