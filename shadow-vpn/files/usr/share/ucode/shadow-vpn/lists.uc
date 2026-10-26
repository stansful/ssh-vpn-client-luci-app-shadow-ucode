'use strict';

// Domain lists (DESIGN §9): the desktop parser (src/core/routing/domain-proxy-list.ts) and the last good
// copy on flash, ETC/lists/<kind>.lst with a sha256sum-style <kind>.sha256 next to it.

import * as fs from 'fs';
import { sha256 } from 'digest';
import { ETC, RUN, LIMITS } from 'shadow-vpn.const';

// the desktop label regex; {0,61} is replaced by a length check (bounded repeats are slow in musl)
const LABEL = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
const BLANKS = /[ \t\r\n\f\v]+/;
const MAX_DOMAINS = LIMITS.list_domains;

// desktop normalizeProxyDomain: 'x.y', or '.x' for the suffix form ('*.x' and '.x'); null when invalid.
export function normalize_domain(token) {
	let s = lc(trim(`${token ?? ''}`));

	if (substr(s, -1) == '.')
		s = substr(s, 0, -1);

	if (s == '' || substr(s, 0, 1) == '#')
		return null;

	let suffix = substr(s, 0, 1) == '.' || substr(s, 0, 2) == '*.';
	let domain = (substr(s, 0, 2) == '*.') ? substr(s, 2) : (substr(s, 0, 1) == '.') ? substr(s, 1) : s;

	if (domain == '' || length(domain) > 253)
		return null;

	let labels = split(domain, '.');

	// A leading dot names a TLD suffix such as '.ua'; a bare single label (localhost) is not a list entry.
	if (!suffix && length(labels) < 2)
		return null;

	for (let label in labels)
		if (length(label) > 63 || !match(label, LABEL))
			return null;

	return suffix ? `.${domain}` : domain;
};

// desktop parseDomainProxyList plus the refresh's empty-result check.
export function parse(text, kind) {
	let seen = {}, count = 0;

	for (let token in split(`${text ?? ''}`, BLANKS)) {
		let domain = normalize_domain(token);

		if (domain == null || seen[domain])
			continue;

		seen[domain] = true;

		if (++count > MAX_DOMAINS)
			return { error: `Domain proxy list is larger than ${MAX_DOMAINS} entries.` };
	}

	if (!count)
		return { error: `Routing ${kind ?? 'proxy'} list refresh returned no domains.` };

	return { domains: sort(keys(seen)) };
};

function valid_kind(kind) {
	return kind == 'proxy' || kind == 'direct';
}

function paths(kind, opts) {
	let dir = opts?.dir ?? `${ETC}/lists`;

	return {
		dir,
		list: `${dir}/${kind}.lst`,
		sum: `${dir}/${kind}.sha256`,
		run: opts?.run ?? RUN,
		stamp: `${opts?.run ?? RUN}/lists.${kind}.checked`
	};
}

function read_sum(path) {
	let m = match(fs.readfile(path) ?? '', /^([0-9a-f]{64}) /);

	return m ? m[1] : null;
}

function mkdir_p(path) {
	if (fs.stat(path)?.type == 'directory')
		return true;

	if (!mkdir_p(fs.dirname(path)))
		return false;

	return fs.mkdir(path, 0o700) || fs.stat(path)?.type == 'directory';
}

// fs has no fsync; busybox ships the applet. Without it a power cut after rename can leave an empty file.
function fsync(path) {
	system([ 'fsync', path ]);
}

function write_synced(path, data) {
	let f = fs.open(path, 'w', 0o600);

	if (!f)
		return false;

	let ok = f.write(data) == length(data);

	f.close();
	fs.chmod(path, 0o600);
	fsync(path);

	return ok;
}

// The list text when it matches its stored hash. A store cut off between its two renames has left the
// matching hash in <kind>.sha256.tmp; that copy is finished here.
function read_verified(p) {
	let body = fs.readfile(p.list);

	if (body == null)
		return null;

	let hash = sha256(body);

	if (read_sum(p.sum) == hash)
		return body;

	if (read_sum(`${p.sum}.tmp`) != hash)
		return null;

	fs.rename(`${p.sum}.tmp`, p.sum);

	return body;
}

// Domains as parse() returns them; [] when the file is missing or does not match its hash.
export function load(kind, opts) {
	if (!valid_kind(kind))
		return [];

	let body = read_verified(paths(kind, opts));
	let out = [];

	for (let line in split(body ?? '', '\n')) {
		let domain = normalize_domain(line);

		if (domain != null)
			push(out, domain);
	}

	return out;
};

// Writes the list only when its content changed (flash wear): tmp + fsync + rename for the list and
// then its hash. Every successful refresh is stamped on tmpfs, so 'due' does not refetch an unchanged
// list every hour. The caller serialises stores (the CLI holds LOCK).
export function store(kind, domains, opts) {
	if (!valid_kind(kind) || type(domains) != 'array')
		return { changed: false, count: 0, error: 'Invalid list.' };

	let p = paths(kind, opts);
	let body = length(domains) ? join('\n', domains) + '\n' : '';
	let hash = sha256(body);
	let changed = read_sum(p.sum) != hash || read_verified(p) != body;

	if (changed) {
		if (!mkdir_p(p.dir) ||
		    !write_synced(`${p.list}.tmp`, body) ||
		    !write_synced(`${p.sum}.tmp`, `${hash}  ${kind}.lst\n`) ||
		    !fs.rename(`${p.list}.tmp`, p.list) ||
		    !fs.rename(`${p.sum}.tmp`, p.sum))
			return { changed: false, count: 0, error: `Cannot write ${p.list}.` };

		fsync(p.dir);
	}

	if (mkdir_p(p.run))
		fs.writefile(p.stamp, `${time()}\n`);

	return { changed, count: length(domains) };
};

// updated: the last successful refresh (this boot) or the last change on flash, whichever is newer.
export function info(kind, opts) {
	if (!valid_kind(kind))
		return { count: 0, updated: null };

	let p = paths(kind, opts);
	let body = read_verified(p);

	if (body == null)
		return { count: 0, updated: null };

	let stamp = +(match(fs.readfile(p.stamp) ?? '', /^[0-9]+/)?.[0] ?? 0);
	let mtime = fs.stat(p.list)?.mtime ?? 0;

	return {
		count: (body == '') ? 0 : length(split(trim(body), '\n')),
		updated: (stamp > mtime) ? stamp : mtime
	};
};

// Downloads url with uclient-fetch: 15 s without progress (-T) or overall, LIMITS.download_bytes.
// opts.ipv4 forces IPv4 (the tunnel retry diverts only fetch4); opts.timeout overrides the deadline.
// { text } | { error, retry } where retry marks failures a path through the tunnel may avoid.
export function fetch(url, opts) {
	if (!match(url, /^https?:\/\/[-A-Za-z0-9.:_~%]+(\/[-A-Za-z0-9.:_~%]*)*$/))
		return { error: 'Routing list download failed: invalid URL.' };

	let cmd = sprintf("exec uclient-fetch -q -T 15 -Y off%s -O - '%s' 2>/dev/null", opts?.ipv4 ? ' -4' : '', url);
	let p = fs.popen(cmd, 'r');

	if (!p)
		return { error: 'Routing list download failed.' };

	let chunks = [], size = 0, error = null, retry = false;
	let deadline = time() + (opts?.timeout ?? 15);

	for (;;) {
		let chunk = p.read(65536);

		if (chunk == null || chunk == '')
			break;

		size += length(chunk);

		if (size > LIMITS.download_bytes) {
			error = 'Routing list is larger than the allowed limit.';
			break;
		}

		push(chunks, chunk);

		if (time() > deadline) {
			error = 'Routing list download timed out.';
			retry = true;
			break;
		}
	}

	// Closing early makes uclient-fetch exit on its next write (SIGPIPE), so this never waits long.
	let rc = p.close();

	if (error)
		return { error, retry };

	if (rc != 0)
		return { error: `Routing list download failed (uclient-fetch exit ${rc}).`, retry: true };

	return { text: join('', chunks) };
};
