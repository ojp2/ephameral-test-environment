# Wager Ephemeral Test Environment

Ephemeral Kubernetes test environment deployed via ArgoCD on EKS.
Each run gets its own namespace, runs JMeter as a K8s Job, uploads results to S3, then tears everything down.

---

## Architecture

```
GitHub Actions (tools account)
  ├── Build     → wager-app + wager-jmeter images → ECR
  ├── Provision → ArgoCD creates namespace + all services in app cluster
  ├── Test      → polls ArgoCD for JMeter Job completion
  │               downloads results from S3 → uploads as artifact
  └── Teardown  → ArgoCD deletes Application → namespace gone
```

```
App cluster namespace (wager-test-run-XXXXX):
  mysql          StatefulSet
  wiremock-gds   Deployment + ConfigMap  (game data mock)
  wiremock-esb   Deployment + ConfigMap  (account + purchase mock)
  wager-svc      Deployment + ClusterIP
  jmeter         Job  (hits wager-svc, uploads results to S3, exits)
```

---

## Test Cases

| Name | Game | HTTP | Body status | Scenario |
|---|---|---|---|---|
| `mega-millions` | MM | 200 | OK | Successful purchase |
| `powerball` | PB | 402 | NO_FUNDS | Zero account balance |
| `pick5` | P5 | 503 | HOST_NO_ISSUE | ESB host unavailable |

---

## Substitutions Required

### `.github/workflows/wager-ephemeral-test.yml`
| Line | Placeholder | Example |
|---|---|---|
| 28 | `YOUR_ARGOCD_SERVER` | `argocd.yourdomain.com` |
| 29 | `YOUR_ECR_REGISTRY` | `123456789.dkr.ecr.us-east-1.amazonaws.com` |
| 30 | `YOUR_AWS_REGION` | `us-east-1` |
| 31 | `YOUR_S3_BUCKET` | `my-wager-test-results` |

### `helm/wager-test-env/values.yaml`
| Field | Replace with |
|---|---|
| `jmeter.s3Bucket` | your tools account S3 bucket name |

### `argocd/project.yaml`
| Field | Replace with |
|---|---|
| `sourceRepos[0]` | your GitHub repo URL |

---

## GitHub Secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | ECR login + S3 download (tools account) |
| `AWS_SECRET_ACCESS_KEY` | ECR login + S3 download (tools account) |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token |

---

## S3 Cross-Account Setup

JMeter runs in the **app account** and writes to an S3 bucket in the **tools account**.

**Tools account bucket policy** (allows app account nodes to write):
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::APP_ACCOUNT_ID:role/YOUR_NODE_ROLE"
    },
    "Action": ["s3:PutObject", "s3:PutObjectAcl"],
    "Resource": "arn:aws:s3:::YOUR_S3_BUCKET/wager-test-results/*"
  }]
}
```

**App account node role policy** (allows writing to tools account bucket):
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:PutObjectAcl"],
    "Resource": "arn:aws:s3:::YOUR_S3_BUCKET/wager-test-results/*"
  }]
}
```

---

## One-Time Setup

```bash
# Apply ArgoCD project
kubectl apply -f argocd/project.yaml

# Register repo in ArgoCD
argocd repo add https://github.com/YOUR_ORG/YOUR_REPO \
  --username YOUR_USERNAME \
  --password YOUR_PAT
```

---

## Trigger a Test

```bash
# Via GitHub CLI
gh workflow run wager-ephemeral-test.yml -f test_case=mega-millions
gh workflow run wager-ephemeral-test.yml -f test_case=powerball
gh workflow run wager-ephemeral-test.yml -f test_case=pick5
```

Or via GitHub UI: **Actions → Wager Ephemeral Test → Run workflow**

---

## Project Structure

```
.github/workflows/
  wager-ephemeral-test.yml

app/
  server.js          Node.js wager service
  schema.sql         MySQL DDL
  package.json
  Dockerfile

jmeter-image/
  Dockerfile         JMeter image with test plan baked in
  run-tests.sh       Runs JMeter, uploads to S3

jmeter/
  wager-purchase-test.jmx

helm/wager-test-env/
  Chart.yaml
  values.yaml
  test-cases/
    mega_millions-values.yaml
    powerball-values.yaml
    pick5-values.yaml
  templates/
    mysql.yaml
    schema-migrate.yaml
    wiremock.yaml
    wiremock-configmaps.yaml
    wager-svc.yaml
    jmeter-job.yaml
    rbac.yaml
    network-policy.yaml
    resource-quota.yaml

wiremock/
  gds-mappings/game-data.json
  esb-mappings/esb-wager.json

argocd/
  project.yaml

scripts/
  validate-results.sh

docker-compose.yml   Local dev without K8s
```
