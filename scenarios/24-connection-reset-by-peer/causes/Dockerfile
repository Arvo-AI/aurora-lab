FROM golang:1.25-alpine AS build
WORKDIR /src
COPY server.go client.go ./
RUN CGO_ENABLED=0 go build -o /rstserver server.go && CGO_ENABLED=0 go build -o /rstclient client.go && go version > /goversion
FROM alpine:3.22
RUN apk add --no-cache tcpdump curl python3 py3-requests nodejs openssh-server openssh-client netcat-openbsd iproute2 ip6tables iptables
COPY --from=build /rstserver /rstclient /goversion /app/
COPY single.py py_client.py py_sweep.py raw_idle.py node_client.js /app/
