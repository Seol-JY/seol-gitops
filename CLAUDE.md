# CLAUDE.md

k3s 클러스터를 Argo CD 로 운영하는 GitOps 레포지터리, 문서와 커밋 메시지는 한국어

## 구조

- `argocd/root.yaml`: 루트 App of Apps, 클러스터에 한 번만 수동 등록, `argocd/applications/` 재귀 감시
- `argocd/applications/`: `infra-<이름>.yaml`, `app-<이름>.yaml`
- `infra/<컴포넌트>/`: Helm values(`values.yaml`) 또는 kustomize
- `apps/<앱>/`: 앱 kustomize 디렉터리, 네임스페이스는 앱 이름과 동일
- `docs/runbook.md`: 운영 절차

## 규칙

- 커밋과 푸시는 사용자가 검토 후 직접 수행, 파일 준비와 제안 커밋 메시지까지만
- 커밋 메시지는 `type(scope): 설명` 한 줄 한국어, type 은 feat/fix/chore/docs/refactor, scope 는 argocd/infra/apps/docs 또는 컴포넌트명 (예: `feat(infra): cert-manager 추가`)
- 시크릿은 SealedSecret(`*.sealedsecret.yaml`)만 커밋, 평문 `kind: Secret`·토큰·키·kubeconfig 는 어떤 파일에도 저장 금지
- 매니페스트 주석은 비자명한 설정에 한 줄만, 설명은 README 와 docs 에 기재
- 문서의 IP·OCID 같은 식별 정보는 일부 마스킹
- 버전은 명시적으로 고정 (`targetRevision`, install.yaml 태그)
- 파괴적 작업(방화벽, 삭제, 재부팅, 노드 변경)은 실행 전 사용자 확인

## 검증

```bash
kubectl kustomize infra/argocd >/dev/null
kubectl kustomize infra/cert-manager-issuers >/dev/null
kubectl kustomize infra/traefik >/dev/null
gitleaks dir . --redact
pre-commit run --all-files
```
