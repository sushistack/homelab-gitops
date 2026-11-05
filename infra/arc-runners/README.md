# arc-runners (vignal)

Synced as source 2 of `argocd/apps/arc-runners-vignal.yaml`: only `sealedsecret.yaml` (Secret `arc-github`).

Credential: a GitHub App (preferred: no expiry) or a fine-grained PAT -- see the header of `seal.sh`.

Rotate / first time:
1. GitHub -> Settings -> Developer settings -> Fine-grained tokens: repository `sushistack/vignal` only,
   permissions **Administration: Read and write** (runner registration) and Metadata: Read.
2. `echo GITHUB_TOKEN=github_pat_... > infra/arc-runners/arc-github.env` (git-ignored), then `./infra/arc-runners/seal.sh`.
3. Commit `sealedsecret.yaml` only. Delete `arc-github.env`.
