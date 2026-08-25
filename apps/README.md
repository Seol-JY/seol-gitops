# apps/

앱별 매니페스트 디렉터리, 현재 비어 있음

## 앱 추가 규약

1. 디렉터리 하나가 앱 하나, `apps/<앱>/` 아래에 `kustomization.yaml` 과 매니페스트 위치
2. 네임스페이스는 앱 이름과 같게 만들고 `namespace.yaml` 을 디렉터리에 포함
3. 시크릿은 SealedSecret(`*.sealedsecret.yaml`)만 커밋, 평문은 `*.plain.yaml` 로 두면 `.gitignore` 가 차단
4. 프라이빗 GHCR 이미지는 `imagePullSecret` 도 SealedSecret 으로 생성
5. Ingress 의 `tls:` 에는 `secretName` 생략, Traefik 기본 TLSStore 가 `*.seol.pro` 와일드카드 인증서 사용
6. DNS 는 Cloudflare 에 앱별 A 레코드(DNS only) 수동 추가, 와일드카드 DNS 레코드는 생성 금지
7. 영속 데이터(DB, Redis)는 PVC(StorageClass `local-path`) + `nodeSelector: { tier: data-a | data-b }` 로 노드 고정
8. `argocd/applications/app-<앱>.yaml` 에 Application 추가 후 push, 루트 App of Apps 가 자동 반영

```yaml
# argocd/applications/app-<앱>.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <앱>
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/Seol-JY/seol-gitops.git
    targetRevision: main
    path: apps/<앱>
  destination:
    server: https://kubernetes.default.svc
    namespace: <앱>
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## CI/CD

앱 레포지터리 GitHub Actions → GHCR push → 이 레포지터리 `apps/<앱>/kustomization.yaml` 의 `images[].newTag` 갱신 커밋 → Argo CD 배포, CI 토큰은 GitHub Actions Secrets 에만 보관
