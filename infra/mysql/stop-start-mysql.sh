#!/usr/bin/env bash
set -euo pipefail
RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
CMD="${1:-status}"  # stop|start|restart|status

case "$CMD" in
  stop)    az mysql flexible-server stop -g "$RG" -n "$SERVER" ;;
  start)   az mysql flexible-server start -g "$RG" -n "$SERVER" ;;
  restart) az mysql flexible-server restart -g "$RG" -n "$SERVER" ;;
  status)  az mysql flexible-server show -g "$RG" -n "$SERVER" --query state -o tsv ;;
  *) echo "Usage: $0 {stop|start|restart|status}" ; exit 1 ;;
esac
