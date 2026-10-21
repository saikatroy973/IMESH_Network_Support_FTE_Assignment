# 5-Minute Screen Recording Script

**Title:** Kubernetes Network Troubleshooting — `frontend → backend` failure
**Length:** 5 minutes
**Format:** screen recording, voice-over narration
**Tooling:** any screen recorder (OBS, QuickTime, Loom). Terminal font at a
readable size, `kubectl` + `bash scripts/…` on screen.

---

## Pre-recording checklist

```bash
docker info                        # Docker daemon must be running
kind version && kubectl version --client

cd IMESH
./scripts/00-reset.sh              # clean slate
./scripts/run-all.sh --recreate   # pre-build everything so the recording is smooth
```

Open three tabs before you start recording:

1. **Tab A** — the main terminal (all commands from the script below).
2. **Tab B** — `kubectl -n imesh-demo logs -f deploy/client` (the customer's view).
3. **Tab C** — a text editor with this README open (for the closing summary).

Keep the terminal wide (>= 100 columns) so nothing wraps.

---

## Timeline

### 0:00 – 0:35 · Environment (35 s)

**On screen:**

```bash
kind get clusters
kubectl get nodes -o wide
kubectl -n imesh-demo get pods -o wide
kubectl -n imesh-demo get svc
```

**Narration:**

> "This is my local Kubernetes cluster. It's a two-node kind cluster: a
> control-plane node and a worker. The three workloads are `client`,
> `frontend` and `backend`. The client is pinned to the control-plane node on
> purpose, so the client-to-frontend traffic crosses a real node boundary and
> is handled by kube-proxy's ClusterIP rules rather than some single-node
> shortcut.
>
> The frontend is an nginx that serves its own page on `/` and reverse-proxies
> `/api/` to the backend Service. The backend is an nginx that listens on
> port 8080."

**On screen:**

```bash
kubectl -n imesh-demo get deploy,svc,endpoints
```

> "Backend has two replicas. The Service exposes port 80 and forwards to
> targetPort 8080, which is the port the container actually listens on. Same
> for the frontend."

---

### 0:35 – 1:05 · Healthy baseline (30 s)

**On screen:**

```bash
./scripts/04-verify-baseline.sh
```

**Narration:**

> "First, a baseline. Both legs of the flow work: client to frontend, and
> frontend to backend. I'll also check the end-to-end path through the
> frontend's proxy. Everything is green."

**On screen (Tab B):**

```
[12:01:54Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200
```

> "And here's the client workload polling every ten seconds. Both checks are
> 200. That's our healthy state."

---

### 1:05 – 1:30 · Injecting the fault (25 s)

**On screen:**

```bash
./scripts/05-inject-fault.sh
```

**Narration:**

> "Now I introduce one networking fault. The backend Service's `targetPort`
> changes from 8080 to 9090. The container still listens on 8080 — I'm not
> touching the pods at all. Notice the pod uptime doesn't change: no pod is
> stopped or deleted. This is exactly the kind of drift you get when the
> application is reconfigured to a new port and the Service is never updated."

**On screen (Tab B):**

```
[12:02:04Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=502
```

> "Within ten seconds the customer sees it: the frontend itself is still
> healthy — 200 — but every API call it makes downstream returns 502."

---

### 1:30 – 2:15 · The symptom (45 s)

**On screen:**

```bash
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -v http://backend.imesh-demo.svc.cluster.local/
```

**Narration:**

> "Let's start the investigation from the symptom, exactly as a support
> engineer would on a real ticket.
>
> Two things jump out of this output immediately. First: the hostname
> *resolved* — we got an IPv4 address, so DNS and CoreDNS are working. Second:
> the error is **Connection refused**, not a timeout.
>
> That distinction matters a lot. A timeout means packets are being dropped —
> think NetworkPolicy, firewall, a routing problem. A refusal means the host
> answered and said 'there's no process listening on that port'. That points
> at a port mapping problem, not a connectivity problem."

---

### 2:15 – 3:10 · Layered investigation (55 s)

**On screen:**

```bash
./scripts/06-diagnose.sh
```

**Narration** (follow the output as it scrolls):

> "Now I walk the stack layer by layer, and I don't skip ahead.
>
> **Layer 1, DNS.** `getent` and `dig` both return the ClusterIP. DNS is
> healthy.
>
> **Layer 2, the Service.** `describe svc backend` shows `TargetPort: 9090`.
> First red flag.
>
> **Layer 3, the endpoints.** And here's the trap. The endpoints exist — two
> of them, both `ready=true`. So the obvious check 'does the Service have
> endpoints?' passes. But read the *port*: `9090`. The EndpointSlice mirrors
> the Service's targetPort, it's not independent evidence of health.
>
> **Layer 4, the pod spec.** The container declares `containerPort: 8080`.
>
> **Layer 5, the application.** `ss -lntp` inside the backend pod is the
> authoritative answer — nginx is listening on 8080 and nothing else. The
> access log confirms it's genuinely serving HTTP there.
>
> And notice why the pod never restarted: the readiness probe hits port 8080,
> which is correct, so the probes keep passing and the pod stays Ready. A
> Service-level fault is completely invisible to kubelet."

---

### 3:10 – 3:50 · Proof (40 s)

**On screen:**

```bash
BACKEND_POD_IP=$(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].status.podIP}')

kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:8080/   # works
kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:9090/   # refused
```

**Narration:**

> "This is the decisive experiment. I bypass the Service entirely and talk to
> the pod IP directly.
>
> Port 8080 — works. The app is healthy and the pod network is fine.
> Port 9090 — refused. That's the port the Service is pointing at.
>
> So the fault is isolated to the Service-to-pod port mapping. The CNI, the
> node, the pod and the application are all exonerated."

**On screen:**

```bash
# capture on EVERY backend pod - the Service load-balances 50/50 between them
for p in $(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
             -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n imesh-demo exec "$p" -- bash -c \
    '(timeout 12 tcpdump -n -l -i any "tcp port 9090" > /tmp/t.out 2>&1 &);
     sleep 9; grep -E "IP |Flags" /tmp/t.out | head -4' &
done
sleep 3
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS -o /dev/null http://backend.imesh-demo.svc.cluster.local/
wait
```

**Narration:**

> "The packet capture confirms it on the wire. The SYN arrives at the backend
> pod on **port 9090** and gets a **RST** — nothing is listening there.
> Seconds later, on the same pod, the kubelet's own health probe on **8080**
> completes a full handshake and gets 200 OK.
>
> And finally, at the node level, kube-proxy's own rules state the root cause
> literally: `DNAT --to-destination 10.244.1.3:9090`. Compare with the
> healthy frontend service on the same node, which DNATs to port 8080."

**On screen:**

```bash
docker exec imesh-worker iptables -t nat -S KUBE-SVC-NU3EPORMY7BJPWSM
```

---

### 3:50 – 4:30 · Root cause and fix (40 s)

**On screen:**

```bash
kubectl -n imesh-demo get svc backend -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].spec.containers[0].ports[0].containerPort}{"\n"}'
```

**Narration:**

> "Root cause stated as a diff: the backend Service's `targetPort` is 9090,
> but the container listens on 8080. kube-proxy therefore DNATs ClusterIP:80
> to a closed port, and every connection is rejected with a TCP RST.
>
> The fix is one line — point the Service back at the port the container
> actually listens on. I'll apply the corrected manifest, because that's what
> survives the next `kubectl apply` or GitOps sync."

**On screen:**

```bash
./scripts/07-fix.sh
```

> "Note: no pod was restarted. The pod uptime is unchanged. The endpoint
> controller and kube-proxy pick up the new targetPort within a second."

---

### 4:30 – 5:00 · Verification and close (30 s)

**On screen:**

```bash
./scripts/08-verify-fixed.sh
```

**Narration:**

> "Verification. I re-run the same assertions that proved the failure, plus
> three more: client to frontend, frontend to backend, the end-to-end path
> through the proxy, the application's own port, and the endpoint list. All
> five pass."

**On screen (Tab B):**

```
[12:03:04Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200
```

> "And from the customer's point of view, the 502s are gone.
>
> To summarise: the symptom was a frontend-to-backend failure returning
> Connection refused. The investigation went DNS, Service, Endpoints, Pod
> spec, application socket, packet capture, kube-proxy rules. The root cause
> was a Service targetPort that no longer matched the container's listening
> port. The fix was to correct that one field. Everything's in the repo —
> the manifests, the scripts, and the full write-up in the README."

---

## Cut / jump-list

If you are running long, these are the safe cuts:

| Cut | Saving | Notes |
|---|---|---|
| Skip the `kubectl get deploy,svc,endpoints` walkthrough | ~15 s | Already covered by the topology narration |
| Skip the `tcpdump` block | ~25 s | Keep the `ss -lntp` + direct-pod-IP cross-check — those carry the argument |
| Skip the live `iptables` block | ~15 s | The `06-diagnose.sh` output already shows the DNAT rule |
| Trim the baseline section | ~15 s | Keep at least one PASS line |

**Do not cut:** the symptom (`Connection refused` vs timeout), the endpoints
trap, the `ss -lntp` output, and the direct-pod-IP cross-check. Those four
carry the whole investigation.

---

## Quick reference — every command in the video

```bash
# environment
kind get clusters
kubectl get nodes -o wide
kubectl -n imesh-demo get pods -o wide
kubectl -n imesh-demo get svc
kubectl -n imesh-demo get deploy,svc,endpoints

# baseline
./scripts/04-verify-baseline.sh

# fault
./scripts/05-inject-fault.sh

# symptom
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -v http://backend.imesh-demo.svc.cluster.local/

# investigation
./scripts/06-diagnose.sh

# proof
BACKEND_POD_IP=$(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].status.podIP}')
kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:8080/
kubectl -n imesh-demo exec deploy/frontend -- curl http://$BACKEND_POD_IP:9090/
docker exec imesh-worker iptables -t nat -S KUBE-SVC-NU3EPORMY7BJPWSM

# fix
./scripts/07-fix.sh

# verification
./scripts/08-verify-fixed.sh
```
