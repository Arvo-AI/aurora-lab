#!/usr/bin/env bash
# Plain Docker: what ssh prints for each way a server can drop you. No cluster.
# The firewall rule runs in the server's own network namespace.
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"; R="$OUT/rst"; mkdir -p "$R"
docker build -q -t resetlab:24 "$C"
docker network create rstssh >/dev/null
docker run -d --name rst-sshd --network rstssh --cap-add NET_ADMIN --cap-add NET_RAW resetlab:24 sh -c \
  "sed -i 's/^root:[^:]*:/root:*:/' /etc/shadow; mkdir -p /root/.ssh; while [ ! -s /root/.ssh/authorized_keys ]; do sleep 1; done; ssh-keygen -A; exec /usr/sbin/sshd -D -e -p 2222 -o MaxStartups=1:100:1 -o PasswordAuthentication=no"
docker run -d --name rst-ssh --network rstssh --cap-add NET_ADMIN --cap-add NET_RAW resetlab:24 sleep infinity
docker exec rst-ssh ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
docker exec rst-ssh cat /root/.ssh/id_ed25519.pub | docker exec -i rst-sshd sh -c 'cat > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'
sleep 3
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' rst-sshd)
SSH="ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2222 root@$IP"
cap_on() { docker exec rst-ssh sh -c "tcpdump -l -nn -p -i eth0 -tttt -v 'tcp port 2222' > /tmp/cap.txt 2>/dev/null & echo \$! > /tmp/cap.pid; sleep 1"; }
cap_off() { sleep 1; docker exec rst-ssh sh -c 'kill $(cat /tmp/cap.pid); sleep 1; cat /tmp/cap.txt'; }
fw() { docker exec rst-sshd iptables "$@"; }
show() { grep -v -E '^debug1: (Reading|/etc|Connecting|Local version|compat|kex|SSH2|Host|expecting|Will|Server host|channel|load_hostkeys|identity|Authentic|Next|Offering|Trying|Sending|Entering|pledge|Remote: |rekey|Server accepts|Enabling|Skipping|client_input|receive packet|Requesting|Authenticated|No more|Transferred|Bytes|Exit)|^Warning: Permanently|^\*\*|^debug1: (OpenSSH|Connection established|Remote protocol)' || true; }
{
echo "# control"; echo "\$ ssh -p 2222 root@$IP true"; docker exec rst-ssh $SSH true 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
echo; echo "# firewall resets every non-SYN segment: reset right after the handshake"; cap_on
fw -I INPUT -p tcp --dport 2222 ! --syn -j REJECT --reject-with tcp-reset
echo "\$ iptables -I INPUT -p tcp --dport 2222 ! --syn -j REJECT --reject-with tcp-reset"
echo "\$ ssh -p 2222 root@$IP true"; docker exec rst-ssh $SSH true 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
fw -D INPUT -p tcp --dport 2222 ! --syn -j REJECT --reject-with tcp-reset
echo "--- client capture"; cap_off
echo; echo "# firewall resets the first segment carrying data"; cap_on
fw -I INPUT -p tcp --dport 2222 --tcp-flags PSH PSH -j REJECT --reject-with tcp-reset
echo "\$ iptables -I INPUT -p tcp --dport 2222 --tcp-flags PSH PSH -j REJECT --reject-with tcp-reset"
echo "\$ ssh -p 2222 root@$IP true"; docker exec rst-ssh $SSH true 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
fw -D INPUT -p tcp --dport 2222 --tcp-flags PSH PSH -j REJECT --reject-with tcp-reset
echo "--- client capture"; cap_off
echo; echo "# reset in the middle of a logged-in session"; cap_on
docker exec rst-ssh sh -c "$SSH -o ServerAliveInterval=2 'sleep 30' > /tmp/sess.txt 2>&1; echo exit=\$? >> /tmp/sess.txt" &
sleep 5
fw -I INPUT -p tcp --dport 2222 -j REJECT --reject-with tcp-reset
echo "\$ iptables -I INPUT -p tcp --dport 2222 -j REJECT --reject-with tcp-reset"
sleep 8
fw -D INPUT -p tcp --dport 2222 -j REJECT --reject-with tcp-reset
wait
docker exec rst-ssh cat /tmp/sess.txt | show
echo "--- client capture"; cap_off | tail -14
docker exec rst-ssh ssh -V 2>&1
} > "$R/11-ssh-docker.txt" 2>&1
docker rm -f rst-sshd rst-ssh >/dev/null; docker network rm rstssh >/dev/null
echo ssh repro done
