#!/usr/bin/env bash
# Step 6 - TROUBLESHOOTING RUNBOOK.
#
# This script is written the way an on-call engineer would actually work the
# ticket: start from the symptom, then walk the network stack from the top
# (DNS) down to the bottom (the application's listening socket), and only fix
# something once the root cause is proven.
#
#     Observe  ->  Investigate  ->  Identify  ->  Fix  ->  Verify
#
# Layer model used here:
#
#   L0  symptom          what does the user see?
#   L1  DNS              does the Service name resolve?  -> ClusterIP
#   L2  Service          what does the Service map to?   -> selector + port/targetPort
#   L3  Endpoints        which pods back the Service and on WHICH port?
#   L4  Pod              which port does the container declare / listen on?
#   L5  App              is the process alive and accepting on that port?
#   L6  Packet capture   what really goes out on the wire?
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 6 - Troubleshooting runbook"

BACKEND_SVC="backend.${NAMESPACE}.svc.cluster.local"
BACKEND_POD_IP="$(k get pod -l app.kubernetes.io/name=backend -o jsonpath='{.items[0].status.podIP}')"

# ---------------------------------------------------------------------------
printf '\n%s--- L0  SYMPTOM: reproduce the reported failure -------------%s\n' "${C_BOLD}" "${C_RESET}"
info "client -> frontend (expected to still work):"
kexec_q client curl -sS --max-time 5 "http://frontend.${NAMESPACE}.svc.cluster.local/" 2>&1 | sed 's/^/      /' || true
info ""
info "frontend -> backend (reported as broken):"
kexec_q frontend curl -sS --max-time 5 -v "http://${BACKEND_SVC}/" 2>&1 | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
printf '\n%s--- L1  DNS: does the Service name resolve? -------------------%s\n' "${C_BOLD}" "${C_RESET}"
info "getent hosts backend.${NAMESPACE}.svc.cluster.local:"
kexec_q frontend getent hosts "${BACKEND_SVC}" 2>&1 | sed 's/^/      /' || true
info "dig +short (from the client pod, to show CoreDNS is answering):"
kexec_q client dig +short "${BACKEND_SVC}" 2>&1 | sed 's/^/      /' || true
info "Service ClusterIP from the API:"
k get svc backend -o wide --no-headers | sed 's/^/      /'

# ---------------------------------------------------------------------------
printf '\n%s--- L2  SERVICE: what does the backend Service map to? ---------%s\n' "${C_BOLD}" "${C_RESET}"
info "kubectl get svc backend -o yaml (relevant fields):"
k get svc backend -o jsonpath='{range .spec.ports[*]}      port={.port}  targetPort={.targetPort}  protocol={.protocol}  name={.name}{"\n"}{end}' | sed 's/^/      /'
info "selector:"
k get svc backend -o jsonpath='      {.spec.selector}'; echo

# ---------------------------------------------------------------------------
printf '\n%s--- L3  ENDPOINTS: which pods back the Service, on which port? %s\n' "${C_BOLD}" "${C_RESET}"
info "kubectl get endpoints backend:"
k get endpoints backend --no-headers | sed 's/^/      /'
info ""
info "kubectl get endpointslices (modern source of truth):"
k get endpointslices -l kubernetes.io/service-name=backend \
  -o jsonpath='{range .items[*]}      endpoints={.endpoints[*].addresses[*]}  ready={.endpoints[*].conditions.ready}  ports={.ports[*].port}{"\n"}{end}' 2>&1 | sed 's/^/      /' || true
info ""
info "kubectl describe svc backend (Events + spec):"
k describe svc backend 2>&1 | sed 's/^/      /'

# ---------------------------------------------------------------------------
printf '\n%s--- L4  POD: which port does the container declare? ------------%s\n' "${C_BOLD}" "${C_RESET}"
info "kubectl describe pod (container ports):"
k describe pod -l app.kubernetes.io/name=backend 2>&1 | grep -E "^(Name|Namespace|Node|Status|Containers|Port|  Image|  Ready|  Restart Count|IP:|Controlled By)" | sed 's/^/      /' || true
info ""
info "declared containerPort:"
k get pod -l app.kubernetes.io/name=backend \
  -o jsonpath='{range .items[0].spec.containers[*].ports[*]}      name={.name}  containerPort={.containerPort}  protocol={.protocol}{"\n"}{end}' | sed 's/^/      /'

# ---------------------------------------------------------------------------
printf '\n%s--- L5  APP: is the process alive, and on which socket? ---------%s\n' "${C_BOLD}" "${C_RESET}"
info "ss -lntp inside the backend pod (the authoritative answer):"
kexec_q backend ss -lntp 2>&1 | sed 's/^/      /' || true
info ""
info "container log tail (nginx started normally?):"
k logs -l app.kubernetes.io/name=backend --tail=5 --prefix 2>&1 | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
printf '\n%s--- L6  CROSS-CHECK: bypass the Service and hit the pod IP -----%s\n' "${C_BOLD}" "${C_RESET}"
info "backend pod IP = ${BACKEND_POD_IP}"
info "a) frontend -> podIP:8080   (the port the app really listens on):"
kexec_q frontend curl -sS --max-time 5 "http://${BACKEND_POD_IP}:8080/" 2>&1 | sed 's/^/      /' || true
info "b) frontend -> podIP:9090   (the port the Service is now pointing at):"
kexec_q frontend curl -sS --max-time 5 "http://${BACKEND_POD_IP}:9090/" 2>&1 | sed 's/^/      /' || true
info "c) frontend -> ClusterIP:80 (the Service, i.e. the reported symptom):"
kexec_q frontend curl -sS --max-time 5 "http://$(svc_ip backend):80/" 2>&1 | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
printf '\n%s--- L7  PACKET CAPTURE: what goes on the wire? ----------------%s\n' "${C_BOLD}" "${C_RESET}"
info "Two captures inside the BACKEND pods. The client sees the ClusterIP;"
info "the backend pod sees the post-DNAT destination."

BACKEND_PODS="$(k get pod -l app.kubernetes.io/name=backend -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

info ""
info "(a) traffic on port 9090 - the port the Service points at."
info "    kube-proxy load-balances 50/50 across the replicas, so the capture is"
info "    started on EVERY backend pod to be sure to catch the DNAT'ed traffic:"
CAP_JOBS=()
for p in ${BACKEND_PODS}; do
  (
    kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" exec "$p" -- bash -c '
      (timeout 12 tcpdump -n -l -i any "tcp port 9090" > /tmp/td9090.out 2>&1 &) ;
      sleep 9 ;
      echo "      --- capture on '"$p"' ---" ;
      grep -E "IP |Flags" /tmp/td9090.out | head -6' 2>&1
  ) &
  CAP_JOBS+=($!)
done
sleep 3
kexec_q frontend curl -sS --max-time 4 -o /dev/null "http://${BACKEND_SVC}/" >/dev/null 2>&1 || true
wait "${CAP_JOBS[@]}" 2>/dev/null || true

info ""
info "(b) traffic on port 8080 - the port the app really listens on"
info "    (the kubelet health probe lands here and succeeds):"
for p in ${BACKEND_PODS}; do
  kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" exec "$p" -- bash -c '
    (timeout 8 tcpdump -n -l -i any "tcp port 8080" > /tmp/td8080.out 2>&1 &) ;
    sleep 6 ;
    echo "      --- capture on '"$p"' ---" ;
    grep -E "IP |Flags|HTTP" /tmp/td8080.out | head -8' 2>&1
done

# ---------------------------------------------------------------------------
printf '\n%s--- L8  NODE LEVEL: kube-proxy DNAT rules -----------------------%s\n' "${C_BOLD}" "${C_RESET}"
info "kube-proxy translates ClusterIP:80 into podIP:<targetPort>."
info "The rule below is the ground truth for where traffic is actually sent:"
if docker ps --format '{{.Names}}' | grep -q "^imesh-worker$"; then
  SVC_CHAIN="$(docker exec imesh-worker sh -c \
    'iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep "imesh-demo/backend:http" | grep -oE "KUBE-SVC-[A-Z0-9]+"' 2>/dev/null | head -1)"
  if [[ -n "${SVC_CHAIN}" ]]; then
    info "cluster-IP rule (${SVC_CHAIN}):"
    docker exec imesh-worker sh -c "iptables -t nat -S ${SVC_CHAIN} 2>/dev/null" 2>&1 | sed 's/^/      /' || true
    info ""
    info "per-endpoint DNAT rules (these contain the real destination port):"
    docker exec imesh-worker sh -c \
      "iptables -t nat -S ${SVC_CHAIN} 2>/dev/null | grep -oE 'KUBE-SEP-[A-Z0-9]+' | while read sep; do iptables -t nat -S \"\$sep\" 2>/dev/null; done" \
      2>&1 | sed 's/^/      /' || true
  fi
  info ""
  info "for contrast - the healthy frontend Service:"
  FE_CHAIN="$(docker exec imesh-worker sh -c \
    'iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep "imesh-demo/frontend:http" | grep -oE "KUBE-SVC-[A-Z0-9]+"' 2>/dev/null | head -1)"
  if [[ -n "${FE_CHAIN}" ]]; then
    docker exec imesh-worker sh -c \
      "iptables -t nat -S ${FE_CHAIN} 2>/dev/null | grep -oE 'KUBE-SEP-[A-Z0-9]+' | while read sep; do iptables -t nat -S \"\$sep\" 2>/dev/null; done" \
      2>&1 | sed 's/^/      /' || true
  fi
else
  warn "kind node container not reachable - skipping kube-proxy rule inspection"
fi

# ---------------------------------------------------------------------------
printf '\n%s--- L9  IDENTIFY: root cause ----------------------------------%s\n' "${C_BOLD}" "${C_RESET}"
svc_target="$(k get svc backend -o jsonpath='{.spec.ports[0].targetPort}')"
ctr_target="$(k get pod -l app.kubernetes.io/name=backend -o jsonpath='{.items[0].spec.containers[0].ports[0].containerPort}')"
info "Service backend .spec.ports[0].targetPort  = ${svc_target}"
info "backend container .ports[0].containerPort   = ${ctr_target}"
if [[ "${svc_target}" != "${ctr_target}" ]]; then
  fail "MISMATCH  ->  kube-proxy sends traffic to podIP:${svc_target} but nginx listens on :${ctr_target}"
  printf '\n%s  ROOT CAUSE: the backend Service targetPort (%s) does not match the port\n' "${C_BOLD}" "${svc_target}"
  printf '  the backend container actually listens on (%s).  The Service object\n' "${ctr_target}"
  printf '  re-points ClusterIP:80 at a closed port, so every frontend -> backend\n'
  printf '  connection is rejected with a TCP RST ("Connection refused").\n'
  printf '  The pod, the application and DNS are all healthy - only the\n'
  printf '  Service -> pod port mapping is wrong.\n%s\n' "${C_RESET}"
else
  ok "targetPort matches containerPort - the Service mapping is correct"
fi

printf '\n'
info "run scripts/06-fix.sh to correct the Service, then scripts/07-verify-fixed.sh"
