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

앱 노출 순서: Cloudflare 에 `<앱>.seol.pro` A 레코드(DNS only) → cp-1 공인 IP → Ingress 커밋

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
-A INPUT -s 10.42.0.0/16 -j ACCEPT
-A INPUT -s 10.43.0.0/16 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT
# k3s (end)
```

- 적용은 `sudo iptables-restore < /etc/iptables/rules.v4`
- `netfilter-persistent reload` 는 `--noflush` 로 덧붙여 옛 `REJECT` 가 앞에 남음, 부팅 시에는 빈 테이블에서 시작하므로 문제없음
- `FORWARD` 체인의 기본 `REJECT` 는 유지, k3s 네트워크 정책 컨트롤러가 로컬 파드 전달 트래픽을 `0x20000` 마크로 먼저 ACCEPT
- `--disable-network-policy` 사용 시에만 `-A FORWARD -s 10.42.0.0/16 -j ACCEPT`, `-A FORWARD -d 10.42.0.0/16 -j ACCEPT` 를 `REJECT` 위에 추가

## 7. OCI 네트워크

서브넷 공유 Security List 는 TCP 22/80/443(0.0.0.0/0)과 ICMP type 3 만 유지, k3s 전용 포트는 노드 VNIC 의 NSG 두 개로 개방

| NSG | 부착 | 규칙 |
|---|---|---|
| `k3s-nodes` | cp-1, worker-1, worker-2 | ingress: TCP 22 ← PC IP, UDP 8472 ← 10.0.0.0/16, TCP 10250 ← 10.0.0.0/16, TCP 80/443 ← 0.0.0.0/0. egress: all |
| `k3s-control-plane` | cp-1 | ingress: TCP 6443 ← 10.0.0.0/16, TCP 6443 ← PC IP |

- Security List 와 NSG 는 둘 중 하나라도 허용하면 통과
- 6443/8472/10250 은 NSG 로만 개방, OS iptables(6절)가 두 번째 층
- 같은 서브넷의 다른 인스턴스는 Security List 의 22/80/443 만 적용

```bash
oci session authenticate --profile-name k3s --region ap-chuncheon-1
export OCI_CLI_PROFILE=k3s OCI_CLI_AUTH=security_token
oci network nsg list --compartment-id <tenancy OCID> --query 'data[].{name:"display-name",id:id}' --output table
oci network nsg rules list --nsg-id <nsg OCID> --all
```

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

## 10. 향후 확장

- DB, Redis: `apps/<앱>/` 에 StatefulSet + PVC(`storageClassName: local-path`) + `nodeSelector: {tier: data-a}` 로 노드 고정, 데이터는 그 노드의 `/var/lib/rancher/k3s/storage/` 에 저장
- CI/CD: 앱 레포지터리 GitHub Actions → GHCR push → 이 레포지터리 `apps/<앱>/kustomization.yaml` 의 `images[].newTag` 갱신 커밋 → Argo CD 자동 배포, 프라이빗 이미지는 `imagePullSecret` 을 SealedSecret 으로
