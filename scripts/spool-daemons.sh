#!/usr/bin/env bash
# The reference spool daemons `scripts/check.sh spool` dials (ADR 2026-11.adrq, P5), in containers on this machine's
# loopback alone.
#
#     eval "$(scripts/spool-daemons.sh start)"           # two public daemons and a private one, at SPOOL_POW_BITS=8
#     eval "$(scripts/spool-daemons.sh start --heavy)"   # and one at 24 bits, for KNIT_SPOOL_HEAVY=1
#     scripts/check.sh spool
#     scripts/spool-daemons.sh stop
#
# The image is knit-spool built from a clean worktree at knit-spool's pin with its own Dockerfile and tagged by that commit
# (`.agents/context/spool.md`, "A daemon to test against"). The pin is enforced, not just recorded: unless KNIT_SPOOL_IMAGE
# names another image, `start` refuses a local tag whose image ID is not the pinned one, runs that ID, and never pulls.
# Every container publishes port 9470 on 127.0.0.1 alone at a port Docker picks, drops every capability, runs read-only
# with no new privileges and its store on a tmpfs, and is removed when it stops. The private daemon's token is minted at
# random per run and reaches the container through the environment, never its command line. `start` prints the variables
# the suite reads.

set -euo pipefail

# The tag and the ID it was built to on 2026-11-17 move together: a new knit-spool pin rebuilds the image, then updates both
# here and in spool.md.
pinned_tag=knit-spool:a682524
pinned_id=sha256:e21ae5b6d1956b02950667652942e5cd40fc4a6c8b3246e981ec72cfeac826d9
prefix=knit-spool-check

# The image `run` starts: the pinned ID, once the local tag is checked against it, or KNIT_SPOOL_IMAGE as given.
resolve_image() {
	if [ -n "${KNIT_SPOOL_IMAGE:-}" ]; then
		image=$KNIT_SPOOL_IMAGE
		return 0
	fi
	local id
	id=$(docker image inspect --format '{{.Id}}' "$pinned_tag" 2>/dev/null || true)
	if [ "$id" != "$pinned_id" ]; then
		echo "$pinned_tag is ${id:-missing}, not the pinned $pinned_id: build it from knit-spool's pin (spool.md)" >&2
		return 1
	fi
	image=$pinned_id
}

# One daemon named $1 at $2 bits of proof of work. A new scope every few seconds is the suite's pace, past the daemon's
# default of six a minute from one address. /tmp is executable because sqlite-jdbc loads its native library from there.
run() {
	local name=$1 bits=$2
	shift 2
	nice -n 10 docker run -d --rm --pull never --name "$prefix-$name" -p 127.0.0.1::9470 \
		--cap-drop ALL --security-opt no-new-privileges --read-only \
		--tmpfs /data:rw,size=64m,uid=65532,gid=65532,mode=0700 --tmpfs /tmp:rw,exec,nosuid,nodev,size=32m,mode=1777 \
		-e SPOOL_POW_BITS="$bits" -e SPOOL_RATE_NEW_SCOPES=600 "$@" "$image" >/dev/null
}

# The address of daemon $1, once it answers its health check on the loopback port Docker gave it.
address() {
	local port attempt
	port=$(docker port "$prefix-$1" 9470/tcp | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | head -n 1)
	if [ -z "$port" ]; then
		echo "$prefix-$1 publishes no port on 127.0.0.1" >&2
		return 1
	fi
	for attempt in $(seq 60); do
		if curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then
			echo "ws://127.0.0.1:$port/spool/v1"
			return 0
		fi
		sleep 0.5
		: "$attempt"
	done
	echo "$prefix-$1 never answered on 127.0.0.1:$port" >&2
	return 1
}

case "${1:-}" in
start)
	resolve_image
	run a 8
	run b 8
	token=$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
	SPOOL_TOKEN=$token run private 8 -e SPOOL_TOKEN
	echo "export KNIT_SPOOL_URL=$(address a)"
	echo "export KNIT_SPOOL_URL_2=$(address b)"
	echo "export KNIT_SPOOL_PRIVATE_URL=$(address private)"
	echo "export KNIT_SPOOL_TOKEN=$token"
	if [ "${2:-}" = --heavy ]; then
		run heavy 24
		echo "export KNIT_SPOOL_HEAVY=1"
		echo "export KNIT_SPOOL_HEAVY_URL=$(address heavy)"
	fi
	;;
stop)
	mapfile -t running < <(docker ps --filter "name=^$prefix-" --format '{{.Names}}')
	if [ "${#running[@]}" -gt 0 ]; then
		docker stop "${running[@]}" >/dev/null
	fi
	;;
*)
	sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
	exit 2
	;;
esac
