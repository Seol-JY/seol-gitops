# argocd/

- `root.yaml`: 루트 App of Apps, 클러스터 초기화 때 `kubectl apply -f argocd/root.yaml` 로 한 번만 등록
- `applications/`: 루트가 재귀 감시, Application 매니페스트 추가·수정·삭제 후 push 하면 반영
  - `infra-<이름>.yaml`: 인프라 컴포넌트 (`infra/<이름>/`)
  - `app-<이름>.yaml`: 앱 (`apps/<이름>/`, 규약은 `apps/README.md`)

sync-wave: `infra-argocd`(-10) → `infra-sealed-secrets`, `infra-cert-manager`(0) → `infra-cert-manager-issuers`(10) → 앱(기본 0)
