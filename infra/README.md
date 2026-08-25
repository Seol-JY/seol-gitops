# infra/

클러스터 공통 인프라 컴포넌트, 각 디렉터리는 `argocd/applications/infra-<이름>.yaml` 이 참조

| 디렉터리 | 내용 | 배포 방식 |
|---|---|---|
| `argocd/` | Argo CD (비HA, cp-1 고정, dex·notifications 제거) | kustomize (upstream install.yaml + 패치) |
| `sealed-secrets/` | Sealed Secrets 컨트롤러 values | Helm 차트 + values (multi-source) |
| `cert-manager/` | cert-manager values | Helm 차트 + values (multi-source) |
| `cert-manager-issuers/` | Let's Encrypt ClusterIssuer, `*.seol.pro` 와일드카드 Certificate, Traefik 기본 TLSStore, Cloudflare 토큰 SealedSecret | kustomize |

버전 변경: Application 의 `targetRevision`(차트 버전) 또는 `infra/argocd/kustomization.yaml` 의 URL 태그 수정 후 push
