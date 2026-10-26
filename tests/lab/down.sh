#!/bin/bash
# Removes the Shadow lab containers and networks (label com.shadow.testenv=1). Images and state/ are kept.
#   PURGE_IMAGES=1 ./down.sh   also removes the shadow-testenv/* images
set -uo pipefail
LABEL="com.shadow.testenv=1"
ids=$(docker ps -aq --filter "label=$LABEL")
[ -n "$ids" ] && docker rm -f $ids >/dev/null
for n in $(docker network ls -q --filter "label=$LABEL"); do docker network rm "$n" >/dev/null; done
if [ "${PURGE_IMAGES:-0}" = 1 ]; then
  docker images --format '{{.Repository}}:{{.Tag}}' | grep '^shadow-testenv/' | xargs -r docker rmi >/dev/null
fi
docker ps -a --filter "label=$LABEL" --format '{{.Names}}'; docker network ls --filter "label=$LABEL" --format '{{.Name}}'
echo "lab down"
