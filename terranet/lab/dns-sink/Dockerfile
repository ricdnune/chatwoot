FROM alpine:3.21
RUN apk add --no-cache dnsmasq
COPY dnsmasq.conf /etc/dnsmasq.conf
EXPOSE 53/udp 53/tcp
# -k: foreground, log to stderr so `docker logs` is the DNS audit trail (names only, no payloads)
CMD ["dnsmasq", "-k", "--log-facility=-"]
