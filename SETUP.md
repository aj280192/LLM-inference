# Quick Setup

**NOTE: the pipeline file is `.gitlab-ci.yml` (starts with a DOT — enable
"show hidden files" in your file explorer). `gitlab-ci.yml.REFERENCE-COPY.yml`
is an identical visible copy for reading only; GitLab uses the dotted one.**

Order:
1. `vault/vault_setup.sh` (vault admin)
2. `scripts/setup_build_host.sh` (root on build host) — copy printed SSH pubkey
3. `scripts/setup_poc_host.sh` (root on POC host) — paste pubkey + vault creds;
   ALSO copies `lib/log.sh` -> `/opt/chatapp/lib/log.sh` (needed by deploy_local.sh)
4. GitLab CI/CD variables per header of `.gitlab-ci.yml` (protected vs not!)
5. Create `chatapp-releases` repo, service account gets push access
6. Protect `main`, enable squash merge + delete branch on merge
7. Push a feature branch, open MR, watch the pipeline, press play on deploy-poc

Full details: README.md
