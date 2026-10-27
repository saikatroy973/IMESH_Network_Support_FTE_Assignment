# Kubernetes Network Troubleshooting — Support Engineer Assignment

**Repository:** `IMESH` — Network Support Engineer assignment
**Environment:** local Kubernetes cluster created with **kind v0.33.0** (Kubernetes **v1.37.0**, Docker Desktop 29.6.2, macOS / arm64)
**CNI:** kindnetd (the kind default)

---

## 1. What this repository contains

A complete, reproducible reproduction of a Kubernetes networking incident, together with the
troubleshooting runbook that finds the root cause and the fix that resolves it.

| Path | Purpose |
|---|---|
| `README.md` | This write-up — symptom, investigation, observations, root cause, resolution, verification |
| `kind-config.yaml` | kind cluster topology (control-plane + worker) |
| `Dockerfile` | The single image used by all three workloads (nginx + curl + iproute2 + bind-tools + tcpdump) |
| `manifests/` | All Kubernetes YAML: namespace, the three workloads, the injected fault, the fix |
| `scripts/` | Every command used, in order, as runnable scripts |
| `docs/TROUBLESHOOTING.md` | The layered investigation methodology and the full command transcript |
| `docs/VIDEO_SCRIPT.md` | Script for the 5-minute screen recording |
| `artifacts/` | Real captured output from the run reproduced below |

### Application flow

```
      ┌──────────────┐    ClusterIP     ┌──────────────┐    ClusterIP     ┌──────────────┐
      │    client    │ ───────────────► │   frontend   │ ───────────────► │   backend    │
      │ (control-    │   frontend:80    │  (nginx:8080)│  backend:80     │ (nginx:8080) │
      │  plane node) │                  │  proxies     │                  │              │
      └──────────────┘                  │  /api/ ──────┼────────────────► │              │
                                        └──────────────┘                  └──────────────┘
```

* **backend** — nginx serving `BACKEND-OK`, listening on **:8080**. Service `backend` exposes port **80 → targetPort 8080**.
* **frontend** — nginx serving `FRONTEND-OK` on `/` and reverse-proxying `/api/` to the backend Service. Listens on **:8080**. Service `frontend` exposes port **80 → targetPort 8080**.
* **client** — a 10-second health loop that calls the frontend Service and the frontend's `/api/` route, logging both HTTP status codes.

The client is deliberately scheduled onto the **control-plane node** while frontend and backend run on the
**worker**, so `client → frontend` traffic crosses a real node boundary and is genuinely handled by
kube-proxy's ClusterIP rules rather than a single-node shortcut.

---

## 2. Reproducing everything

### Prerequisites

```bash
docker --version      # Docker Desktop, Docker daemon running
kind  --version
kubectl version --client
```

### One command

```bash
git clone <this-repo> && cd IMESH
./scripts/run-all.sh --recreate
```

`run-all.sh` executes the whole story in order and stores each step's output under `artifacts/`:

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/01-setup-cluster.sh` | Creates the kind cluster (`imesh`) |
| 2 | `scripts/02-build-image.sh` | Builds `imesh-demo-app:1.0.0` and `kind load`s it into every node |
| 3 | `scripts/03-deploy.sh` | Applies the manifests, waits for rollout + ready endpoints |
| 4 | `scripts/04-verify-baseline.sh` | **Proves `client → frontend` and `frontend → backend` both work** |
| 5 | `scripts/05-inject-fault.sh` | **Introduces the single networking fault** |
| 6 | `scripts/06-diagnose.sh` | **The troubleshooting runbook** (layers L0 → L9) |
| 7 | `scripts/07-fix.sh` | **Applies the fix** |
| 8 | `scripts/08-verify-fixed.sh` | **Verifies the flow is restored** |
| 9 | `scripts/09-capture-incident-timeline.sh` | Captures the before/during/after customer timeline |

### Step by step

```bash
./scripts/01-setup-cluster.sh
./scripts/02-build-image.sh
./scripts/03-deploy.sh
./scripts/04-verify-baseline.sh     # both legs OK
./scripts/05-inject-fault.sh        # break frontend -> backend
./scripts/06-diagnose.sh            # investigate
./scripts/07-fix.sh                 # resolve
./scripts/08-verify-fixed.sh        # confirm
./scripts/09-capture-incident-timeline.sh   # 200 -> 502 -> 200 from the client
```

Tear everything down with `./scripts/00-reset.sh`.

---

## 3. Symptom

**Ticket title:** *API calls through the frontend return 502 Bad Gateway*

After a configuration change, the `frontend → backend` leg of the application flow stopped working,
while `client → frontend` kept working.

Observed from the client workload (`kubectl -n imesh-demo logs deploy/client`):

```
[2026-10-27T18:26:41Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=200
[2026-10-27T18:27:21Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=502
[2026-10-27T18:27:31Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=502
```

The frontend is healthy and reachable. Every request the frontend makes **downstream to the backend**
fails.

From inside the frontend pod, the direct call to the backend Service fails at the TCP level:

```
$ kubectl -n imesh-demo exec deploy/frontend -- \
    curl -v http://backend.imesh-demo.svc.cluster.local/

* Host backend.imesh-demo.svc.cluster.local:80 was resolved.
* IPv4: 10.96.126.148
*   Trying 10.96.126.148:80...
* connect to 10.96.126.148 port 80 from 10.244.1.3 port 43898 failed: Connection refused
* Failed to connect to backend.imesh-demo.svc.cluster.local port 80 after 1 ms: Could not connect to server
curl: (7) Failed to connect to backend.imesh-demo.svc.cluster.local port 80 after 1 ms: Could not connect to server
```

Two details in that output are already valuable:

* **DNS worked** — the name resolved to the ClusterIP `10.96.126.148`. This is not a DNS incident.
* **`Connection refused`, not a timeout** — the TCP handshake was actively rejected with a RST.
  A *timeout* would have pointed at a dropped packet (NetworkPolicy, firewall, wrong route);
  a *refusal* means the host answered and said "no process is listening on that port".

---

## 4. Investigation

The investigation walked the network stack from the top down, one layer at a time, and only moved on
when the current layer was proven healthy. Every command below is executed by `scripts/06-diagnose.sh`
and the real output is in [`artifacts/06-diagnose.log`](artifacts/06-diagnose.log).

| Layer | Question | Command | Verdict |
|---|---|---|---|
| **L0** | What exactly fails? | `kubectl exec deploy/frontend -- curl -v http://backend…` | `Connection refused` on ClusterIP:80 |
| **L1** | Is it DNS? | `kubectl exec deploy/frontend -- getent hosts backend…`, `dig +short`, `nslookup` | resolves to ClusterIP `10.96.126.148` — **healthy** |
| **L1b** | Is a NetworkPolicy filtering it? | `kubectl get networkpolicy`, `kubectl get networkpolicy -A`, CNI check | no policies exist; kindnetd does not enforce them anyway — **ruled out** |
| **L2** | What does the Service map to? | `kubectl get svc backend -o yaml`, `kubectl describe svc backend` | `port=80 targetPort=9090` |
| **L3** | Which pods back it, on which port? | `kubectl get endpoints backend`, `kubectl get endpointslices -l kubernetes.io/service-name=backend` | endpoints **exist**: `10.244.1.2:9090`, `10.244.1.5:9090` |
| **L4** | What port does the container declare? | `kubectl describe pod -l app.kubernetes.io/name=backend` | `containerPort: 8080` |
| **L5** | Is the app alive and where does it listen? | `kubectl exec deploy/backend -- ss -lntp` | `LISTEN 0.0.0.0:8080 users:(("nginx",pid=1,fd=6))` — **healthy** |
| **L6** | Bypass the Service entirely | `ping <podIP>`, `curl http://10.244.1.5:8080/` | ICMP 0 % loss, `BACKEND-OK` — **works** |
| **L7** | What is actually on the wire? | `kubectl exec deploy/backend -- tcpdump -i any` | SYN to **`10.244.1.5:9090`** → **RST** |
| **L8** | What does kube-proxy think? | `docker exec imesh-worker iptables -t nat -S KUBE-SVC-…` | `DNAT --to-destination 10.244.1.5:9090` |
| **L9** | Do the declared and actual ports agree? | `jsonpath` comparison of `targetPort` vs `containerPort` | `9090 ≠ 8080` → **MISMATCH** |

### The commands that mattered

```bash
# 1. Reproduce
kubectl -n imesh-demo exec deploy/frontend -- curl -v http://backend.imesh-demo.svc.cluster.local/

# 2. Is DNS involved?
kubectl -n imesh-demo exec deploy/frontend -- getent hosts backend.imesh-demo.svc.cluster.local
kubectl -n imesh-demo exec deploy/client    -- dig +short backend.imesh-demo.svc.cluster.local
kubectl -n imesh-demo exec deploy/client    -- nslookup backend.imesh-demo.svc.cluster.local

# 3. Is anything filtering the traffic?
kubectl -n imesh-demo get networkpolicy
kubectl -n imesh-demo get networkpolicy -A
kubectl -n kube-system get pods | grep -E 'kindnet|calico|cilium'

# 4. What does the Service say?
kubectl -n imesh-demo get svc backend -o yaml
kubectl -n imesh-demo describe svc backend

# 5. Which pods, which port?
kubectl -n imesh-demo get endpoints backend
kubectl -n imesh-demo get endpointslices -l kubernetes.io/service-name=backend -o yaml

# 6. What does the pod declare?
kubectl -n imesh-demo describe pod -l app.kubernetes.io/name=backend

# 7. What is the process really listening on?  (the authoritative answer)
kubectl -n imesh-demo exec deploy/backend -- ss -lntp

# 8. Bypass the Service - proves the app and the pod network are fine
kubectl -n imesh-demo exec deploy/frontend -- ping -c 2 10.244.1.5
kubectl -n imesh-demo exec deploy/frontend -- curl http://10.244.1.5:8080/

# 9. Packet capture
kubectl -n imesh-demo exec deploy/backend -- tcpdump -n -i any 'tcp port 8080 or tcp port 9090'

# 10. kube-proxy's view (node level)
docker exec imesh-worker iptables -t nat -S KUBE-SERVICES | grep 'imesh-demo/backend'
docker exec imesh-worker iptables -t nat -S KUBE-SEP-KWKLRVL7J2CICKIV
```

---

## 5. Observations

**1. DNS and CoreDNS were never involved.**
`getent hosts`, `dig +short` and `nslookup` all returned the ClusterIP `10.96.126.148`, and
`kubectl get svc` showed the ClusterIP unchanged. The name→address step worked perfectly.
`kubectl get networkpolicy -A` returned nothing, and kind's default CNI does not enforce
NetworkPolicy anyway — so packet filtering was ruled out explicitly, not just assumed away.

**2. The Service *did* have endpoints — this was the trap.**
The instinctive first hypothesis ("the Service has no endpoints") was **wrong**:

```
$ kubectl get endpoints backend
backend   10.244.1.2:9090,10.244.1.5:9090
```

Both backend pods were `Ready`, and the Service selector matched their labels. A responder who stops
here ("endpoints exist, DNS works, so the Service is fine") would be stuck. The *port* in the endpoint
list is the thing to read: **9090**.

**3. The endpoint port disagreed with the container port.**

```
Service backend .spec.ports[0].targetPort  = 9090
backend container .ports[0].containerPort  = 8080
```

**4. The application itself was completely healthy.**
`ss -lntp` inside the backend pod showed exactly one listening socket, on the correct port:

```
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      511          0.0.0.0:8080      0.0.0.0:*    users:(("nginx",pid=1,fd=6))
```

The nginx access log also shows it happily serving requests on **8080** — including the kubelet's own
`/healthz` probe — so the readiness probe was correctly validating the right port. That is why the pods
stayed `Ready` and the rollout looked green: **the probe tested the container port, while the Service
pointed somewhere else.**

**5. Reaching the pod IP directly bypassed the fault.**

```
frontend -> podIP (ICMP) -> 0% packet loss                (reachable)
frontend -> podIP:8080   -> BACKEND-OK                     (works)
frontend -> podIP:9090   -> Connection refused             (fails)
frontend -> ClusterIP:80 -> Connection refused             (fails - the reported symptom)
```

This isolates the fault to the **Service → pod port mapping** and exonerates the pod network, the CNI,
the node and the application.

**6. The packet capture showed the DNAT destination and the rejection.**

```
# (a) traffic on port 9090 - the port the Service points at
18:26:00.035147 eth0  In  IP 10.244.1.3.39602 > 10.244.1.2.9090: Flags [S], ... length 0
18:26:00.035152 eth0  Out IP 10.244.1.2.9090 > 10.244.1.3.39602: Flags [R.], ... length 0

# (b) traffic on port 8080 - the port the app really listens on
18:26:14.686847 eth0  Out IP 10.244.1.2.8080 > 10.244.1.1.48986: Flags [P.], ... length 145: HTTP: HTTP/1.1 200 OK
```

The SYN arrives at the backend pod on **port 9090** and is answered with a **RST**, because nothing is
listening there. On the very same pod, the kubelet's own health probe on **8080** completes a full
three-way handshake and gets `200 OK`. Port 8080 → handshake and `200 OK`. Port 9090 → RST.
Same pod, same node, seconds apart.

> Both backend replicas show the same pattern — the Service is misrouting traffic to a closed port on
> *every* endpoint, which is why the fault is total rather than intermittent.

**7. kube-proxy's rules confirmed the mapping.**

```
-A KUBE-SVC-NU3EPORMY7BJPWSM ... --comment "imesh-demo/backend:http -> 10.244.1.2:9090" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-W63RYVPXPK4XVHZR
-A KUBE-SVC-NU3EPORMY7BJPWSM ... --comment "imesh-demo/backend:http -> 10.244.1.5:9090" -j KUBE-SEP-KWKLRVL7J2CICKIV

-A KUBE-SEP-KWKLRVL7J2CICKIV -p tcp ... -j DNAT --to-destination 10.244.1.5:9090
```

versus the healthy frontend Service on the same node:

```
-A KUBE-SEP-XOAH7QOUDJ4CCN77 -p tcp ... -j DNAT --to-destination 10.244.1.3:8080
```

**8. Why the pods never restarted.**
The Deployment's readiness/liveness probes use `containerPort: 8080`. Because the application was
listening on 8080 exactly as declared, the probes kept passing, the pods stayed `Ready`, and the
scheduler/endpoint controller kept them in the EndpointSlice. A fault in the *Service* is invisible to
kubelet — only the Service's `targetPort` had drifted.

---

## 6. Root cause

> **The `backend` Service's `targetPort` was set to `9090`, but the backend container listens on `8080`.**

```diff
  ports:
    - name: http
      port: 80
-     targetPort: 8080
+     targetPort: 9090
      protocol: TCP
```

**Mechanism.** kube-proxy programs a DNAT rule for every Service endpoint, derived from
`Service.spec.ports[].targetPort`. With `targetPort: 9090` the rule became
`DNAT --to-destination <backend-pod-IP>:9090`. The client connects to `backend:80` →
ClusterIP `10.96.126.148:80` → DNAT → `10.244.1.5:9090` → **nothing listening → TCP RST** →
`Connection refused`.

**Why the topology hid it.** The failure looked like "the backend is down", but the backend was the
healthiest workload in the cluster:

* the pods stayed `Running` and `Ready` (probes hit 8080, which was correct);
* the EndpointSlice kept both pods (they matched the selector);
* the EndpointSlice advertised port **9090**, so `kubectl get endpoints` looked healthy at a glance;
* only a reader who compares the *Service* port against the *container* port notices the drift.

**Why "Connection refused" was the decisive clue.** The error message narrows the fault to a small set
of possibilities:

| Symptom | Most likely cause |
|---|---|
| `Could not resolve host` | DNS / wrong Service name / missing namespace |
| `Connection refused` | Host reachable, **port closed** (wrong `targetPort`, app not listening) |
| Timeout / no route to host | Packet dropped — NetworkPolicy, firewall, wrong route, wrong node |

The cluster returned `Connection refused`, which is precisely the signature of a Service pointing at a
port where nothing is listening. A NetworkPolicy would have produced a **timeout** instead — and
kindnetd, the kind default CNI, does not enforce NetworkPolicy at all, so a policy could not have
produced this symptom in this environment.

**How this would happen in production.** A perfectly ordinary sequence: the backend application was
reconfigured to listen on a new port, the Service was never updated (or a Helm/GitOps template was
changed on one side only), or a `kubectl patch`/`kubectl edit` during a previous incident was never
reverted. The drift sits in the Service object while the workload looks perfectly healthy.

---

## 7. Resolution

**Fix:** point the Service's `targetPort` back at the port the container actually listens on.

### Declarative (preferred — the manifest is the source of truth)

```yaml
# manifests/90-fix-targetport.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: imesh-demo
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: backend
  ports:
    - name: http
      port: 80
      targetPort: 8080      # <-- matches containerPort / the nginx listen port
      protocol: TCP
```

```bash
kubectl -n imesh-demo apply -f manifests/90-fix-targetport.yaml
```

### Imperative (what you would type during a live incident)

```bash
kubectl -n imesh-demo patch svc backend --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
```

### Why nothing was restarted

No pod was deleted, restarted or recreated — the `targetPort` change is picked up by the endpoint
controller and kube-proxy within a second, and the pods' uptime proves it:

```
$ kubectl -n imesh-demo get pods -l app.kubernetes.io/name=backend
backend-6d448c44cf-pt7pb   1/1   Running   0     69s
backend-6d448c44cf-tshwt   1/1   Running   0     69s
```

### Prevention (beyond the fix)

* Reference the port **by name** instead of by number, so the pod spec is the single source of truth:
  `targetPort: http` next to `ports: [{name: http, containerPort: 8080}]`. A port rename then breaks
  loudly at apply time instead of silently at runtime.
* Add a CI check that diffs every Service `targetPort` against the matching `containerPort`.
* Alert on `kube_service_status_load_balancer_*`-style signals for the ClusterIP, and on a rise in
  frontend 5xx rates — the `frontend → backend` 502 was visible from the client side within one
  10-second window.

---

## 8. Verification

`scripts/08-verify-fixed.sh` re-runs every assertion. Real output
([`artifacts/08-verify-fixed.log`](artifacts/08-verify-fixed.log)):

```
    backend   ClusterIP   10.96.126.148   <none>   80/TCP   93s
    backend   10.244.1.2:8080,10.244.1.5:8080   93s

    kube-proxy DNAT rules after the fix (the destination port is now 8080):
      -A KUBE-SEP-FTK6SABNPP4IODE2 -p tcp ... -j DNAT --to-destination 10.244.1.2:8080
      -A KUBE-SEP-UKD725XHCBHY6O3T -p tcp ... -j DNAT --to-destination 10.244.1.5:8080

    OK   client -> frontend            : PASS  (FRONTEND-OK  pod=frontend-64bbfbffdf-6s2lj  client=10.244.0.5)
    OK   frontend -> backend           : PASS  (BACKEND-OK  pod=backend-6d448c44cf-pt7pb  client=10.244.1.3)
    OK   client -> frontend -> backend  : PASS  (BACKEND-OK  pod=backend-6d448c44cf-pt7pb  client=10.244.1.4)
    OK   backend own port 8080        : PASS  (app is alive and serving)
    OK   frontend own port 8080        : PASS  (app is alive and serving)
    OK   RESOLVED - the full flow client -> frontend -> backend works again
```

Six independent checks all pass:

| # | Check | Command | Result |
|---|---|---|---|
| 1 | `client → frontend` | `kubectl exec deploy/client -- curl http://frontend…` | `FRONTEND-OK` |
| 2 | `frontend → backend` | `kubectl exec deploy/frontend -- curl http://backend…` | `BACKEND-OK` |
| 3 | end-to-end through the proxy | `kubectl exec deploy/client -- curl http://frontend…/api/` | `BACKEND-OK` |
| 4 | application locally healthy | `kubectl exec deploy/backend -- curl http://127.0.0.1:8080/` | `BACKEND-OK` |
| 5 | endpoint port corrected | `kubectl get endpoints backend` | `10.244.1.2:8080,10.244.1.5:8080` |
| 6 | kube-proxy DNAT corrected | `iptables -t nat -S KUBE-SEP-…` | `DNAT --to-destination 10.244.1.2:8080` |

> Pod names, pod IPs and ClusterIPs differ on every cluster creation — the values above are from the
> run stored in `artifacts/`. The *shape* of the output is what matters, not the specific addresses.

### The customer timeline ([`artifacts/incident-timeline.txt`](artifacts/incident-timeline.txt))

```
### 1. HEALTHY
[18:26:41Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200

### 2. FAULT INJECTED   backend Service targetPort : 8080 -> 9090
[18:27:11Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200
[18:27:21Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=502
[18:27:31Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=502

### 3. ROOT CAUSE FIXED  backend Service targetPort : 9090 -> 8080
[18:27:51Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200
[18:28:01Z] client -> frontend  http_code=200  |  client -> frontend(/api/) -> backend  http_code=200
```

The customer's symptom disappears the moment the `targetPort` is corrected.

---

## 9. Methodology — Observe → Investigate → Identify → Fix → Verify

**Observe.** Start from the user's symptom, not from the cluster objects. Capture the exact error
text — `Connection refused` versus `timeout` versus `could not resolve` immediately narrows the search
space. Write down what is *still* working (`client → frontend` = 200); a half-broken flow is a very
useful clue.

**Investigate.** Walk the stack top-down and prove each layer before moving on:
DNS → Service → Endpoints/EndpointSlice → Pod spec → application socket → packet capture → node-level
kube-proxy rules. Each layer has a specific command, and each answer eliminates a class of causes.

**Identify.** Name the root cause as a *configuration fact*, not a suspicion:
"Service `backend` has `targetPort: 9090`; the container listens on `8080`". A good root cause is
something you can state as a diff.

**Fix.** Change the one thing that is wrong. Apply the declarative source of truth rather than a live
edit, so the fix survives the next `kubectl apply` / GitOps sync.

**Verify.** Re-run the *same* assertions that proved the failure, plus at least one independent check.
Verify the symptom is gone from the customer's point of view, not just that the object looks right.

### The anti-patterns this exercise deliberately exposes

| Tempting shortcut | Why it is wrong |
|---|---|
| `kubectl delete pod backend-xxx` | The pod is healthy. Restarting it changes nothing and destroys evidence. |
| "The Service has no endpoints" | It *does* have endpoints — the endpoint **port** is wrong. |
| "The pod is `Ready`, so it must be serving traffic" | Readiness proves the *container port*, not the *Service port*. |
| "Add a NetworkPolicy / restart / recreate" | Symptom-chasing instead of root-causing. A policy cannot produce `Connection refused`. |

---

## 10. Notes and limitations

* **The fault is a Service-level fault, not a pod-level one.** The assignment explicitly asks that the
  issue be networking-related and that pods not simply be stopped or deleted — the pods here never
  restart across the entire incident.
* **kindnetd does not enforce NetworkPolicy.** A `NetworkPolicy` would have been silently ignored in
  this cluster, which is itself a useful lesson: when a policy appears to have no effect, check the CNI
  before assuming the policy is correct. A policy-capable CNI (Calico / Cilium) would be required to
  demonstrate the NetworkPolicy variant of the scenario.
* **Scope.** Exactly one networking fault is introduced, as required. `scripts/06-diagnose.sh` prints
  the healthy frontend Service's kube-proxy rules next to the broken backend Service's rules purely as
  a contrast — it does not introduce a second fault.
* **The scripts are idempotent.** `run-all.sh --recreate` rebuilds the whole environment from scratch,
  which is what was used to produce every artifact in `artifacts/`.

---

## 11. Submission checklist

- [x] Kubernetes cluster created (kind, 2 nodes)
- [x] `client`, `frontend`, `backend` workloads + Services deployed
- [x] Baseline verified: `client → frontend` OK, `frontend → backend` OK
- [x] **One** intentional networking fault introduced (`targetPort` drift)
- [x] No pod stopped or deleted to create the fault
- [x] Troubleshooting documented with the exact commands used
- [x] Root cause identified and explained
- [x] Fix applied declaratively (`manifests/90-fix-targetport.yaml`)
- [x] Resolution verified with six independent checks
- [x] `README.md` + `manifests/` + `scripts/` in the repository
- [x] 5-minute video script in `docs/VIDEO_SCRIPT.md`
