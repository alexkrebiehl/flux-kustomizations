# Proxmox Prometheus Exporter

This component deploys the prometheus-pve-exporter to collect metrics from Proxmox VE and expose them to Prometheus. It includes a Grafana dashboard for visualization.

## Components

- **ExternalSecret**: Fetches Proxmox API credentials from Azure Key Vault
- **Deployment**: Runs the prompve/prometheus-pve-exporter:v3.8.0 container
- **Service**: Exposes the metrics endpoint on port 9221
- **ServiceMonitor**: Configures Prometheus to scrape the exporter
- **Dashboard ConfigMap**: Provides Grafana dashboard (ID 10347)

## Prerequisites

### 1. Create Proxmox API Token

In Proxmox VE web interface:

1. Navigate to **Datacenter → Permissions → API Tokens**
2. Click **Add** to create a new token:
   - **User**: Create or select a user (e.g., `prometheus@pve`)
   - **Token ID**: `monitoring`
   - **Privilege Separation**: Enabled (recommended)
3. Assign the **PVEAuditor** role to the user:
   - Navigate to **Datacenter → Permissions**
   - Add permission: User `prometheus@pve`, Role `PVEAuditor`, Path `/`
4. Copy the token value (shown only once)

### 2. Store Credentials in Azure Key Vault

Store the following secrets in your Azure Key Vault:

```bash
# User (format: username@realm)
az keyvault secret set \
  --vault-name <your-vault> \
  --name proxmox-api-token-prom-exporter-user \
  --value "prometheus@pve"

# Token name (the ID you created)
az keyvault secret set \
  --vault-name <your-vault> \
  --name proxmox-api-token-prom-exporter-token-name \
  --value "monitoring"

# Token value (the secret shown when created)
az keyvault secret set \
  --vault-name <your-vault> \
  --name proxmox-api-token-prom-exporter-token-value \
  --value "<your-token-value>"
```

### 3. Verify API Access

Test the API token works correctly:

```bash
# Replace with your actual values
USER="prometheus@pve"
TOKEN_NAME="monitoring"
TOKEN_VALUE="<your-token-value>"

curl -k -H "Authorization: PVEAPIToken=${USER}!${TOKEN_NAME}=${TOKEN_VALUE}" \
  https://pve.krebiehl.com:8006/api2/json/version
```

Expected response: JSON with Proxmox version information.

## Configuration

### Target Configuration

The exporter is configured to scrape `pve.krebiehl.com`. To change the target:

1. Edit `servicemonitor.yaml`:
   ```yaml
   params:
     target:
       - your-proxmox-host.com  # Change this
   ```

2. Update the deployment health probes if needed

### Resource Limits

Default resource allocation:
- Requests: 50m CPU, 64Mi memory
- Limits: 200m CPU, 128Mi memory

Adjust in `deployment.yaml` if needed for larger clusters.

### Scrape Interval

Default: 60 seconds (matches kube-prometheus-stack settings)

To change, edit `servicemonitor.yaml`:
```yaml
endpoints:
  - interval: 30s  # Change this
```

## Verification

### 1. Check Pod Status

```bash
kubectl get pods -n monitoring -l app=prometheus-pve-exporter
kubectl logs -n monitoring -l app=prometheus-pve-exporter
```

Expected: Pod running, logs showing successful connection to Proxmox.

### 2. Test Metrics Endpoint

```bash
kubectl port-forward -n monitoring svc/prometheus-pve-exporter 9221:9221
curl http://localhost:9221/pve?target=pve.krebiehl.com&module=default
```

Expected: Prometheus metrics output with `pve_*` metrics.

### 3. Verify Prometheus Target

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Access http://localhost:9090/targets and verify:
- Target `prometheus-pve-exporter` is present and UP
- No scrape errors

### 4. Check Grafana Dashboard

```bash
kubectl get configmap -n monitoring proxmox-dashboard
```

Expected: ConfigMap with label `grafana_dashboard: "1"`

Access Grafana and verify:
- Dashboard "Proxmox via Prometheus" appears in General folder
- Select instance `pve.krebiehl.com` from dropdown
- Panels show data (CPU, memory, storage, guests)

### 5. Verify External Secret

```bash
kubectl get externalsecret -n monitoring proxmox-credentials
kubectl describe externalsecret -n monitoring proxmox-credentials
```

Expected: Status shows `SecretSynced` condition is True.

## Troubleshooting

### Pod Not Starting

Check secret exists and has correct keys:
```bash
kubectl get secret -n monitoring proxmox-credentials
kubectl get secret -n monitoring proxmox-credentials -o yaml
```

Expected keys: `PVE_USER`, `PVE_TOKEN_NAME`, `PVE_TOKEN_VALUE`

### No Metrics / Authentication Error

Check logs for API errors:
```bash
kubectl logs -n monitoring -l app=prometheus-pve-exporter
```

Common issues:
- Token expired or revoked in Proxmox
- Incorrect user/token format
- Missing PVEAuditor role assignment

### Dashboard Not Appearing in Grafana

1. Check ConfigMap exists and has correct label:
   ```bash
   kubectl get configmap -n monitoring proxmox-dashboard -o yaml | grep grafana_dashboard
   ```

2. Check Grafana sidecar logs:
   ```bash
   kubectl logs -n monitoring deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard
   ```

3. Verify sidecar configuration in HelmRelease allows cross-namespace discovery

### Prometheus Not Scraping

1. Check ServiceMonitor exists:
   ```bash
   kubectl get servicemonitor -n monitoring prometheus-pve-exporter
   ```

2. Check Prometheus operator logs:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator
   ```

3. Verify service endpoint:
   ```bash
   kubectl get endpoints -n monitoring prometheus-pve-exporter
   ```

## Metrics Exposed

Key metrics available:

- `pve_up` - VM/container status (1=running, 0=stopped)
- `pve_cpu_usage_ratio` - CPU usage
- `pve_cpu_usage_limit` - Allocated CPU cores
- `pve_memory_usage_bytes` - Memory usage
- `pve_memory_size_bytes` - Allocated memory
- `pve_disk_usage_bytes` - Disk usage
- `pve_disk_size_bytes` - Allocated disk
- `pve_network_receive_bytes` - Network received
- `pve_network_transmit_bytes` - Network transmitted
- `pve_guest_info` - Guest metadata (name, type)
- `pve_node_info` - Node information
- `pve_storage_info` - Storage information

## References

- [prometheus-pve-exporter GitHub](https://github.com/prometheus-pve/prometheus-pve-exporter)
- [Grafana Dashboard 10347](https://grafana.com/grafana/dashboards/10347)
- [Proxmox VE API Documentation](https://pve.proxmox.com/pve-docs/api-viewer/)
