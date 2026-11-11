#!/bin/bash
# Полная проверка веб-клиента: HTTP-раздача + WebSocket-протокол.
cd "$(dirname "$0")"
pkill -9 -f mock_host 2>/dev/null
sleep 1

python3 mock_host.py > run.log 2>&1 &
SRV=$!
sleep 5

{
echo "=== HTTP-РАЗДАЧА ==="
for p in "/?g=482913" "/style.css" "/app.js" "/cards/mafia.jpg" "/sounds/kill.ogg" "/nope"; do
  printf "%-24s " "$p"
  curl -s -o /dev/null -w "%{http_code}  %{content_type}  %{size_download}b\n" "http://127.0.0.1:8090$p"
done

echo
echo "=== КОД ПОДСТАВЛЕН В HTML ==="
curl -s "http://127.0.0.1:8090/" | grep -o "__MAFIA__={[^}]*}"

echo
echo "=== WEBSOCKET-ПРОТОКОЛ ==="
python3 ws_client.py
} > result.txt 2>&1

kill $SRV 2>/dev/null
wait $SRV 2>/dev/null
cat result.txt
