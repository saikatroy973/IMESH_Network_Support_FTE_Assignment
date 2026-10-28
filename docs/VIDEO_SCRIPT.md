# 5-Minute Screen Recording — Complete Shooting Script

**Assignment:** IMESH — Network Support Engineer (FTE)
**Video title:** Kubernetes Network Troubleshooting — `frontend → backend` 502
**Target length:** 5:00 (record ~6:00, cut dead time in the edit)
**Resolution:** 1920×1080, 30 fps
**Audio:** one voice track; no music, or a bed at −28 dB
**Repository:** <https://github.com/saikatroy973/IMESH_Network_Support_FTE_Assignment>

---

## What the reviewer is grading, and where it appears

| Criterion | Where it is demonstrated |
|---|---|
| Kubernetes networking fundamentals | 2:10–3:05 (Service → Endpoints → DNAT), 3:40–4:05 (root cause) |
| Services, Pods, Endpoints | 2:10–3:05 (L2, L3, L4, L5) |
| DNS and connectivity troubleshooting | 1:40–2:10 (refused vs timeout), L1 in the runbook |
| Linux networking | 2:10–3:05 (`ss`, `tcpdump`, `iptables`), 3:05–3:40 (direct pod IP) |
| Methodology | Whole video: **Observe → Investigate → Identify → Fix → Verify** |
| Root-cause analysis | 3:40–4:05 |
| Documentation | 4:52–5:00 (repository pointer) |

---

## The story in one paragraph

A client calls the frontend Service. `/` returns **200**; `/api/` returns **502**.
All pods are `Running` and stay `Ready`. The backend Service's `targetPort` has
drifted from **8080** to **9090**, while the container still listens on **8080**.
kube-proxy DNATs ClusterIP:80 to podIP:9090, the pod answers with a TCP **RST**,
and the frontend turns that into a 502. The fix is one field on the Service; no
pod is restarted.

---

## 1. Production settings

| Item | Setting |
|---|---|
| Recorder | OBS (best) or QuickTime. 1920×1080, 30 fps, H.264, AAC 48 kHz |
| Terminal | Dark theme, **17–18 pt**, **120 columns × 35 rows**, no transparency, no blur |
| Cursor | Visible block cursor; disable blinking if it distracts on camera |
| Notifications | macOS **Do Not Disturb** on; quit Slack/Mail/Calendar |
| Desktop | Hide the Dock; close every window except the three tabs below |
| Mic | 10-second test; peak around **−12 dB**; record in a quiet room |
| Browser zoom | 110–125 % so the README diagram is legible if you cut to it |
| Machine | Plugged in; **disable sleep** (`caffeinate -dimsu` in a spare tab) |

> **Do not use a ZIP.** The submission is the public repository plus the video URL.

---

## 2. Pre-flight (do this 20 minutes before recording)

### 2.1 Clean rehearsal

```bash
# 1. Tooling must be present and Docker must be running
docker info
kind version
kubectl version --client

# 2. Go to the repository root (the directory that contains scripts/run-all.sh)
cd /path/to/IMESH_Network_Support_FTE_Assignment
git pull

# 3. Rebuild the whole story from scratch.
#    ARTIFACTS_DIR keeps this rehearsal out of the committed artifacts/ directory.
ARTIFACTS_DIR=/tmp/imesh-rehearsal ./scripts/run-all.sh --recreate
```

Expected at the end:

```
OK   RESOLVED - the full flow client -> frontend -> backend works again
```

The rehearsal takes about **4–5 minutes** (cluster creation, image build, deploy,
baseline, fault, diagnosis, fix, verification, timeline).

### 2.2 Verify the starting state

```bash
kubectl -n imesh-demo get pods -o wide
kubectl -n imesh-demo get svc backend -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
kubectl -n imesh-demo exec deploy/client -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://frontend/api/
```

You must see:

- **five pods**, all `1/1 Running`, `RESTARTS 0`;
- `targetPort` = **8080**;
- the last command prints **200**.

If any of those is false, stop and fix the environment before recording. Do not
record over a broken baseline.

> If the `frontend` pods are in `CrashLoopBackOff` right after a host/Docker
> restart, CoreDNS was not ready when nginx resolved the backend name. Wait
> 30–60 seconds; it self-heals. If it does not, re-run the clean rehearsal.

### 2.3 Open three tabs

| Tab | Contents |
|---|---|
| **A — main terminal** | Repository root; all timed commands below are typed here |
| **B — customer view** | `kubectl -n imesh-demo logs -f deploy/client` |
| **C — documentation** | The README at §6 *Root cause* (GitHub or local editor) |

Leave Tab B running for the whole recording. Its log line is the customer-visible
proof of the 200 → 502 → 200 transition.

### 2.4 Clear the stage

```bash
# Tab A
cd /path/to/IMESH_Network_Support_FTE_Assignment
clear
```

- Terminal prompt should show the repo name, not a long path.
- Command history should be empty (`history -c`) so ↑ does not reveal spoilers.
- Set the window title to `IMESH — Network Troubleshooting`.

### 2.5 Test recording

Record 15 seconds of you saying the first two sentences. Check:

1. Text is readable at 100 % playback.
2. Audio is not clipping and has no keyboard rumble.
3. The cursor is visible against the dark theme.
4. No notification banners appear.

---

## 3. Timeline at a glance

| Time | Length | Beat | Command |
|---|---|---|---|
| 0:00–0:20 | 20 s | Cold open: the ticket | *(title card, or terminal)* |
| 0:20–0:50 | 30 s | Environment and topology | `kubectl get nodes`; `get pods -o wide`; `get svc` |
| 0:50–1:15 | 25 s | Healthy baseline | `./scripts/04-verify-baseline.sh` |
| 1:15–1:40 | 25 s | Inject the one fault | `./scripts/05-inject-fault.sh` |
| 1:40–2:10 | 30 s | Reproduce the symptom | client log + `/` and `/api/` curls + `curl -v` |
| 2:10–3:05 | 55 s | Layered investigation L0–L9 | `./scripts/06-diagnose.sh` |
| 3:05–3:40 | 35 s | Decisive test: Service vs pod IP | direct pod IP on 8080/9090; kube-proxy DNAT |
| 3:40–4:05 | 25 s | Root cause, stated as a diff | `targetPort` vs `containerPort` |
| 4:05–4:25 | 20 s | Fix | `./scripts/07-fix.sh` |
| 4:25–4:52 | 27 s | Verification | `./scripts/08-verify-fixed.sh` |
| 4:52–5:00 | 8 s | Close and repository URL | *(end card)* |

**Total: 5:00.** The narration is ~660 words. At a measured 140–150 wpm it runs
about 4:30, leaving 30 seconds for command output, pauses, and breaths.

---

## 4. Shot-by-shot script

> Commands are run from the repository root in **Tab A** unless stated otherwise.
> All IPs, pod names, and iptables chain IDs are looked up dynamically — never
> hardcode them; they change every time the cluster is recreated.

---

### 0:00–0:20 · Cold open — the ticket

**Purpose:** state the symptom, the surprising part, and the thesis in 20 seconds.

**Screen:** title card in the edit:

```
Kubernetes Network Troubleshooting
200 on /   ·   502 on /api/
```

If you are not adding a title card, either:

- start on **Tab C** at the README's *Symptom* section, which shows the captured
  200/502 lines; or
- skip this beat and start at **0:20** — cut the first 20 seconds in the edit.

Do **not** open on Tab B: at this point the live client log is still healthy
(200/200), which contradicts the narration.

**Say (verbatim):**

> This is a Kubernetes support ticket. The frontend's home page returns 200, but
> every API call returns 502. All five pods are Running, and nothing restarts
> when the failure appears. So the application processes are alive — something
> in the network path between the frontend and the backend is wrong.

**Edit:** optional 4-second title card; fade or hard cut to the environment. If
you open the README instead, crop to the two lines that show 200 on `/` and 502
on `/api/`.

---

### 0:20–0:50 · Environment and topology

**Purpose:** prove this is a real multi-node cluster, not a single-node shortcut.

**Type in Tab A:**

```bash
kubectl get nodes
kubectl -n imesh-demo get pods -o wide
kubectl -n imesh-demo get svc
```

**Say (verbatim):**

> Everything runs on a two-node kind cluster — a control plane and a worker — on
> Kubernetes 1.37 with kindnet. The client is pinned to the control plane;
> frontend and backend run on the worker, so every request crosses a real node
> boundary and exercises kube-proxy. The frontend serves `/` itself and
> reverse-proxies `/api/` to the backend Service. The backend has two replicas,
> both listening on 8080.

**Expected:**

```
NAME                  STATUS   ROLES           AGE   VERSION
imesh-control-plane   Ready    control-plane   ...   v1.37.0
imesh-worker          Ready    <none>          ...   v1.37.0
```

```
NAME                        READY   STATUS    RESTARTS   AGE   IP            NODE
backend-................     1/1     Running   0          ...   10.244.1.x    imesh-worker
backend-................     1/1     Running   0          ...   10.244.1.x    imesh-worker
client-.................     1/1     Running   0          ...   10.244.0.x    imesh-control-plane
frontend-...............     1/1     Running   0          ...   10.244.1.x    imesh-worker
frontend-...............     1/1     Running   0          ...   10.244.1.x    imesh-worker
```

```
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
backend    ClusterIP   10.96.x.x       <none>        80/TCP    ...
frontend   ClusterIP   10.96.x.x       <none>        80/TCP    ...
```

**Point at:** `NODE` column — the client is on `imesh-control-plane`, everything
else on `imesh-worker`.

**Edit:** cut the pause between commands; keep the node and `NODE` columns on
screen for at least 3 seconds.

---

### 0:50–1:15 · Healthy baseline

**Purpose:** establish the control state before changing anything.

**Type in Tab A:**

```bash
./scripts/04-verify-baseline.sh
```

**Say (verbatim):**

> I always establish a baseline before changing anything. This script checks both
> legs, DNS from inside the client pod, and each application's own port. Five
> checks pass. The client's health loop agrees: 200 for the frontend, and 200 for
> the proxied API. This is the control state.

**Expected (key lines):**

```
OK   client -> frontend            : PASS  (FRONTEND-OK  pod=frontend-...  client=10.244.0.x)
OK   frontend -> backend           : PASS  (BACKEND-OK   pod=backend-...   client=10.244.1.x)
OK   client -> frontend -> backend : PASS  (BACKEND-OK   pod=backend-...   client=10.244.1.x)
OK   backend own port 8080         : PASS  (app is alive and serving)
OK   frontend own port 8080        : PASS  (app is alive and serving)
OK   BASELINE HEALTHY - client -> frontend and frontend -> backend both work
```

**Edit:** do not read all five lines aloud. Let the block sit for 2 seconds after
the last PASS; the green `OK` lines are the visual.

---

### 1:15–1:40 · Inject the one fault

**Purpose:** show that only the Service changes; the pods are untouched.

**Type in Tab A:**

```bash
./scripts/05-inject-fault.sh
```

Run this at the **start** of the beat, not the end: the client health loop needs
one 10-second cycle before the symptom beat, otherwise the log still shows the
old 200/200 samples.

**Say (verbatim):**

> Now one fault, and only one: I change the backend Service's targetPort from
> 8080 to 9090. The container still listens on 8080. No pod is deleted,
> restarted, or edited — only the Service object changes. It's realistic drift:
> the application moves to a new port and the Service is left pointing at the old
> one.

**Expected (key lines):**

```
backend Service BEFORE the fault:
  targetPort = 8080

applying manifests/40-fault-targetport.yaml ...
service/backend configured

backend Service AFTER the fault:
  targetPort = 9090

the pods are untouched - no restart, no deletion:
  backend-................   1/1   Running   0   ...
  backend-................   1/1   Running   0   ...

OK   fault injected - frontend -> backend is now broken
```

**Edit:** hold on `targetPort = 9090` and on the `Running 0` restart column. That
is the proof no pod was bounced.

---

### 1:40–2:10 · Reproduce the symptom

**Purpose:** show the split — frontend healthy, downstream broken — and teach the
error semantics that drive the whole investigation.

**Type in Tab A:**

```bash
kubectl -n imesh-demo logs deploy/client --tail=4
kubectl -n imesh-demo exec deploy/client -- \
  curl -s -o /dev/null -w 'GET /      -> %{http_code}\n' http://frontend/
kubectl -n imesh-demo exec deploy/client -- \
  curl -s -o /dev/null -w 'GET /api/  -> %{http_code}\n' http://frontend/api/
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS -v --max-time 5 http://backend.imesh-demo.svc.cluster.local/ 2>&1 \
  | grep -E 'resolved|IPv4|Trying|Connection refused|curl:'
```

The `grep` keeps the two decisive facts on one screen — the name **resolved**
and the connection was **refused** — and drops curl's progress meter.

**Say (verbatim):**

> Ten seconds later, the client log shows the split: frontend 200, `/api/` 502.
> Same client, same Service name — only the downstream leg is broken. Curl gives
> the key clue: **Connection refused**, not a timeout. A timeout means packets
> are dropped — firewall or routing. A refusal means we reached the host and got
> a TCP reset because nothing is listening. So this is a port mapping problem,
> not connectivity.

**Expected:**

```
[....Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=502
```

```
GET /      -> 200
GET /api/  -> 502
```

```
* Host backend.imesh-demo.svc.cluster.local:80 was resolved.
* IPv4: 10.96.x.x
*   Trying 10.96.x.x:80...
* connect to 10.96.x.x port 80 from 10.244.1.x port ... failed: Connection refused
curl: (7) Failed to connect to backend.imesh-demo.svc.cluster.local port 80 ...
```

**Point at:** the words `resolved` and `Connection refused` on the same screen.
That single frame rules out DNS and packet drops at once.

**If the log still shows 200/200:** the client loop is 10 seconds; wait one more
cycle, then run `logs --tail=2` again. Do not edit the log.

---

### 2:10–3:05 · Layered investigation (the runbook)

**Purpose:** walk the stack from DNS to the wire, and show why the obvious
"endpoints exist" check is not enough.

**Type in Tab A:**

```bash
./scripts/06-diagnose.sh
```

The script runs for **~25 seconds** (the packet capture dominates). Let it run;
do not press Ctrl-C.

**Say (verbatim, over the output):**

> Now the runbook, layer by layer. L1: DNS. `getent`, `dig` and `nslookup` all
> return the ClusterIP — CoreDNS is fine. L1b: no NetworkPolicies exist, and the
> refusal already ruled out dropping. L2: the Service says **targetPort 9090** —
> first red flag. L3: two endpoints exist, both Ready — so the selector and the
> probes are fine — but the endpoint port is **9090**. That's the trap: endpoints
> prove readiness, not that the port is right. L4: the container declares
> **8080**. L5: `ss` inside the pod shows nginx listening on **8080**. L6: the pod
> IP on 8080 works. L7: the capture shows SYN to **9090**, reset back. L8:
> kube-proxy's rule says DNAT to **9090**. Every layer is healthy except the
> Service's port mapping.

**What to point at as it scrolls (in order):**

| Layer | Line to look for |
|---|---|
| L1 | `10.96.x.x  backend.imesh-demo.svc.cluster.local` |
| L1b | `<none> - no NetworkPolicy objects exist in this namespace` |
| L2 | `targetPort=9090` |
| L3 | `endpoints=10.244.1.x 10.244.1.x  ready=true true  ports=9090` |
| L4 | `containerPort=8080` |
| L5 | `LISTEN 0 ... 0.0.0.0:8080` |
| L7 | `Flags [S]` to `:9090`, then `Flags [R.]` back |
| L8 | `DNAT --to-destination 10.244.1.x:9090` |
| L9 | `ROOT CAUSE: the backend Service targetPort (9090) does not match ...` |

**Edit:** the output is long and fast. Add a **2× zoom + 1.5-second freeze** on
the L2, L3, L4, L7 and L8 lines. If you do not edit, the recap at 3:40–4:05
repeats the decisive numbers at a readable pace.

**Do not say:** "the backend is down." It is not; L5 and L6 prove otherwise.

---

### 3:05–3:40 · Decisive test: Service vs pod IP

**Purpose:** isolate the fault to the Service-to-pod mapping with a controlled
comparison.

**Type in Tab A:**

```bash
BACKEND_POD_IP=$(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].status.podIP}')
echo "backend pod IP: ${BACKEND_POD_IP}"

# 1. through the Service: the broken path
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 http://backend.imesh-demo.svc.cluster.local/

# 2. straight to the same pod, on the port the application really uses
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 "http://${BACKEND_POD_IP}:8080/"

# 3. straight to the same pod, on the port the Service points at
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 "http://${BACKEND_POD_IP}:9090/"
```

Then show the data-plane rule:

```bash
kubectl -n kube-system exec ds/kube-proxy -- iptables-save \
  | grep 'imesh-demo/backend:http' | grep DNAT
```

**Say (verbatim):**

> The decisive test is the direct comparison. Through the Service, connection
> refused. Straight to the same pod on 8080: BACKEND-OK. Same pod, same network,
> same client. That isolates the fault to the Service-to-pod mapping and
> exonerates the CNI, the node, the pod, and the application. The kube-proxy rule
> confirms where the packets actually go: DNAT to port 9090.

**Expected:**

```
backend pod IP: 10.244.1.x
curl: (7) Failed to connect to backend.imesh-demo.svc.cluster.local port 80 ...
BACKEND-OK  pod=backend-...  client=10.244.1.x
curl: (7) Failed to connect to 10.244.1.x port 9090 after 0 ms: Could not connect to server
```

```
-A KUBE-SEP-... -p tcp -m comment --comment "imesh-demo/backend:http" -m tcp -j DNAT --to-destination 10.244.1.x:9090
-A KUBE-SEP-... -p tcp -m comment --comment "imesh-demo/backend:http" -m tcp -j DNAT --to-destination 10.244.1.x:9090
```

**Note:** `kubectl exec` prints `command terminated with exit code 7` after the
refused curl. Leave it in — it is the expected result of a connection refused.

**Fallback for the DNAT command:** if `kubectl exec ds/kube-proxy` is unavailable,
use the node container directly:

```bash
docker exec imesh-worker iptables -t nat -S | grep 'imesh-demo/backend:http' | grep DNAT
```

---

### 3:40–4:05 · Root cause

**Purpose:** state the root cause as a one-line diff, not a story.

**Type in Tab A:**

```bash
kubectl -n imesh-demo get svc backend \
  -o jsonpath='Service targetPort : {.spec.ports[0].targetPort}{"\n"}'
kubectl -n imesh-demo get deploy backend \
  -o jsonpath='Container port     : {.spec.template.spec.containers[0].ports[0].containerPort}{"\n"}'
```

**Say (verbatim):**

> Root cause as a diff: the Service's targetPort is 9090; the container listens
> on 8080. kube-proxy programs DNAT from ClusterIP port 80 to podIP port 9090,
> where nothing is listening, so every connection is rejected with a reset. The
> pods stay Ready because the readiness probe correctly targets 8080 — kubelet
> never sees a Service-level fault.

**Expected:**

```
Service targetPort : 9090
Container port     : 8080
```

**Optional cutaway:** switch to **Tab C** (README §6) for 3 seconds to show the
sequence diagram: `GET /api/ → DNAT :9090 → RST → 502`. Return to Tab A.

**Edit:** this is the money shot. Hold the two-line output for **4 seconds** with
no cursor movement. Add a caption: `targetPort ≠ containerPort`.

---

### 4:05–4:25 · Fix

**Purpose:** show a declarative, minimal, reversible change.

**Type in Tab A:**

```bash
./scripts/07-fix.sh
```

**Say (verbatim):**

> The fix is one field. I apply the corrected manifest rather than an imperative
> patch, because the manifest is what survives the next apply or GitOps sync. The
> pods are not touched: same names, same restart count, same age. Only the
> Service changes.

**Expected (key lines):**

```
targetPort BEFORE the fix:
  9090

[1/2] applying the corrected manifest (declarative):
service/backend configured

targetPort AFTER the fix:
  8080

the backend pods were never restarted - only the Service was corrected:
  backend-................   1/1   Running   0   ...

OK   fix applied - Service targetPort now matches the container port
```

**Edit:** hold on `8080` after the fix. Do not cut away before the `Running 0`
lines are visible.

---

### 4:25–4:52 · Verification

**Purpose:** prove the fix with the same assertions, fresh samples, and no pod
restarts.

**Type in Tab A:**

```bash
./scripts/08-verify-fixed.sh
```

The script deliberately waits **up to ~17 seconds** for two new client samples,
so the verification cannot be fooled by pre-fix log lines. Let the wait run.

**Say (verbatim):**

> Verification re-runs the same assertions. The Service now DNATs to 8080, all
> five checks pass, and the client's fresh samples — taken after the fix, not
> replayed — show 200 and 200. Pod names and restart counts are unchanged, which
> proves the repair was a control-plane change, not a pod restart. That's the
> full cycle: observe, investigate, identify, fix, verify.

**Expected (key lines):**

```
endpoints:
  backend   10.244.1.x:8080,10.244.1.x:8080   ...

kube-proxy DNAT rules after the fix (the destination port is now 8080):
  ... DNAT --to-destination 10.244.1.x:8080
  ... DNAT --to-destination 10.244.1.x:8080

OK   client -> frontend            : PASS  ...
OK   frontend -> backend           : PASS  ...
OK   client -> frontend -> backend : PASS  ...
OK   backend own port 8080         : PASS  ...
OK   frontend own port 8080        : PASS  ...

client health loop (fresh samples recorded after the fix):
  [....Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=200
  [....Z] client -> frontend  http_code=200   |   client -> frontend(/api/) -> backend  http_code=200

OK   RESOLVED - the full flow client -> frontend -> backend works again
```

**Edit:** if the 17-second wait feels long, speed only the **empty** part at 4×;
keep the first and last second at normal speed. Do not cut the sentence that
explains why the script waits.

---

### 4:52–5:00 · Close

**Screen:** end card in the edit:

```
Repository: github.com/saikatroy973/IMESH_Network_Support_FTE_Assignment
README · manifests/ · scripts/ · artifacts/
```

**Say (verbatim):**

> The runbook, manifests and captured output are in the repository. Thanks for
> watching.

**Edit:** 3-second fade. Do not add music over the last sentence.

---

## 5. Teleprompter (narration only)

Print this page or put it on a second screen. `[pause]` means a beat, not a cut.

```
0:00  This is a Kubernetes support ticket. The frontend's home page returns
      200, but every API call returns 502. All five pods are Running, and
      nothing restarts when the failure appears. So the application processes
      are alive — something in the network path between the frontend and the
      backend is wrong.

0:20  Everything runs on a two-node kind cluster — a control plane and a
      worker — on Kubernetes 1.37 with kindnet. The client is pinned to the
      control plane; frontend and backend run on the worker, so every request
      crosses a real node boundary and exercises kube-proxy. The frontend
      serves / itself and reverse-proxies /api/ to the backend Service. The
      backend has two replicas, both listening on 8080.

0:50  I always establish a baseline before changing anything. This script
      checks both legs, DNS from inside the client pod, and each application's
      own port. Five checks pass. The client's health loop agrees: 200 for the
      frontend, and 200 for the proxied API. This is the control state.

1:15  Now one fault, and only one: I change the backend Service's targetPort
      from 8080 to 9090. The container still listens on 8080. No pod is
      deleted, restarted, or edited — only the Service object changes. It's
      realistic drift: the application moves to a new port and the Service is
      left pointing at the old one.

1:40  Ten seconds later, the client log shows the split: frontend 200, /api/
      502. Same client, same Service name — only the downstream leg is broken.
      Curl gives the key clue: Connection refused, not a timeout. A timeout
      means packets are dropped — firewall or routing. A refusal means we
      reached the host and got a TCP reset because nothing is listening. So
      this is a port mapping problem, not connectivity.

2:10  Now the runbook, layer by layer. L1: DNS. getent, dig and nslookup all
      return the ClusterIP — CoreDNS is fine. L1b: no NetworkPolicies exist,
      and the refusal already ruled out dropping. L2: the Service says
      targetPort 9090 — first red flag. L3: two endpoints exist, both Ready —
      so the selector and probes are fine — but the endpoint port is 9090.
      That's the trap: endpoints prove readiness, not that the port is right.
      L4: the container declares 8080. L5: ss inside the pod shows nginx
      listening on 8080. L6: the pod IP on 8080 works. L7: the capture shows
      SYN to 9090, reset back. L8: kube-proxy's rule says DNAT to 9090.
      Every layer is healthy except the Service's port mapping.

3:05  The decisive test is the direct comparison. Through the Service,
      connection refused. Straight to the same pod on 8080: BACKEND-OK. Same
      pod, same network, same client. That isolates the fault to the
      Service-to-pod mapping and exonerates the CNI, the node, the pod, and
      the application. The kube-proxy rule confirms where the packets actually
      go: DNAT to port 9090.

3:40  Root cause as a diff: the Service's targetPort is 9090; the container
      listens on 8080. kube-proxy programs DNAT from ClusterIP port 80 to
      podIP port 9090, where nothing is listening, so every connection is
      rejected with a reset. The pods stay Ready because the readiness probe
      correctly targets 8080 — kubelet never sees a Service-level fault.

4:05  The fix is one field. I apply the corrected manifest rather than an
      imperative patch, because the manifest is what survives the next apply
      or GitOps sync. The pods are not touched: same names, same restart count,
      same age. Only the Service changes.

4:25  Verification re-runs the same assertions. The Service now DNATs to
      8080, all five checks pass, and the client's fresh samples — taken after
      the fix, not replayed — show 200 and 200. Pod names and restart counts
      are unchanged, which proves the repair was a control-plane change, not a
      pod restart. That's the full cycle: observe, investigate, identify, fix,
      verify.

4:52  The runbook, manifests and captured output are in the repository.
      Thanks for watching.
```

---

## 6. Edit map

| Time | Edit | Why |
|---|---|---|
| 0:00 | Title card, 4 s | Names the ticket before the terminal appears |
| 0:20 | Cut command pauses | Keeps the environment beat under 30 s |
| 2:10–3:05 | 2× zoom + 1.5 s freeze on L2/L3/L4/L7/L8 | The runbook scrolls too fast to read |
| 3:40 | Hold the two-line diff for 4 s | This is the root-cause frame |
| 4:25 | 4× only the empty wait, not the output | The wait is a deliberate verification feature |
| 4:52 | End card with repo URL | The reviewer needs the link |
| Throughout | Captions for `ClusterIP`, `targetPort`, `DNAT`, `RST` | Networking terms carry the grade |

**Do not cut:**

1. the `200` vs `502` split;
2. `Connection refused` vs timeout;
3. the endpoints-are-Ready-but-on-9090 trap;
4. the direct pod comparison;
5. the unchanged pod names, ages, and restart counts.

Those five carry the entire investigation.

---

## 7. If something goes wrong

| Symptom | Recovery |
|---|---|
| `05` says the fault is already present | `./scripts/07-fix.sh && ./scripts/05-inject-fault.sh` |
| Client log still shows 200/200 | Wait one 10-second loop; re-run `logs --tail=2` |
| `frontend` pods crash-loop after a host restart | Wait 30–60 s for CoreDNS; if still down, re-run the clean rehearsal |
| Docker Desktop stops or the API dies | Stop recording, restart Docker, re-run the pre-flight, start over |
| `kubectl exec ds/kube-proxy` fails | Use `docker exec imesh-worker iptables -t nat -S \| grep ...` |
| You typo a command | Fix it, continue; cut the typo in the edit. Never hide a failed command by pretending it passed |
| The 06 output is too fast to read | Rely on the 3:40 recap; it repeats the decisive numbers at human pace |

**Never do any of these on camera:**

- `kubectl delete pod` or `rollout restart` — the assignment forbids "fixing" by
  restarting workloads, and it would destroy the evidence;
- change two things at once;
- say "the backend is down" — the pods are Ready and serving on 8080;
- edit the client log or the artifacts.

---

## 8. Upload checklist

- [ ] Watch the export end-to-end at 1080p; no frame shows a notification or an
      unrelated window.
- [ ] Audio is intelligible on laptop speakers; no clipping; keyboard noise is
      acceptable but not dominant.
- [ ] The five "do not cut" moments are present.
- [ ] Runtime is **4:50–5:10**. If longer, use the edit map; do not speed up the
      narration.
- [ ] Upload to YouTube as **Unlisted** (or Google Drive: "anyone with the link").
- [ ] Title: `Kubernetes Network Troubleshooting — IMESH Support Assignment`.
- [ ] Description: one-paragraph summary + repository URL + chapters:

```
0:00 Symptom
0:20 Environment
0:50 Healthy baseline
1:15 Fault injection
1:40 Symptom reproduction
2:10 Layered investigation
3:05 Decisive test
3:40 Root cause
4:05 Fix
4:25 Verification
4:52 Summary
```

- [ ] Correct the auto-captions for `targetPort`, `kube-proxy`, `DNAT`,
      `EndpointSlice`, `CoreDNS`, and `RST`.
- [ ] Copy the video URL into the submission email.

---

## 9. Appendix — every command, in order

Run from the repository root. Values in `<...>` are illustrative; the commands
look everything up dynamically.

```bash
# ---------- environment ----------
kubectl get nodes
kubectl -n imesh-demo get pods -o wide
kubectl -n imesh-demo get svc

# ---------- baseline ----------
./scripts/04-verify-baseline.sh

# ---------- inject exactly one fault ----------
./scripts/05-inject-fault.sh

# ---------- symptom ----------
kubectl -n imesh-demo logs deploy/client --tail=4
kubectl -n imesh-demo exec deploy/client -- \
  curl -s -o /dev/null -w 'GET /      -> %{http_code}\n' http://frontend/
kubectl -n imesh-demo exec deploy/client -- \
  curl -s -o /dev/null -w 'GET /api/  -> %{http_code}\n' http://frontend/api/
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS -v --max-time 5 http://backend.imesh-demo.svc.cluster.local/ 2>&1 \
  | grep -E 'resolved|IPv4|Trying|Connection refused|curl:'

# ---------- layered investigation ----------
./scripts/06-diagnose.sh

# ---------- decisive test ----------
BACKEND_POD_IP=$(kubectl -n imesh-demo get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{.items[0].status.podIP}')
echo "backend pod IP: ${BACKEND_POD_IP}"
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 http://backend.imesh-demo.svc.cluster.local/
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 "http://${BACKEND_POD_IP}:8080/"
kubectl -n imesh-demo exec deploy/frontend -- \
  curl -sS --max-time 3 "http://${BACKEND_POD_IP}:9090/"

# ---------- data-plane proof ----------
kubectl -n kube-system exec ds/kube-proxy -- iptables-save \
  | grep 'imesh-demo/backend:http' | grep DNAT

# ---------- root cause as a diff ----------
kubectl -n imesh-demo get svc backend \
  -o jsonpath='Service targetPort : {.spec.ports[0].targetPort}{"\n"}'
kubectl -n imesh-demo get deploy backend \
  -o jsonpath='Container port     : {.spec.template.spec.containers[0].ports[0].containerPort}{"\n"}'

# ---------- fix ----------
./scripts/07-fix.sh

# ---------- verification ----------
./scripts/08-verify-fixed.sh
```

---

## 10. Why this video is hard to fake

- The **pods never restart**: the same pod names, ages, and restart counts
  appear before the fault, after the fix, and in the verification.
- The **Service is the only object that changes**: `05` prints the before/after
  `targetPort`, and the pod age column does not move.
- The **client log is generated by a workload**, not by the presenter: it shows
  the 200 → 502 → 200 transition on its own 10-second schedule.
- The **packet capture and kube-proxy rules** agree with the API objects, so the
  conclusion is grounded in the data plane, not just in `kubectl get`.
