#!/bin/sh
# HTTP responder of tests/unit/ssh/e2e-sshd.sh (socat EXEC). It reads the request up to the blank
# line before it answers: closing with unread request bytes would reset the connection.
cr=$(printf '\r')
while IFS= read -r line; do
	[ "${line%"$cr"}" = "" ] && break
done
printf 'HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nshadow-ok\n'
