cd -- "$(dirname -- "$0")" && docker compose up -d --build && sleep 5 && docker compose logs -f video-encode
