# First-Time Azure Deploy

Walkthrough for provisioning a brand-new Azure environment from a fresh subscription through to a running AKS cluster reconciled by ArgoCD against `aks-gitops`.

Assumes you have an Azure subscription and your sign-in account has Owner on it. If you don't, see [Account & Identity Setup](#account--identity-setup) first.

## Prerequisites

| Tool | Install | Why |
|---|---|---|
| Azure CLI | `brew install azure-cli` | sign-in, tenant ops, quota, RG creation |
| OpenTofu | `brew install opentofu` | resource provisioning |
| Terragrunt | `brew install terragrunt` | environment orchestration |
| kubelogin | `brew install Azure/kubelogin/kubelogin` | cluster-bootstrap needs it to authenticate to AKS via AAD |
| kubectl | `brew install kubectl` | post-deploy verification |
| Task | `brew install go-task/tap/go-task` | runs the Taskfile wrappers |

## Account & Identity Setup

If you signed up using a personal Microsoft account (gmail, outlook.com, hey.com, etc.), don't use it for admin work. The MSA-as-guest identity model produces constant friction (AADSTS16000, AADSTS50058, missing portal blades). Bootstrap a tenant-native admin user first.

### 1. Sign in scoped to your Azure tenant

```bash
az login --use-device-code --allow-no-subscriptions
az account tenant list -o table       # find your tenant ID — NOT the "Microsoft Services" one
az logout
az login --use-device-code --tenant <your-real-tenant-id>
az account show --query "{tenant:tenantId, subscription:id, user:user.name}" -o yaml
```

> **Tenant ID vs Subscription ID** — they're different things. Tenant ID identifies your Entra ID directory (where users live). Subscription ID identifies the billing container. Use `az account show --query tenantId -o tsv` to get the tenant ID specifically.

### 2. Create a tenant-native admin user

The signup MSA becomes your break-glass (last-resort recovery). All daily work goes through a new Entra ID user.

```bash
TENANT_DOMAIN=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/domains" \
  --query "value[?isInitial].id | [0]" -o tsv)
SUB_ID=$(az account show --query id -o tsv)
PASSWORD=$(openssl rand -base64 36)

echo "USERNAME: <yourname>-admin@$TENANT_DOMAIN"
echo "PASSWORD: $PASSWORD"
# Save both NOW (password manager). The password won't be shown again.

az ad user create \
  --display-name "<Your Name> Admin" \
  --user-principal-name "<yourname>-admin@$TENANT_DOMAIN" \
  --password "$PASSWORD" \
  --force-change-password-next-sign-in false

USER_ID=$(az ad user show --id "<yourname>-admin@$TENANT_DOMAIN" --query id -o tsv)

# Activate the Global Admin role (no-op if already active)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/directoryRoles" \
  --body '{"roleTemplateId":"62e90394-69f5-4237-9190-012177145e10"}' 2>/dev/null || true

GA_ROLE_ID=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/directoryRoles" \
  --query "value[?displayName=='Global Administrator'].id | [0]" -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/directoryRoles/$GA_ROLE_ID/members/\$ref" \
  --body "{\"@odata.id\":\"https://graph.microsoft.com/v1.0/directoryObjects/$USER_ID\"}"

az role assignment create \
  --assignee-object-id "$USER_ID" \
  --assignee-principal-type User \
  --role "Owner" \
  --scope "/subscriptions/$SUB_ID"
```

### 3. Switch to the new user and enroll MFA

```bash
az logout
az login --use-device-code --tenant <your-tenant-id>
# Sign in as <yourname>-admin@<tenant>.onmicrosoft.com
```

Enable Security Defaults in the portal: **entra.microsoft.com → Overview → Properties → Manage security defaults → Enabled**.

Enroll MFA at <https://aka.ms/mfasetup> using any TOTP app (Microsoft Authenticator, 1Password, Authy, Aegis — they all support the RFC 6238 standard). Repeat for the original signup account at <https://account.microsoft.com → Security → Two-step verification>; save the recovery code somewhere durable.

## Pre-Deploy Setup

### 4. Update `account.hcl`

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
echo "tenant: $TENANT_ID  subscription: $SUB_ID"
```

Edit `live/azure/workload-<env>/account.hcl` (where `<env>` is `dev`, `staging`, or `prod`):

```hcl
locals {
  subscription_id = "<your-subscription-id>"
  tenant_id       = "<your-tenant-id>"
  account_alias   = "workload-<env>"
}
```

### 5. Register Azure resource providers

```bash
for ns in Microsoft.ContainerService Microsoft.Network Microsoft.KeyVault Microsoft.Storage Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Authorization Microsoft.Monitor Microsoft.Dashboard Microsoft.AlertsManagement Microsoft.DBforPostgreSQL Microsoft.Insights; do echo "Registering $ns..."; az provider register --namespace $ns --wait; done
```

`--wait` blocks until each is fully Registered. Total ~5-8 min. Idempotent — re-run anytime.

### 6. Bootstrap the state backend

Creates `tfstate-rg` resource group + `tfstate<12char>` storage account + `tfstate` container. Idempotent.

```bash
SUB_ID=$(az account show --query id -o tsv)
./scripts/init-backend-azure.sh $SUB_ID westus2
```

### 7. Create the workload resource group

Components do `data "azurerm_resource_group"` lookups; the RG must exist before apply.

```bash
az group create --name <env> --location westus2
```

Where `<env>` is `dev`, `staging`, or `production` — matches the `env.hcl` `environment` value.

### 8. vCPU quota — file BEFORE applying cluster

Brand-new PAYG subscriptions default to **10 vCPU regional cap** in westus2. The system node pool alone is 12 vCPU (3× D4s_v5 for prod). Without raising the cap, `cluster` apply fails ~10 min in with `ErrCode_InsufficientVCPUQuota` *after* it's already created a Log Analytics workspace.

File the bump now:

**portal.azure.com → Quotas → Compute → westus2** → bump BOTH:
- `Total Regional vCPUs` → 100 (or 500 for headroom)
- `Standard DSv5 Family vCPUs` → 100

Auto-approved within 1-5 min on PAYG.

**Note:** `az vm list-usage --location westus2 -o table` returns `[]` empty for the first hour or so after a fresh subscription — usage counters haven't been initialized yet. Empty doesn't mean quota is fine; the 10-vCPU cap still applies. File the bump anyway.

### 9. Decide on public, private, or IP-restricted cluster

Three options for cluster API access:

| Setting | Result |
|---|---|
| `cluster_endpoint_public_access = true`, no allowlist | Fully public — anyone with AAD creds can hit it |
| `cluster_endpoint_public_access = true`, allowlist set | **Recommended** — public endpoint, only listed CIDRs allowed |
| `cluster_endpoint_public_access = false` | Fully private — laptop kubectl needs VPN/Bastion |

The IP allowlist is **not committed** in `terragrunt.hcl` — it's set per-shell via `TF_VAR_api_authorized_ip_ranges`. This keeps your home/office IP out of git.

```bash
# Get your IPv4 address (AKS doesn't accept IPv6 in allowlists)
MY_IP=$(curl -s -4 https://api.ipify.org)
echo "IP: $MY_IP"

# Export for the apply session
export TF_VAR_api_authorized_ip_ranges="[\"$MY_IP/32\"]"

# Apply with the allowlist in effect
task apply CLOUD=azure ACCOUNT=workload-prod REGION=westus2 ENVIRONMENT=production COMPONENT=cluster
```

**Notes:**

- **Home IPs rotate.** When the API stops responding from your laptop, refresh `TF_VAR_api_authorized_ip_ranges` and re-apply `cluster` (~2 min to update the allowlist; no cluster recreate).
- **IPv4 only.** AKS authorized IP ranges reject IPv6 CIDRs. Use `curl -4` or `api.ipify.org` (IPv4-only by default).
- **CI workers** that hit the cluster API also need to be in the allowlist (extend `TF_VAR_api_authorized_ip_ranges` to a JSON array of multiple CIDRs).
- **ArgoCD reconciliation is pull-based** from inside the cluster — doesn't need allowlist access. Only direct `kubectl` / `helm` / `argocd` CLI calls from outside need it.

## Deploy

The full deploy is six tofu applies, one wire-up script, one git push, and one smoke test. All the gotchas that historically broke first-time deploys are now baked into the components — `apply` succeeds first try on a clean Azure subscription.

```bash
cd <repo-root>
ENV=prod         # or dev / staging
ACCT=workload-prod   # or workload-dev / workload-staging

# Prereq: workload resource group must exist (the network component reads
# it but doesn't create it — keeps RG lifecycle out of state)
az group create --name $ENV --location westus2

# Pin your home IP into the API-server allowlist. `-4` forces IPv4
# (AKS rejects IPv6 in authorized_ip_ranges with a 400)
export TF_VAR_api_authorized_ip_ranges="[\"$(curl -4 -s ifconfig.me)/32\"]"

# Six applies, dependency order. ~25-35 min total on a fresh sub
for c in network cluster secrets cluster-bootstrap cluster-addons managed-monitoring; do
  task apply CLOUD=azure ACCOUNT=$ACCT REGION=westus2 ENVIRONMENT=$ENV COMPONENT=$c
done
```

If your Wi-Fi is flaky and any apply errors with `HTTP response was nil; connection may have been reset`, just re-run that one apply — tofu state is durable and the rerun picks up where it stopped. (See troubleshooting table for full diagnosis.)

### Get kubectl access (after `cluster` succeeds)

The cluster-bootstrap component talks to the apiserver, so this happens between `cluster` and `cluster-bootstrap`:

```bash
az aks get-credentials --resource-group $ENV --name $ENV-aks --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes   # 3 system nodes Ready
```

## Post-Deploy

### Wire landing-zone outputs into aks-gitops

The aks-gitops repo has placeholder client-IDs / storage-account names / AMW URLs in `addons/**/values-<env>.yaml`. `task wire` pulls every output that `cluster-addons` and `managed-monitoring` produced and patches them in-place:

```bash
cd ../aks-gitops
task wire -- azure $ACCT westus2 $ENV
git diff --stat        # eyeball the changes
git add -u && git commit -m "wire $ENV outputs into addon values" && git push
```

`task wire` is idempotent — safe to re-run after any landing-zone re-apply that rotates outputs (managed-monitoring's DCR `immutable_id` changes on replacement, for example).

### Bootstrap the Grafana service-account token (one-time per env)

The `dashboards` addon expects an Azure Managed Grafana SA token in Key Vault, surfaced as a Kubernetes Secret via External Secrets. Mint it once:

```bash
# Grant yourself Grafana Admin so you can create SAs against the AMG API
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Grafana Admin" \
  --scope $(cd ../landing-zone/live/azure/$ACCT/westus2/$ENV/managed-monitoring && terragrunt output -raw grafana_id)

# Wait ~60s for role propagation
sleep 60

# Mint the SA and token
GRAFANA_NAME=$(cd ../landing-zone/live/azure/$ACCT/westus2/$ENV/managed-monitoring && terragrunt output -raw grafana_name)
az grafana service-account create -g $ENV -n $GRAFANA_NAME --service-account aks-gitops --role Admin
TOKEN=$(az grafana service-account token create -g $ENV -n $GRAFANA_NAME \
  --service-account aks-gitops --token aks-gitops-token --time-to-live 1y \
  --query 'key' -o tsv)

# Self-grant KV Administrator (one-time)
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Key Vault Administrator" \
  --scope $(cd ../landing-zone/live/azure/$ACCT/westus2/$ENV/secrets && terragrunt output -raw key_vault_id)
sleep 30

# Land the token where the ExternalSecret expects it
VAULT_NAME=$(cd ../landing-zone/live/azure/$ACCT/westus2/$ENV/secrets && terragrunt output -raw key_vault_uri | sed 's|https://||; s|.vault.azure.net/||')
az keyvault secret set --vault-name $VAULT_NAME --name aks-grafana-token \
  --value "{\"token\":\"$TOKEN\"}"
```

### Verify

```bash
cd ../aks-gitops
task smoke
```

`task smoke` exercises 20 end-to-end checks: cluster health, Cilium readiness, CoreDNS, every ArgoCD Application Healthy, the full External Secrets → Key Vault chain (creates a probe ExternalSecret and verifies it reconciles), Loki + Tempo + grafana-agent pods Ready, grafana-agent remote-write to AMW with no recent errors, Karpenter NAP NodePools and worker provisioning, cert-manager Ready, ingress-nginx controller + external-dns Ready, Azure CLI auth.

A green run looks like:

```
── summary ──
  ●  20 passed   ●  0 failed   ●  0 skipped
```

`SKIP_DESTRUCTIVE=1 task smoke` skips the ExternalSecret probe (creates a test Secret in the cluster). `ENV=name task smoke` tags the output for log-grepping.

## Optional Add-Ons

`managed-monitoring` is part of the standard sequence above. These are the extras you can layer on once the base is stable:

```bash
# Druid analytics tenant (Postgres + storage, ~$40/day)
task apply CLOUD=azure ACCOUNT=$ACCT REGION=westus2 ENVIRONMENT=$ENV COMPONENT=druid-catalog-analytics

# DNS zone (if attaching ingress hostnames)
task apply CLOUD=azure ACCOUNT=$ACCT REGION=westus2 ENVIRONMENT=$ENV COMPONENT=dns
```

## Cost Reality

Approximate $/day at default sizes:

| Setting | Dev | Production |
|---|---|---|
| AKS control plane | $0 | $0 |
| System node pool | $5 (1× D4s_v5) | $14 (3× D4s_v5) |
| Karpenter-provisioned addons | $5-10 | $20-40 |
| NAT Gateway + Public IPs | $1.20 | $1.20 |
| Storage (PVCs + accounts) | $0.50 | $1.50 |
| Key Vault + DNS | $0.10 | $0.10 |
| **Baseline** | **~$12-17/day** | **~$37-57/day** |
| +Managed monitoring | +$3/day | +$5-8/day |
| +Druid | +$37/day | +$45/day |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS50058` | third-party cookie blocking on Microsoft login domains | Edge settings → cookies → allow `[*.]microsoftonline.com`, `[*.]microsoft.com`, `[*.]azure.com`. Or use private window. |
| `AADSTS16000` "User account from live.com does not exist in tenant" | MSA acting in wrong directory | Use tenant-scoped URL: `https://portal.azure.com/<tenant-id>`. Or sign in as tenant-native user. |
| `AADSTS90002 Tenant not found` | passed subscription ID instead of tenant ID to `--tenant` | `az account show --query tenantId -o tsv` to get the real tenant ID |
| `task init-backend` says `Usage:` | Taskfile not forwarding args | Run script directly: `./scripts/init-backend-azure.sh $SUB_ID westus2` |
| `terragrunt: Working dir components/azure/X does not exist` | envcommon source path bug | Fixed — `${dirname(find_in_parent_folders("cloud.hcl"))}/../../components/...` (note the `../..`) |
| `ErrCode_InsufficientVCPUQuota` during cluster apply | vCPU quota too low | portal → Quotas → Compute → westus2. Bump BOTH `Total Regional vCPUs` and the family for your VM size (`Standard Dsv6 Family vCPUs` for D-series v6). Re-apply. |
| `Standard DSv5 Family vCPUs` quota request requires business-justification form | DSv5 is being phased out — Microsoft sets default limit to 0 on new subs and gatekeeps increases | Switch the cluster to v6 (`system_node_vm_size = "Standard_D4s_v6"`). Bumping Dsv6 family quota is auto-approved up to 50+ vCPU. |
| `K8sVersionNotSupported ... only available for Long-Term Support (LTS)` | The K8s minor you requested has dropped out of Standard support and into LTS-only | Either bump to a current Standard-tier version (`az aks get-versions --location <region> -o table` to see options) OR set `sku_tier = "Premium"` + `support_plan = "AKSLongTermSupport"` (~$432/mo). |
| `OperationNotAllowed ... nodeProvisioningProfile.mode cannot be Auto unless all AgentPools have property .properties.enableAutoScaling set to one of [false]` | NAP and system-pool autoscaling are mutually exclusive | Set `system_node_count` (fixed) — variable name in this component is `system_node_count`, not min/max. |
| `ServiceCidrOverlapExistingSubnetsCidr` during cluster create | VNet CIDR and AKS default service CIDR both at 10.0.0.0/16 | Component pins `service_cidr = "10.96.0.0/16"` to avoid this. If you change `var.vnet_cidr` to a 10.x range, also audit `var.service_cidr` and aks-gitops cilium pod CIDR for collision. |
| `Output refers to sensitive values` on cluster outputs | azurerm provider v4+ marks `kube_config[*]` as sensitive | Outputs derived from `kube_config` must be marked `sensitive = true` in `outputs.tf`. |
| `StorageAccountAlreadyTaken` (any storage account) | Azure storage account names are globally unique | All names in this repo now suffix with subscription hash for uniqueness; rerun apply. |
| `VMExtensionError_K8SAPIServerConnFail` after ~13 min cluster create | API authorized IP allowlist set without including cluster egress IPs — nodes can't reach API server | Component now auto-merges `var.egress_public_ips` (NAT Gateway public IPs from network component) into the allowlist. Verify the cluster envcommon passes `egress_public_ips = dependency.network.outputs.nat_public_ips`. |
| `a resource with the ID ".../workspaces/<name>" already exists` after RG recreate | Log Analytics workspaces have a 14-day soft-delete window. Recreating an RG resurrects soft-deleted workspaces with the same name. | Either import into state (`terragrunt import azurerm_log_analytics_workspace.this <id>`) or purge with `az monitor log-analytics workspace delete --resource-group <rg> --workspace-name <name> --force true --yes`. |
| `VaultAlreadyExists ... vault in a recoverable state` after RG recreate | Key Vault has a 7-90 day soft-delete window. `purge_protection_enabled=true` *prevents force-purge* during that window. | Recover: `az keyvault recover --name <vault> --location <region>` then `terragrunt import azurerm_key_vault.this <id>`. For personal/portfolio envs, also set `purge_protection_enabled = false` in the env terragrunt — but this only takes effect on *new* vaults; once set true on a vault, it's immutable. |
| `VaultAlreadyExists` but `az keyvault show` returns `ResourceNotFound` AND `az keyvault list-deleted` is empty | Key Vault names are globally unique across all Azure tenants — another tenant grabbed `<rg>secrets` (or Azure metadata is stale). | Component already suffixes the vault name with a subscription-hash slice and truncates to 24 chars (`substr("${rg}secrets${sub_id_no_dashes}", 0, 24)`). If you ever hit this on a brand-new RG name, that suffix is what saves you. |
| `zsh: command not found: kubelogin` after `brew install kubelogin` | Homebrew's main `kubelogin` formula is the int128 OIDC tool (installs as `kubectl-oidc_login`), NOT Microsoft's AKS-specific kubelogin | `brew uninstall kubelogin && brew install Azure/kubelogin/kubelogin` (Microsoft's tap). Or `az aks install-cli --install-location ~/.azure-kubelogin/bin/kubectl --kubelogin-install-location ~/.azure-kubelogin/bin/kubelogin` then add that bin to PATH. |
| `Unreadable module directory ... ../../../modules: no such file or directory` during terragrunt init | Component references `../../../modules/<cloud>/workload-identity` but terragrunt only copies the component dir to its cache, breaking the relative path | Use `//` separator in the envcommon source to copy the full repo: change `source = ".../components/azure/<name>"` to `source = ".../..//components/azure/<name>"`. Terragrunt copies the whole repo to cache (including `modules/`), runs from the working dir after `//`. Required for any component that references the shared `modules/` tree. |
| `cluster-bootstrap` hangs talking to API server | private cluster + no VPN/Bastion | Flip `cluster_endpoint_public_access = true` in cluster terragrunt; re-apply cluster |
| `cluster-bootstrap` apply fails with `no matches for kind "AppProject" in group "argoproj.io"` (or any CRD not yet installed) | The `hashicorp/kubernetes` provider's `kubernetes_manifest` resource validates CRD schemas at *plan* time. On a fresh cluster the ArgoCD / External Secrets / Kyverno CRDs don't exist until their Helm releases apply, so plan fails before they can be installed. | Component now uses `gavinbunney/kubectl`'s `kubectl_manifest` for all custom-resource bootstrapping (AppProject, ClusterSecretStore, Application). That provider defers schema lookup until apply time, so the same plan can install a CRD and an instance of it in one run. |
| `cluster-bootstrap` apply fails with `secrets is forbidden: User <oid> cannot list resource "secrets" ... User does not have access to the resource in Azure` | AKS uses **Azure RBAC for Kubernetes Authorization** — an Azure-plane role (Owner, Contributor on the cluster resource) does NOT grant Kubernetes-API access. A separate role assignment on the cluster scope is required for `kubectl`/`helm`/anything talking to kube-apiserver. | The cluster component now grants `Azure Kubernetes Service RBAC Cluster Admin` to `data.azurerm_client_config.current.object_id` on the cluster scope automatically (see `azurerm_role_assignment.deployer_cluster_admin` in `components/azure/cluster/main.tf`). If you ever apply cluster-bootstrap with a different identity than the one that created the cluster, manually grant: `az role assignment create --assignee $(az ad signed-in-user show --query id -o tsv) --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $(az aks show -g <rg> -n <cluster-name> --query id -o tsv)`. |
| Cilium operator `CrashLoopBackOff`, agents `Running 0/1`, coredns and others stuck `ContainerCreating`, then Helm release errors with `context deadline exceeded` | `ipam.mode = "delegated-plugin"` is for Azure CNI Powered by Cilium (managed AKS feature where Azure CNS allocates pod IPs). On pure BYOCNI (`network_plugin=none` + Helm-installed Cilium), Cilium owns IPAM end-to-end and needs `ipam.mode = "cluster-pool"` plus a `clusterPoolIPv4PodCIDRList`. Mismatch causes operator's IP-allocator loop to fail, agents never go Ready, and downstream pods never get a pod IP. | Component now sets `ipam.mode = "cluster-pool"` with `clusterPoolIPv4PodCIDRList = [var.pod_cidr]` (default `10.244.0.0/16`, `/24` per node). Also bumped Helm `timeout` from default 5m to 15m — fresh BYOCNI bring-up serializes node-Ready → operator leader election → IPAM init → Hubble rollout, which is tight in 5m. |
| ArgoCD Helm release errors with `failed pre-install: timed out waiting for the condition` and `argocd-redis-secret-init` pod sits Pending | At ArgoCD-install time the only nodes are the AKS system pool, which has the `CriticalAddonsOnly:NoSchedule` taint. NAP worker nodes don't exist yet because the NodePool/AKSNodeClass CRs ship from aks-gitops — which can't reconcile until ArgoCD is running. Cilium got past this because its DaemonSet auto-tolerates everything; ArgoCD's chart doesn't. | Set `global.tolerations` on the ArgoCD Helm release to tolerate `CriticalAddonsOnly:Exists`. `global` cascades to every workload + pre-install Hook the chart deploys. This is the **bootstrap toleration** — once NAP is online with worker nodes, ArgoCD will reschedule onto workers because controllers prefer untainted nodes, but the toleration stays present in case the cluster ever shrinks back to system-only. |
| `kubectl_manifest.azure_key_vault_secret_store` fails with `resource [external-secrets.io/v1/ClusterSecretStore] isn't valid for cluster, check the APIVersion and Kind fields are valid` | The `ClusterSecretStore` CRD is installed by the External Secrets Helm chart, which is itself installed by ArgoCD reconciling aks-gitops. At the moment cluster-bootstrap tries to create the CR, ArgoCD has only just started — external-secrets isn't installed yet, the CRD doesn't exist, the apply blows up. Tofu can't usefully `wait_for` a CRD that comes from a gitops loop it doesn't observe. | Move the ClusterSecretStore to aks-gitops where ArgoCD owns the sequencing. The repo now has `addons/bootstrap/external-secrets-stores/` (Kustomize) wired into `applicationsets/addons-bootstrap-kustomize.yaml` at sync wave 1, so it lands after external-secrets (wave 0) but before any consumer (wave ≥ 2). Update the env overlay (`overlays/<env>/kustomization.yaml`) with the actual `key_vault_uri` and `tenant_id` once the secrets component is applied — these are stable per env. **Rule of thumb:** any CR whose CRD is installed by Helm-via-ArgoCD belongs in aks-gitops, not in cluster-bootstrap. |
| `managed-monitoring` apply fails with `creating Grafana ... ZoneRedundancyNotSupported: Zone redundancy is currently not supported in this region: westus2.` | Azure Managed Grafana zone redundancy is gated by region capability, not by the resource tier. The supported list lags new regions and currently covers eastus / eastus2 / westus3 / southcentralus / northeurope / uksouth / francecentral / koreacentral / eastasia / centralindia / canadacentral / norwayeast / australiaeast. westus2 is NOT on the list. | Set `grafana_zone_redundancy_enabled = false` in `live/azure/<account>/<region>/<env>/managed-monitoring/terragrunt.hcl` for any region outside that list. The variable defaults to `false` at the component level; the prod env was opting in explicitly. Keep it `true` only when the region appears in Microsoft's supported list (verify on the day of deploy — the list grows). |
| Many ArgoCD Applications stuck `sync=Unknown` with `Failed to compare desired state to live state: ... error building typed value from live resource: .status.terminatingReplicas: field not declared in schema` | Kubernetes 1.34 added a `terminatingReplicas` field to Deployment/StatefulSet status. ArgoCD's bundled structured-merge-diff library doesn't know that field and aborts comparison. Per-app `syncOptions: [ServerSideDiff=true]` is silently ignored on ArgoCD 2.13.x — the only setting that flips the controller to server-side comparison is the `controller.diff.server.side.enabled=true` key in `argocd-cmd-params-cm`. | The `cluster-bootstrap` ArgoCD Helm release now sets `configs.params.controller.diff.server.side.enabled=true` so server-side diff is on cluster-wide. Apply lands the new value into `argocd-cmd-params-cm` and the chart's StatefulSet rolls the controller, picking up the setting. After that, the stuck Applications reconcile on their next refresh. |
| ArgoCD Applications stuck `sync=Unknown` with `helm template ... Error: values don't meet the specifications of the schema(s)` — `Additional property clusterName is not allowed` | Helm-flavored ApplicationSets in aks-gitops were injecting `clusterName` and `vnetName` via `spec.source.helm.parameters`. Most upstream charts publish a strict `values.schema.json` that rejects unknown top-level keys, and almost no addon in the repo actually consumes those parameters — they were a global convenience injection. | The `helm.parameters` block was removed from all 6 Helm ApplicationSets in `aks-gitops/applicationsets/`. The cluster identity values (cluster name, VNet name) are available to addons that need them via the `cluster-config` ConfigMap synced into the argocd namespace by `environments/<env>/cluster-config.yaml`. Charts that need the cluster name in generated resource names hardcode it in their `values-<env>.yaml`. |
| 31 of 32 ArgoCD Applications stuck `sync=Unknown` with `failed to execute helm template command: Error: open .../addons/<x>/values-prod.yaml: no such file or directory` after env rename | ApplicationSets build per-env paths from the cluster-secret label: `values-{{ .metadata.labels.environment }}.yaml`. Renaming `env.hcl::environment` from `production` to `prod` rotates that label, but addon files in aks-gitops still named `values-production.yaml` are no longer reachable. | Keep `aks-gitops/addons/**/values-<env>.yaml` filenames and `*/overlays/<env>/` directory names in lockstep with `env.hcl::environment`. The repo now uses `prod` throughout; if you ever flip the env name back to `production`, rename matching artifacts in the same commit. |
| `cluster` apply fails with `api_server_access_profile.0.authorized_ip_ranges.N must start with IPV4 address and/or slash, number of bits (0-32) as prefix. Example: 127.0.0.1/8. Got "2600:...:.../32"` | AKS's authorized IP allowlist accepts IPv4 CIDRs only. `curl ifconfig.me` on a dual-stack Mac (most modern setups) prefers IPv6 and returns a v6 address, which then gets baked into `TF_VAR_api_authorized_ip_ranges` as `<v6-addr>/32`. | Two fixes — both are in. (a) Always force IPv4 when discovering your home IP: `export TF_VAR_api_authorized_ip_ranges="[\"$(curl -4 -s ifconfig.me)/32\"]"` (note the `-4`). (b) The cluster component now filters non-IPv4 entries out of the final allowlist (any CIDR containing `:` is dropped), so a stray IPv6 silently degrades rather than blowing up the apply. |
| ArgoCD apps stuck in `OutOfSync` with "repository not accessible" | aks-gitops URL wrong or repo private without creds | Verify https://github.com/stxkxs/aks-gitops loads anonymously |
| `kubectl get nodes` returns 0 after `cluster` apply | NAP not configured | `az aks show -g <env> -n <env>-aks --query nodeProvisioningProfile` — should show `mode: Auto` |
| Addon pods stuck Pending | Karpenter NAP not provisioning | `kubectl get nodepool && kubectl describe nodepool default` |
