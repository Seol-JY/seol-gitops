# Runbook

IP 는 `<cp-1 사설 IP>` 처럼 자리표시자로 표기, 실제 값은 OCI 콘솔 또는 `kubectl get nodes -o wide` 로 확인

## 1. kubeconfig

```bash
mkdir -p ~/.kube && chmod 700 ~/.kube
ssh <cp-1> 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's/127.0.0.1/<cp-1 공인 IP>/; s/name: default/name: seol-k3s/g; s/cluster: default/cluster: seol-k3s/; s/user: default/user: seol-k3s/; s/current-context: default/current-context: seol-k3s/' \
  > ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

- 6443 은 VCN 과 작업용 PC IP 에만 허용
- PC IP 변경 시 7절 NSG 규칙과 6절 iptables 줄을 함께 수정

## 2. k3s 설정

설정은 CLI 플래그 대신 `/etc/rancher/k3s/config.yaml`, 변경 후 `sudo systemctl restart k3s` (워커는 `k3s-agent`)

cp-1 (`k3s.service`)

```yaml
node-ip: <cp-1 사설 IP>
node-external-ip: <cp-1 공인 IP>
advertise-address: <cp-1 사설 IP>
tls-san:
  - <cp-1 공인 IP>
  - cp-1
write-kubeconfig-mode: "0600"
secrets-encryption: true
```

- `advertise-address` 는 반드시 사설 IP
- 비우면 `node-external-ip` 가 광고 주소가 되어 `kubernetes` 엔드포인트와 에이전트 터널이 공인 IP 를 향함, OCI 는 자기 공인 IP 로 되돌아오는 경로가 없어 파드 → API 서버와 `kubectl exec/logs` 실패

worker (`k3s-agent.service`)

```yaml
server: https://<cp-1 사설 IP>:6443
node-ip: <이 노드 사설 IP>
node-external-ip: <이 노드 공인 IP>
node-label:
  - tier=data-a
```

## 3. Argo CD

UI 는 외부 비노출, port-forward 로만 접근

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080  (server.insecure=true 라 터널 안에서는 http)
```

초기 admin 비밀번호

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

로그인 후 비밀번호 변경, 초기 시크릿 삭제

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

부트스트랩 (클러스터 초기화 때 한 번)

```bash
kubectl apply -k infra/argocd --server-side --force-conflicts
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f argocd/root.yaml
```

프라이빗 레포지터리면 루트 등록 전에 읽기 전용 deploy key 를 Argo CD repository Secret 으로 등록, 퍼블릭이면 불필요

## 4. Sealed Secrets

컨트롤러는 `kube-system/sealed-secrets-controller`, kubeseal 기본값과 동일해 옵션 불필요

```bash
kubectl create secret generic my-secret -n my-app \
  --from-literal=password='...' --dry-run=client -o yaml > my-secret.plain.yaml
kubeseal --format yaml < my-secret.plain.yaml > my-secret.sealedsecret.yaml
rm my-secret.plain.yaml
```

- 기본(strict) 스코프, `name` 이나 `namespace` 가 바뀌면 복호화 불가, 다른 네임스페이스는 다시 봉인
- 오프라인 봉인용 공개키

```bash
kubeseal --fetch-cert > sealed-secrets-public.pem
kubeseal --cert sealed-secrets-public.pem --format yaml < x.plain.yaml > x.sealedsecret.yaml
```

### 개인키 백업

- 클러스터 재설치 시 개인키가 사라져 레포지터리의 SealedSecret 전부 복호화 불가
- 키는 30일마다 추가(기존 키 유지), 주기적으로 전체 백업

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-keys.backup.yaml
```

- 평문 개인키, 레포지터리에 넣지 말고 비밀번호 관리자나 암호화한 오프라인 저장소에 보관

복구 (새 클러스터에 컨트롤러 설치 후)

```bash
kubectl apply -f sealed-secrets-keys.backup.yaml
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
```

## 5. 인그레스와 TLS

- `letsencrypt-prod` ClusterIssuer(DNS01, Cloudflare)가 `*.seol.pro` 와일드카드 인증서를 `kube-system/wildcard-seol-pro-tls` 에 발급
- Traefik 기본 TLSStore 가 이 시크릿을 사용, Ingress 는 `tls.secretName` 없이 `tls: [{hosts: [x.seol.pro]}]` 만 기재
- 갱신은 만료 30일 전 자동, 확인은 `kubectl -n kube-system get certificate wildcard-seol-pro`
- Cloudflare 토큰은 `Zone.DNS:Edit` 권한만, 존은 `seol.pro` 하나, Client IP 필터에 노드 공인 IP 3개, 글로벌 API 키 사용 금지

토큰 등록

```bash
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token='...' --dry-run=client -o yaml > cf.plain.yaml
kubeseal --format yaml < cf.plain.yaml > infra/cert-manager-issuers/cloudflare-api-token.sealedsecret.yaml
rm cf.plain.yaml
```

앱 노출 순서: Cloudflare 에 `<앱>.seol.pro` A 레코드(DNS only) → NLB 공인 IP → Ingress 커밋

### Traefik 설정

`infra/traefik/` 의 `HelmChartConfig` 가 k3s 내장 Traefik 의 차트 값만 덮어쓴다

- `web`(80) 은 전량 `websecure`(443) 로 308 리다이렉트, priority 1000 은 앱 라우터(규칙 길이 기반, 보통 수십)보다 높게 잡은 값
- `websecure` 응답에 `kube-system/hsts` Middleware 로 `max-age=31536000; includeSubDomains` 적용, `preload` 는 제거에 수개월 걸려 사용하지 않음
- `/ping` 은 `IngressRoute` 로 web 엔트리포인트에 노출, priority 2000 으로 리다이렉트보다 높여 200 을 반환, NLB 헬스체크가 이 경로를 사용
- `deployment.replicas: 2` 와 `topologySpreadConstraints` 로 서로 다른 노드에 배치, 노드 하드 장애 시 파드 재스케줄이 기본 300초 걸리는 것을 회피
- `websecure` 의 `proxyProtocol.trustedIPs` 가 NLB 443 리스너의 PPv2 헤더를 신뢰, PROXY 헤더가 없는 연결은 그대로 처리하므로 노드 직접 접속도 계속 동작
- 의존은 한 방향이다. 리스너 PPv2 를 켠 채 이 설정을 지우면 헤더 바이트가 TLS 핸드셰이크를 깨뜨리므로, 끌 때는 Traefik 쪽을 나중에 지움
- `logs.access` 는 JSON 으로 켜두고 web 엔트리포인트는 `observability.accessLogs: false` 로 제외, 308 리다이렉트와 헬스체크가 로그를 채우지 않게 함
- `resources` 는 requests 50m/64Mi, limits 256Mi (실사용 18Mi). `podDisruptionBudget.minAvailable: 1` 로 노드 drain 이 두 파드를 동시에 내리지 못하게 함

확인

```bash
curl -sI http://<앱>.seol.pro/ | head -1              # HTTP/1.1 308
curl -sI https://<앱>.seol.pro/ | grep -i strict      # max-age=31536000
curl -s http://<LB 공인 IP>/ping                       # OK, 노드 공인 IP 는 NSG 로 차단됨
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=5 | grep ClientHost   # PPv2 로 받은 원본 IP
```

되돌리기: `infra/traefik/` 삭제 후 push, Argo CD 가 prune 하면 helm-controller 가 차트 기본값으로 복원

## 6. 노드 OS 방화벽

- Oracle 이미지는 `/etc/iptables/rules.v4` 에 기본 `REJECT` 가 있어 OCI 단을 열어도 OS 가 차단
- ufw 는 k3s 와 충돌하므로 사용 금지
- `-A INPUT -j REJECT` 줄 위에 아래 규칙 추가

```
# k3s (begin)
-A INPUT -s 10.0.0.0/16 -p tcp -m state --state NEW -m tcp --dport 6443 -j ACCEPT      # cp-1 만
-A INPUT -s <PC IP>/32 -p tcp -m state --state NEW -m tcp --dport 6443 -j ACCEPT       # cp-1 만
-A INPUT -s 10.0.0.0/16 -p udp -m udp --dport 8472 -j ACCEPT
-A INPUT -s 10.0.0.0/16 -p tcp -m state --state NEW -m tcp --dport 10250 -j ACCEPT
-A INPUT -s 10.0.0.0/16 -p tcp -m state --state NEW -m tcp --dport 9100 -j ACCEPT      # node-exporter
-A INPUT -s 10.42.0.0/16 -j ACCEPT
-A INPUT -s 10.43.0.0/16 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT
# k3s (end)
```

- 규칙을 추가할 때는 파일을 고쳐 재부팅 뒤를 대비하고, 런타임에는 `sudo iptables -I INPUT <REJECT 줄번호> ...` 로 `REJECT` 앞에 끼워 넣는다
- `iptables-restore` 로 전체를 복원하면 `filter` 테이블이 flush 되어 k3s 가 만든 `KUBE-*` 체인이 사라진다. kube-proxy 가 곧 재작성하지만 그 사이 파드 통신이 끊길 수 있다
- 문법만 확인할 때는 `sudo iptables-restore --test /etc/iptables/rules.v4`
- `netfilter-persistent reload` 는 `--noflush` 로 덧붙여 옛 `REJECT` 가 앞에 남음, 부팅 시에는 빈 테이블에서 시작하므로 문제없음
- `FORWARD` 체인의 기본 `REJECT` 는 유지, k3s 네트워크 정책 컨트롤러가 로컬 파드 전달 트래픽을 `0x20000` 마크로 먼저 ACCEPT
- `--disable-network-policy` 사용 시에만 `-A FORWARD -s 10.42.0.0/16 -j ACCEPT`, `-A FORWARD -d 10.42.0.0/16 -j ACCEPT` 를 `REJECT` 위에 추가

## 7. OCI 네트워크

서브넷 공유 Security List 는 TCP 22(0.0.0.0/0)와 ICMP type 3 만 유지, 나머지는 전부 VNIC 별 NSG 로 개방

| NSG | 부착 | 규칙 |
|---|---|---|
| `k3s-nodes` | cp-1, worker-1, worker-2 | ingress: TCP 22 ← PC IP, UDP 8472 ← 10.0.0.0/16, TCP 10250 ← 10.0.0.0/16, TCP 9100 ← 10.0.0.0/16, TCP 80/443 ← NSG `k3s-lb`. egress: all |
| `k3s-control-plane` | cp-1 | ingress: TCP 6443 ← 10.0.0.0/16, TCP 6443 ← PC IP |
| `k3s-lb` | NLB `k3s-ingress` | ingress: TCP 80/443 ← 0.0.0.0/0 |
| `instance-server` | InstanceServer | ingress: TCP 80/443 ← 0.0.0.0/0 |

- Security List 와 NSG 는 둘 중 하나라도 허용하면 통과. 그래서 노드 80/443 을 좁히려면 Security List 에서 먼저 빼야 하고, 같은 서브넷의 InstanceServer 노출은 전용 NSG 로 옮겨 보존했다
- 인터넷 → NLB 는 `k3s-lb`, NLB → 노드는 `k3s-nodes` 가 담당. `k3s-lb` 에 ingress 를 넣지 않으면 NLB 자체가 인터넷에서 닿지 않는다
- 노드 80/443 의 source 는 CIDR 이 아니라 NSG `k3s-lb` 참조다. 트래픽과 헬스체크 프로브 모두 이 규칙으로 통과하는 것을 확인했으므로, NLB 를 재생성해 사설 IP 가 바뀌어도 규칙을 고칠 필요가 없다
- SSH 22 는 Security List 에 `0.0.0.0/0` 으로 남겨둔다. PC IP 가 바뀌어도 SSH 로 들어가 전부 고칠 수 있는 마지막 경로다
- 6443/8472/10250/9100 은 NSG 로만 개방, OS iptables(6절)가 두 번째 층
- 파드에서 다른 노드의 노드 IP 로 가는 트래픽은 목적지가 파드·서비스 CIDR 밖이라 노드 IP 로 SNAT 된다. 그래서 iptables 의 `10.42.0.0/16 ACCEPT` 에 걸리지 않고, NSG 와 OS iptables 를 둘 다 열어야 통한다
- NSG 차단은 조용한 timeout 이고, OS iptables 의 `REJECT --reject-with icmp-host-prohibited` 는 `no route to host` 를 돌려준다. 에러 문구로 어느 층이 막는지 구분할 수 있다

```bash
oci session authenticate --profile-name k3s --region ap-chuncheon-1
export OCI_CLI_PROFILE=k3s OCI_CLI_AUTH=security_token
oci network nsg list --compartment-id <tenancy OCID> --query 'data[].{name:"display-name",id:id}' --output table
oci network nsg rules list --nsg-id <nsg OCID> --all
```

### Network Load Balancer

`k3s-ingress`, public, 노드와 같은 서브넷, 공인 IP 는 ephemeral (`146.56.xxx.xxx`)

| 리소스 | 설정 |
|---|---|
| 리스너 `lsnr-http` | TCP 80 → `bs-http`, PPv2 끔 |
| 리스너 `lsnr-https` | TCP 443 → `bs-https`, PPv2 켬 |
| 백엔드셋 `bs-http` | 노드 사설 IP 3개 : 80, `is-preserve-source false` |
| 백엔드셋 `bs-https` | 노드 사설 IP 3개 : 443, `is-preserve-source false` |
| 헬스체크 (두 백엔드셋 공통) | HTTP, 포트 80, `/ping`, 기대 코드 200, 10초 간격, 타임아웃 3초, 재시도 3 |

- TLS 는 종료하지 않고 TCP 로 통과시킴, 인증서는 Traefik 이 다룸
- 노드 NSG 의 TCP 80/443 은 NLB 만 허용, 인터넷 → NLB 는 `k3s-lb` NSG 가 허용 (7절)
- 노드 추가·제거 시 백엔드셋 두 개를 모두 갱신
- 노드 443 을 NLB 로 좁혔기 때문에 외부에서 PROXY 헤더를 위조해 클라이언트 IP 를 속이는 경로가 없다. 다시 넓히면 그 경로가 열린다

```bash
NLB=<nlb OCID>
oci nlb backend-set-health get --network-load-balancer-id $NLB --backend-set-name bs-https
oci nlb listener list --network-load-balancer-id $NLB --query 'data.items[].{name:name,port:port,ppv2:"is-ppv2-enabled"}' --output table
curl -s --resolve <앱>.seol.pro:443:<LB 공인 IP> https://<앱>.seol.pro/
```

되돌리기: A 레코드를 노드 공인 IP 로 되돌리려면 `k3s-nodes` 에 TCP 80/443 ← `0.0.0.0/0` 을 먼저 다시 넣어야 함. PPv2 설정은 건드릴 필요 없음

## 8. 노드 추가 (worker-3)

1. 호스트네임 `worker-3`, `/etc/hosts` 에 노드 블록, `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` 에 `preserve_hostname: true`
2. 6절 방화벽 규칙(공통 6줄) 적용
3. `oci network vnic update --vnic-id <vnic> --nsg-ids '["<k3s-nodes OCID>"]'` 로 NSG `k3s-nodes` 부착
4. cp-1 에서 토큰 확인: `sudo cat /var/lib/rancher/k3s/server/node-token`
5. 2절 worker config.yaml 작성 후 조인
   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.3+k3s1 K3S_TOKEN='<token>' sh -s - agent
   ```
6. Cloudflare 토큰의 Client IP 필터에 새 노드 공인 IP 추가

## 9. 재부팅과 복구

k3s 는 systemd 서비스(`k3s`, 워커는 `k3s-agent`)로 재부팅 후 자동 기동

```bash
kubectl get nodes
kubectl -n argocd get applications
```

## 10. 모니터링

`victoria-metrics-k8s-stack` 으로 지표와 대시보드만 운영, 알림은 두지 않음

- VMSingle(시계열 저장)과 Grafana 를 `tier=data-b`(worker-2)에 고정, PVC 가 `local-path` 라 노드 로컬 디스크를 쓰므로 파드도 그 노드에 묶인다
- 보관 7일, scrape 15초, PVC 5Gi. 기본값(1개월·20s·20Gi)은 부하 감상 용도에 과하다
- 알림(Alertmanager·VMAlert·기본 룰)은 끔. 클러스터 안의 알림은 클러스터가 죽으면 나가지 않으므로 외부 감시로 따로 해결한다
- `kubeControllerManager`·`kubeScheduler`·`kubeEtcd` scrape 를 끔. k3s 는 두 컴포넌트를 server 프로세스에 통합했고 저장소는 sqlite 라 scrape 대상이 없다
- Grafana 는 초기 admin 생성을 끄고 익명 Admin 접근. 인증이 없으므로 Ingress 를 만들지 않고 port-forward 로만 접근한다
- Operator 의 검증 웹훅도 끔. Argo CD 는 helm 의 `lookup` 을 빈 값으로 렌더링해 sync 마다 admin 비밀번호와 웹훅 TLS 인증서가 새로 생성된다
- CRD 25개 중 가장 큰 것이 751KB 라 client-side apply 의 annotation 256KB 제한을 넘는다. Application 에 `ServerSideApply=true` 가 필요하다
- Grafana sidecar 의 `skipReload` 를 켠다. reload API 는 Org Admin 이 아니라 서버 관리자 권한을 요구해 익명 접근으로는 403 이 된다. 대시보드는 provisioning 폴더 스캔으로 로드되고, datasource 변경은 파드 재시작으로 반영한다
- node-exporter 는 `hostNetwork: true` 로 노드 IP 의 9100 에 붙는다. NSG 와 OS iptables 양쪽에 `9100 ← 10.0.0.0/16` 이 없으면 VMAgent 가 자기 노드만 수집한다(7절)
- 노드 CPU·메모리는 kubelet(10250) 경유로도 들어온다. node-exporter 는 디스크·파일시스템·네트워크 상세를 더한다

접근

```bash
kubectl -n monitoring port-forward svc/vm-grafana 3000:80   # http://localhost:3000
kubectl -n monitoring get vmsingle,vmagent
```

HPA 변화는 `kube_horizontalpodautoscaler_status_current_replicas` 와 `..._desired_replicas` 를 한 패널에 겹쳐 그리면 안정화 창 때문에 두 값이 벌어지는 구간이 보인다

직접 만든 대시보드는 Grafana 에 저장되지 않는다(`persistence` 끔). JSON 으로 내보내 레포에 커밋한다

되돌리기: `argocd/applications/infra-victoria-metrics.yaml` 삭제 후 push. `prune` 이 CRD 까지 지우므로 CR 도 함께 사라진다

## 11. 향후 확장

- DB, Redis: `apps/<앱>/` 에 StatefulSet + PVC(`storageClassName: local-path`) + `nodeSelector: {tier: data-a}` 로 노드 고정, 데이터는 그 노드의 `/var/lib/rancher/k3s/storage/` 에 저장
- CI/CD: 앱 레포지터리 GitHub Actions → GHCR push → 이 레포지터리 `apps/<앱>/kustomization.yaml` 의 `images[].newTag` 갱신 커밋 → Argo CD 자동 배포, 프라이빗 이미지는 `imagePullSecret` 을 SealedSecret 으로
