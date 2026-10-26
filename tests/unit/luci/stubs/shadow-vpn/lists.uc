'use strict';

// Test stand-in for shadow-vpn.lists (CONTRACTS §6).
import { readfile, stat } from 'fs';
import { ETC } from 'shadow-vpn.const';

function load(kind) {
	const text = readfile(`${ETC}/lists/${kind}.lst`);

	return text ? filter(split(trim(text), '\n'), d => d != '') : [];
}

function info(kind) {
	const st = stat(`${ETC}/lists/${kind}.lst`);

	return { count: length(load(kind)), updated: st ? st.mtime : null };
}

function parse(text) {
	return { domains: sort(filter(split(text, /[ \t\n]+/), d => d != '')) };
}

function store(kind, domains) {
	return { changed: false, count: length(domains) };
}

export { load, info, parse, store };
