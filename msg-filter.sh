#!/bin/sh
case "$(cat)" in
  "первый коммит: портабл YouTube Downloader с zapret") echo "Initial commit" ;;
  "убраны большие бинарники из репозитория, обновлен README") echo "Remove large binaries from repository" ;;
  *) cat ;;
esac
