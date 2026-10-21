# Single image used by all three workloads (client / frontend / backend).
#
# It is intentionally tiny (Alpine base) but carries everything a support engineer
# needs once inside a pod:
#
#   nginx       - the "application" HTTP server used by frontend and backend
#   curl        - HTTP client used for the connectivity tests
#   iproute2    - provides `ss`, the tool used to prove which port the app listens on
#   bind-tools  - provides `dig` (DNS troubleshooting)
#   tcpdump     - packet capture, used to show the ClusterIP DNAT happening
#
# Because the tooling ships in the *application* image, every command quoted in the
# README can be reproduced with a plain `kubectl exec` - no debug sidecar needed.
FROM alpine:3.20

RUN apk add --no-cache \
        nginx \
        curl \
        iproute2 \
        bind-tools \
        tcpdump \
        bash \
    && mkdir -p /var/log/nginx /var/lib/nginx/tmp /run/nginx \
    && rm -f /etc/nginx/http.d/default.conf

EXPOSE 8080

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
