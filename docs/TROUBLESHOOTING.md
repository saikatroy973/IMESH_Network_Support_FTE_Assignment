# Troubleshooting Runbook — Deep Dive

This document expands on the investigation described in the top-level `README.md`.
It contains the layered methodology, the reasoning behind each command, and the
real captured output of every step.

Everything here is produced by `scripts/06-diagnose.sh`. The raw log is in
[`../artifacts/06-diagnose.log`](../artifacts/06-diagnose.log).

---

## The layered model

Kubernetes service networking is a pipeline. Each stage has exactly one job, and
each stage can be tested with one command. Troubleshooting is the process of
finding the first stage that misbehaves.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  L1  DNS          service name  ──►  ClusterIP                     │
  │      getent hosts / dig                                              │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L2  Service      ClusterIP:80     ──►  (selector, port/targetPort) │
  │      kubectl get svc / describe svc                                 │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L3  Endpoints    selector         ──►  podIP:port                  │
  │      kubectl get endpoints / endpointslices                         │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L4  Pod spec     containerPort    ──►  what the app should listen on
  │      kubectl describe pod                                           │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L5  App socket   process          ──►  what it ACTUALLY listens on│
  │      ss -lntp                                                        │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L6  Wire         packets          ──►  SYN / SYN-ACK / RST        │
  │      tcpdump                                                        │
  ├─────────────────────────────────────────────────────────────────────┤
  │  L7  kube-proxy   DNAT rules       ──►  ClusterIP → podIP:port     │
  │      iptables -t nat -S KUBE-SVC-…                                  │
  └─────────────────────────────────────────────────────────────────────┘
```

**Rule of thumb:** never jump down a layer until the current one is proven
healthy. Skipping layers is how people end up "fixing" a NetworkPolicy that
was never involved.

---

## Error-message cheat sheet

The exact error string narrows the search space dramatically.

| Error | Layer | Interpretation |
|---|---|---|
| `Could not resolve host: backend` | L1 | DNS. Wrong Service name, wrong namespace, CoreDNS down, missing `ndots`/search-domain issue. |
| `Connection refused` (exit code 7) | L5/L6 | The host answered with a RST. **The host is reachable; the port is closed.** Wrong `targetPort`, app not listening, app crashed. |
| `Operation timed out` (exit code 28) | L6 | Packets are being **dropped**. NetworkPolicy, security group, firewall, wrong route, conntrack table. |
| `No route to host` (exit code 7/113) | L6 | No L3 path. CNI not ready, node down, wrong subnet. |
| `Empty reply from server` | L5 | The connection was accepted and then closed — the app crashed mid-request or a proxy upstream failed. |
| `502 Bad Gateway` (from nginx) | proxy | The proxy itself worked; its **upstream** failed. Point the investigation at the upstream. |

In this incident the error was **`Connection refused`**, which immediately ruled
out NetworkPolicy and firewall-drop scenarios (those produce timeouts) and
pointed straight at "the port is closed on a reachable host".

---

## L0 — Reproduce the symptom

```bash
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -v http://backend.imesh-demo.svc.cluster.local/
```

```
* Host backend.imesh-demo.svc.cluster.local:80 was resolved.
* IPv4: 10.96.116.237
*   Trying 10.96.116.237:80...
* connect to 10.96.116.237 port 80 from 10.244.1.5 port 53878 failed: Connection refused
* Failed to connect to backend.imesh-demo.svc.cluster.local port 80 after 0 ms: Could not connect to server
curl: (7) Failed to connect to backend.imesh-demo.svc.cluster.local port 80 after 0 ms: Could not connect to server
```

Two facts extracted immediately:

* the name resolved → **DNS is not the problem**;
* the failure was an active rejection, not a timeout → **the packet was not dropped**.

Also note `client → frontend` still returned `FRONTEND-OK`, so the fault is
specific to the frontend→backend leg.

---

## L1 — DNS

```bash
kubectl -n imesh-demo exec deploy/frontend -- \
  getent hosts backend.imesh-demo.svc.cluster.local
kubectl -n imesh-demo exec deploy/client -- \
  dig +short backend.imesh-demo.svc.cluster.local
kubectl -n imesh-demo get svc backend -o wide
```

```
10.96.116.237       backend.imesh-demo.svc.cluster.local
10.96.116.237
backend   ClusterIP   10.96.116.237   <none>   80/TCP
```

**Verdict: healthy.** The FQDN resolves to the ClusterIP, and the ClusterIP in
the API matches the address curl dialled.

---

## L2 — Service

```bash
kubectl -n imesh-demo get svc backend -o yaml
kubectl -n imesh-demo describe svc backend
```

```
port=80  targetPort=9090  protocol=TCP  name=http
Selector:  {"app.kubernetes.io/name":"backend"}
TargetPort:  9090/TCP
```

**Note:** `TargetPort: 9090/TCP` in the `describe` output is the first red flag.

---

## L3 — Endpoints / EndpointSlice

```bash
kubectl -n imesh-demo get endpoints backend
kubectl -n imesh-demo get endpointslices -l kubernetes.io/service-name=backend -o yaml
```

```
backend   10.244.1.2:9090,10.244.1.3:9090
endpoints=10.244.1.3 10.244.1.2  ready=true true  ports=9090
```

**This is the trap.** The endpoints are present and `ready=true`, so the
checklist item "does the Service have endpoints?" passes. But look at the
**port**: `9090`. The EndpointSlice faithfully mirrors the Service's
`targetPort` — it is not independent evidence of health.

> Since Kubernetes v1.33 the `v1 Endpoints` API is deprecated; `EndpointSlice`
> (`discovery.k8s.io/v1`) is the source of truth. Both are shown here because
> `kubectl get endpoints` is still what most runbooks use.

---

## L4 — Pod spec

```bash
kubectl -n imesh-demo describe pod -l app.kubernetes.io/name=backend
kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].spec.containers[0].ports}'
```

```
name=http  containerPort=8080  protocol=TCP
```

**First red flag confirmed:** the Service says `9090`, the pod says `8080`.

---

## L5 — The application socket (authoritative)

```bash
kubectl -n imesh-demo exec deploy/backend -- ss -lntp
kubectl -n imesh-demo logs -l app.kubernetes.io/name=backend --tail=5 --prefix
```

```
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      511          0.0.0.0:8080      0.0.0.0:*  users:(("nginx",pid=1,fd=6))

```
[pod/backend-…-7vbxf/backend] 10.244.1.4 - - [21/Oct/2026:11:56:11 +0000] "GET / HTTP/1.1" 200 60 "-" "curl/8.14.1"
[pod/backend-…-scn8g/backend] 10.244.1.5 - - [21/Oct/2026:11:56:41 +0000] "GET / HTTP/1.0" 200 60 "-" "curl/8.14.1"
```
```

`ss -lntp` is the ground truth: the process is listening on **8080** and
nothing else. The access log proves it is genuinely serving HTTP there.

**Why the pod stayed `Ready`:** the readiness probe is
`httpGet: {path: /healthz, port: 8080}` — it validates the *container's* port.
A Service pointing at the wrong port is invisible to kubelet.

---

## L6 — Cross-check: bypass the Service

```bash
BACKEND_POD_IP=$(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].status.podIP}')

kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:8080/   # works
kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:9090/   # refused
kubectl -n imesh-demo exec deploy/frontend -- curl http://10.96.116.237:80/         # refused
```

```
a) frontend -> podIP:8080   -> BACKEND-OK  pod=backend-6d448c44cf-7vbxf  client=10.244.1.4
b) frontend -> podIP:9090   -> curl: (7) Failed to connect to 10.244.1.2 port 9090 … Connection refused
c) frontend -> ClusterIP:80 -> curl: (7) Failed to connect to 10.96.116.237 port 80 … Connection refused
```

**This is the decisive experiment.** It proves, in one shot:

* the pod network works (a) — CNI, routing and the pod's own firewall are fine;
* the application works (a) — it is serving traffic;
* the failure is reproduced only through the Service's port mapping (c);
* the Service's chosen destination port is closed (b).

If (a) had also failed, the fault would be below the Service (CNI / network).

---

## L7 — Packet capture

```bash
# start the capture on EVERY backend pod (kube-proxy load-balances 50/50)
for p in $(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
             -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n imesh-demo exec "$p" -- bash -c '
    (timeout 12 tcpdump -n -l -i any "tcp port 9090" > /tmp/td9090.out 2>&1 &);
    sleep 9; grep -E "IP |Flags" /tmp/td9090.out | head -6' &
done
sleep 3
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 4 -o /dev/null http://backend.imesh-demo.svc.cluster.local/
wait
```

```
12:02:00.780282 eth0  In  IP 10.244.1.5.50200 > 10.244.1.3.9090: Flags [S], seq 2171988689, win 65495, … length 0
12:02:00.780294 eth0  Out IP 10.244.1.3.9090 > 10.244.1.5.50200: Flags [R.], seq 0, ack 2171988690, win 0, length 0
```

The **SYN arrives at the backend pod on port 9090** — this is the DNAT destination, so the Service's
`targetPort` is confirmed on the wire. The pod answers with a **RST** — the kernel has no socket on 9090.

The contrast capture on the working port, same pod, same node:

```
12:02:08.212841 eth0  In  IP 10.244.1.1.35410 > 10.244.1.2.8080: Flags [S], seq 332816736, win 65495, … length 0
12:02:08.213705 eth0  Out IP 10.244.1.2.8080 > 10.244.1.1.35410: Flags [P.], … length 145: HTTP: HTTP/1.1 200 OK
```

The kubelet's own probe on **8080** completes a full three-way handshake and gets `200 OK`.

> Capturing inside the pod shows the *post-DNAT* destination. Capturing in the
> client pod shows the *pre-DNAT* ClusterIP. Capture in the **destination** pod
> when you want to prove where kube-proxy actually sent the traffic — and start
> the capture on **every** replica, because the Service load-balances between
> them and a single-pod capture will miss the traffic roughly half the time.

> Capturing inside the pod shows the *post-DNAT* destination. Capturing in the
> client pod shows the *pre-DNAT* ClusterIP. Capture in the **destination** pod
> when you want to prove where kube-proxy actually sent the traffic.

---

## L8 — kube-proxy's rules (node level)

```bash
docker exec imesh-worker iptables -t nat -S KUBE-SERVICES | grep 'imesh-demo/backend'
docker exec imesh-worker iptables -t nat -S KUBE-SVC-NU3EPORMY7BJPWSM
docker exec imesh-worker iptables -t nat -S KUBE-SEP-N5YRTSCBPFTO5KR7
```

```
-A KUBE-SVC-NU3EPORMY7BJPWSM ... --comment "imesh-demo/backend:http -> 10.244.1.3:9090" \
   -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-N5YRTSCBPFTO5KR7
-A KUBE-SVC-NU3EPORMY7BJPWSM ... --comment "imesh-demo/backend:http -> 10.244.1.2:9090" -j KUBE-SEP-W63RYVPXPK4XVHZR

-A KUBE-SEP-N5YRTSCBPFTO5KR7 -p tcp ... -j DNAT --to-destination 10.244.1.3:9090
```

For contrast, the **healthy** frontend Service on the same node:

```
-A KUBE-SEP-U3WM7YOQV2E4SOX2 -p tcp ... -j DNAT --to-destination 10.244.1.5:8080
```

**The DNAT rule literally contains the wrong port.** This is the most
authoritative statement of the root cause available, because it is what the
dataplane actually executes.

Reading the rule structure:

* `KUBE-SERVICES` — one entry per Service ClusterIP.
* `KUBE-SVC-…` — per-Service chain, holds the load-balancing decisions
  (`--mode random --probability 0.5` = 50 % of traffic to each of the two
  backend replicas).
* `KUBE-SEP-…` — per-endpoint chain, holds the actual `DNAT --to-destination`.
* `KUBE-MARK-MASQ` — marks the packet so the reply is source-NAT'd back to the
  ClusterIP (why the client sees `10.96.116.237` as the peer, not the pod IP).

---

## L9 — Identify

```bash
kubectl -n imesh-demo get svc backend \
  -o jsonpath='{.spec.ports[0].targetPort}'                       # 9090
kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].spec.containers[0].ports[0].containerPort}'  # 8080
```

```
Service backend .spec.ports[0].targetPort  = 9090
backend container .ports[0].containerPort   = 8080
MISMATCH -> kube-proxy sends traffic to podIP:9090 but nginx listens on :8080
```

**Root cause:** the `backend` Service's `targetPort` (9090) does not match the
port the backend container listens on (8080). kube-proxy therefore DNATs
ClusterIP:80 to a closed port and every connection is rejected with a TCP RST.
The pod, the application and DNS are all healthy — only the Service→pod port
mapping is wrong.

---

## Appendix — the same scenario with a different tool

Everything above used `curl` + `ss` + `tcpdump` because they are always
present. If you have `kubectl debug` (node) available, the same investigation
can be done from an ephemeral container:

```bash
kubectl -n imesh-demo debug deploy/frontend -it --image=nicolaka/netshoot -- \
  bash -c 'ss -lntp; dig +short backend.imesh-demo.svc.cluster.local; \
            curl -v http://backend.imesh-demo.svc.cluster.local/'
```

`nicolaka/netshoot` bundles `ss`, `dig`, `nslookup`, `curl`, `netcat`,
`tcpdump`, `traceroute`, `mtr` and `iperf3` in one image.

---

## Appendix — Service `targetPort` reference

| Form | Example | Resolves to | Behaviour when the pod changes port |
|---|---|---|---|
| numeric | `targetPort: 8080` | the literal number | **breaks silently** if the app moves |
| named | `targetPort: http` | the pod's `ports[].name: http` → its `containerPort` | breaks loudly at apply time (no matching endpoint) |
| omitted | (unset) | equals `port` | same as numeric, defaults to `port` |

The named form is the more robust choice: the pod spec becomes the single
source of truth, and a mismatch surfaces as an **empty EndpointSlice** (a
visible, obvious failure) instead of a silent port redirect.
