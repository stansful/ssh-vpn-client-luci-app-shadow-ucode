'use strict';

// Fallback for hosts without ucode-mod-socket: the metrics probe sees no listener.
export const POLLIN = 1, POLLHUP = 16;

function connect() {
	return null;
}

function poll() {
	return [];
}

export { connect, poll };
