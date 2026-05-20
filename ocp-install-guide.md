# Deploying Grafana with Resource Consumption Dashboards on OpenShift

Deploy a Grafana instance with OpenShift OAuth authentication and pre-built dashboards for analyzing Kubernetes workload resource consumption (CPU/memory usage, requests/limits, rightsizing recommendations).

## Prerequisites

- OpenShift 4.x cluster with `cluster-admin` access
- `oc` or `kubectl` CLI configured with kubeconfig
- Cluster monitoring stack enabled (default on OpenShift)
- A default StorageClass available for Grafana persistence

## Architecture

```
Browser
  │
  ▼ (HTTPS)
Route (reencrypt TLS)
  │
  ▼
oauth-proxy (:8443)  ──► OpenShift OAuth Server
  │
  ▼ (HTTP, X-Forwarded-User header)
Grafana (:3000)
  │
  ▼ (HTTPS, Bearer token)
Thanos Querier (:9091, openshift-monitoring)
```

Grafana runs as a sidecar alongside `oauth-proxy`. The proxy handles OpenShift authentication and passes the authenticated user identity to Grafana via the `X-Forwarded-User` header. Grafana queries metrics from the cluster's Thanos Querier using a ServiceAccount token with `cluster-monitoring-view` permissions.

## Variables

Set these for your environment before starting:

```bash
export NAMESPACE="grafana"
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export GRAFANA_HOST="grafana-${NAMESPACE}.${CLUSTER_DOMAIN}"
```

## Step 1 — Clone the dashboard repository

```bash
git clone https://github.com/satand/deployment-resource-consumption-grafana-dashboard.git
```

## Step 2 — Create namespace and install the Grafana Operator

```bash
oc new-project ${NAMESPACE} || oc project ${NAMESPACE}
```

Install the Grafana Operator from OperatorHub (community-operators, channel v5):

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-og
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
    - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: ${NAMESPACE}
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the operator to be ready:

```bash
oc wait csv -n ${NAMESPACE} -l operators.coreos.com/grafana-operator.${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 3 — Create ServiceAccounts and RBAC

Create two ServiceAccounts:
- **grafana-sa**: used by the Grafana datasource to query Thanos Querier (bound to `cluster-monitoring-view`)
- **grafana-proxy**: used by the oauth-proxy sidecar to handle OpenShift OAuth (annotated with the OAuth redirect URI)

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-sa
  namespace: ${NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-proxy
  namespace: ${NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirecturi.grafana: https://${GRAFANA_HOST}/oauth/callback
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-cluster-monitoring-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: grafana-sa
    namespace: ${NAMESPACE}
EOF
```

Create a long-lived token Secret for the datasource (auto-populated by the token controller):

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: grafana-sa
type: kubernetes.io/service-account-token
EOF
```

## Step 4 — Create the oauth-proxy Service

Create a dedicated Service for the oauth-proxy sidecar. The `serving-cert-secret-name` annotation makes OpenShift auto-generate a TLS certificate for the proxy:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: grafana-proxy-service
  namespace: ${NAMESPACE}
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: grafana-proxy-tls
spec:
  selector:
    app: grafana
  ports:
    - name: proxy
      port: 8443
      targetPort: 8443
      protocol: TCP
EOF
```

Wait for the TLS secret to be generated:

```bash
oc wait secret grafana-proxy-tls -n ${NAMESPACE} --for=jsonpath='{.type}'=kubernetes.io/tls --timeout=30s
```

## Step 5 — Create persistent storage

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

## Step 6 — Deploy Grafana with oauth-proxy sidecar

Generate a random cookie secret for the oauth-proxy session encryption:

```bash
COOKIE_SECRET=$(openssl rand -base64 32)
```

Deploy the Grafana instance. The CR configures:
- **auth.proxy**: trusts `X-Forwarded-User` header from the oauth-proxy sidecar
- **oauth-proxy sidecar**: handles OpenShift OAuth, proxies to Grafana on localhost:3000
- **Persistent storage**: SQLite database survives pod restarts
- **Route**: TLS reencrypt through the oauth-proxy service

```bash
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: ${NAMESPACE}
  labels:
    dashboards: grafana
spec:
  route:
    spec:
      host: ${GRAFANA_HOST}
      port:
        targetPort: proxy
      tls:
        termination: reencrypt
        insecureEdgeTerminationPolicy: Redirect
      to:
        kind: Service
        name: grafana-proxy-service
  config:
    log:
      mode: console
    server:
      root_url: https://${GRAFANA_HOST}
    security:
      admin_user: admin
      admin_password: admin
    auth:
      disable_login_form: "true"
      disable_signout_menu: "true"
    auth.proxy:
      enabled: "true"
      header_name: X-Forwarded-User
      header_property: username
      auto_sign_up: "true"
      enable_login_token: "false"
    users:
      auto_assign_org_role: Admin
  deployment:
    spec:
      template:
        spec:
          serviceAccountName: grafana-proxy
          containers:
            - name: grafana
              volumeMounts:
                - name: grafana-data
                  mountPath: /var/lib/grafana
            - name: oauth-proxy
              image: registry.redhat.io/openshift4/ose-oauth-proxy-rhel9:v4.17
              args:
                - --https-address=:8443
                - --provider=openshift
                - --openshift-service-account=grafana-proxy
                - --upstream=http://localhost:3000
                - --tls-cert=/etc/tls/private/tls.crt
                - --tls-key=/etc/tls/private/tls.key
                - --cookie-secret=${COOKIE_SECRET}
                - --pass-user-headers=true
                - --pass-basic-auth=false
                - --pass-access-token=false
              ports:
                - containerPort: 8443
                  name: proxy
                  protocol: TCP
              volumeMounts:
                - name: proxy-tls
                  mountPath: /etc/tls/private
                  readOnly: true
          volumes:
            - name: proxy-tls
              secret:
                secretName: grafana-proxy-tls
            - name: grafana-data
              persistentVolumeClaim:
                claimName: grafana-data
EOF
```

Wait for the rollout:

```bash
oc rollout status deploy/grafana-deployment -n ${NAMESPACE} --timeout=120s
```

## Step 7 — Configure the Prometheus datasource

The datasource connects to the cluster's Thanos Querier and authenticates using the ServiceAccount token created in Step 3. The token is referenced from the Secret via `valuesFrom` — it is never exposed in the CR:

```bash
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  valuesFrom:
    - targetPath: "secureJsonData.httpHeaderValue1"
      valueFrom:
        secretKeyRef:
          name: grafana-sa-token
          key: token
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    editable: true
    jsonData:
      httpHeaderName1: Authorization
      timeInterval: 30s
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"
EOF
```

> **Note:** The `secureJsonData.httpHeaderValue1` placeholder value is overridden at runtime by the `valuesFrom` secret reference. However, `valuesFrom` injects the raw token without the `Bearer ` prefix. If the datasource returns authentication errors, replace this step with a manual token injection:
>
> ```bash
> TOKEN=$(oc get secret grafana-sa-token -n ${NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
> ```
>
> Then set `httpHeaderValue1: "Bearer ${TOKEN}"` in `secureJsonData` and remove the `valuesFrom` block.

## Step 8 — Import the dashboards

Create the folder and dashboard resources. The dashboards are loaded from the cloned repository via ConfigMaps:

```bash
cd deployment-resource-consumption-grafana-dashboard

oc create configmap grafana-dashboard-namespace-overview -n ${NAMESPACE} \
  --from-file=dashboard.json=grafana-dashboard-v11.json

oc create configmap grafana-dashboard-workload -n ${NAMESPACE} \
  --from-file=dashboard.json=grafana-dashboard-workload.json

oc create configmap grafana-dashboard-namespace-docs -n ${NAMESPACE} \
  --from-file=dashboard.json=grafana-dashboard-docs.json

oc create configmap grafana-dashboard-workload-docs -n ${NAMESPACE} \
  --from-file=dashboard.json=grafana-dashboard-workload-docs.json

cd ..
```

Create the Grafana folder and dashboard CRs:

```bash
cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: resource-consumption
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  title: "Resource Consumption Analysis"
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: namespace-overview
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "Resource Consumption Analysis"
  configMapRef:
    name: grafana-dashboard-namespace-overview
    key: dashboard.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: workload-details
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "Resource Consumption Analysis"
  configMapRef:
    name: grafana-dashboard-workload
    key: dashboard.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: namespace-overview-docs
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "Resource Consumption Analysis"
  configMapRef:
    name: grafana-dashboard-namespace-docs
    key: dashboard.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: workload-details-docs
  namespace: ${NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "Resource Consumption Analysis"
  configMapRef:
    name: grafana-dashboard-workload-docs
    key: dashboard.json
EOF
```

## Verification

Check that all components are healthy:

```bash
echo "=== Pods ==="
oc get pods -n ${NAMESPACE}

echo "=== Grafana Status ==="
oc get grafana grafana -n ${NAMESPACE} -o jsonpath='{.status.stageStatus}{"\n"}'

echo "=== Datasource ==="
oc get grafanadatasources -n ${NAMESPACE}

echo "=== Dashboards ==="
oc get grafanadashboards -n ${NAMESPACE}

echo "=== Route ==="
oc get route -n ${NAMESPACE} -o jsonpath='https://{.items[0].spec.host}{"\n"}'
```

Expected:
- Grafana pod shows `2/2 Ready` (grafana + oauth-proxy containers)
- Grafana status is `success`
- 4 dashboards with recent `LAST RESYNC` timestamps
- Route URL is accessible

Open the route URL in a browser. You will be redirected to the OpenShift login page. After authenticating, Grafana opens with the "Resource Consumption Analysis" folder containing 4 dashboards.

If dashboards are missing after the first deployment, restart the operator pod to force a fresh reconciliation:

```bash
oc delete pod -n ${NAMESPACE} -l app.kubernetes.io/name=grafana-operator
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Dashboards missing after pod restart | Ephemeral DB (no PVC) or operator cache stale | Verify PVC is bound: `oc get pvc -n ${NAMESPACE}`. Restart operator pod. |
| OAuth redirect loop / 401 | oauth-proxy sending basic auth headers | Ensure `--pass-basic-auth=false` is set in oauth-proxy args. |
| `no matching instances` in operator logs | Operator can't authenticate to Grafana during rollout | Transient — operator retries. Restart operator pod if persistent. |
| Datasource returns `401 Unauthorized` | Token expired or missing | Recreate the `grafana-sa-token` Secret. `valuesFrom` pulls the new token on next datasource resync. |
| `User sync failed` on login | Generic OAuth misconfigured | Do **not** use `auth.generic_oauth` — OpenShift tokens are opaque. Use the `oauth-proxy` sidecar with `auth.proxy` instead. |

## Cleanup

Remove everything:

```bash
oc delete grafanadashboard --all -n ${NAMESPACE}
oc delete grafanafolder --all -n ${NAMESPACE}
oc delete grafanadatasource --all -n ${NAMESPACE}
oc delete grafana --all -n ${NAMESPACE}
oc delete clusterrolebinding grafana-cluster-monitoring-view
oc delete subscription grafana-operator -n ${NAMESPACE}
oc delete csv -n ${NAMESPACE} -l operators.coreos.com/grafana-operator.${NAMESPACE}
oc delete pvc grafana-data -n ${NAMESPACE}
oc delete sa grafana-sa grafana-proxy -n ${NAMESPACE}
oc delete secret grafana-proxy-tls grafana-sa-token -n ${NAMESPACE}
oc delete service grafana-proxy-service -n ${NAMESPACE}
oc delete configmap grafana-dashboard-namespace-overview grafana-dashboard-workload \
  grafana-dashboard-namespace-docs grafana-dashboard-workload-docs -n ${NAMESPACE}
oc delete project ${NAMESPACE}
```
