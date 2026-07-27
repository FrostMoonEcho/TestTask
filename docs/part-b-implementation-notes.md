# Part B — карта внесённых изменений

Этот документ помогает ревьюеру быстро сопоставить требования задания с
конкретными файлами. Чувствительных значений в репозитории нет: все имена,
идентификаторы и адреса являются примерами.

Требование `No public K8s API / SSH` применяется к Kubernetes API
K3s-дистрибутива: starter repository изначально содержит
`aws_instance.k3s_node` и security group для порта `6443`. Part A при этом
описывает целевую production-платформу на EKS.

## B1 — Terraform

| Где | Что изменено | Почему |
|---|---|---|
| `terraform/versions.tf` | Добавлен удалённый S3 backend, ограничения версий Terraform и провайдеров | State не должен храниться локально; фиксированные диапазоны версий уменьшают риск несовместимых изменений |
| `terraform/backend.hcl.example` | Добавлены S3 state, native S3 lock и DynamoDB lock | Выполняет требование задания о S3 + DynamoDB; реальные имена не коммитятся |
| `terraform/main.tf` | VPC разделена на public, private application и isolated data subnets | K3s и RDS не имеют прямого публичного маршрута |
| `terraform/main.tf`, `terraform/variables.tf` | EC2 для K3s без public IP, SSH/key pair; API `6443` разрешён только для CIDR, полностью находящихся в RFC1918 space | Kubernetes API и административный доступ не выставляются в интернет; публичный `/32` также отклоняется |
| `terraform/main.tf` | Для EC2 включены IMDSv2, encrypted root volume, SSM и ограниченный egress | Уменьшается поверхность атаки и исключаются постоянные SSH-ключи |
| `terraform/main.tf` | RDS private, `storage_encrypted = true`, KMS, TLS enforcement, backups, final snapshot и deletion protection | Защита данных at rest/in transit и базовая восстановимость |
| `terraform/main.tf` | S3: SSE-KMS, versioning, bucket-owner enforcement, TLS-only policy и полный Public Access Block | Исключается публичная или незашифрованная выдача billing exports и ACL-based ownership ambiguity |
| `terraform/iam.tf` | Удалён IAM user с `AdministratorAccess`; добавлены отдельные роли EC2, CI build и CI deploy | Least privilege и краткоживущие credentials вместо постоянных ключей |
| `terraform/iam.tf` | GitHub OIDC trust ограничен точными repository/branch/environment claims | Workflow из другого репозитория или окружения не сможет принять роль |
| `terraform/ecr.tf` | Private immutable ECR, scan-on-push, KMS и lifecycle retention | SHA-теги нельзя перезаписать; старые образы остаются доступны для rollback |
| `terraform/outputs.tf` | Добавлены RDS, S3, ECR, KMS и IAM ARNs без секретов | CI и операторы получают нужные идентификаторы, но не credentials |

## B2 — Helm

| Где | Что изменено | Почему |
|---|---|---|
| `charts/billing-service/values.production.yaml` | Добавлены production env, `PGSSLMODE=verify-full`, два replica, requests/limits и hardening | Отдельный production overlay не смешивается с локальными defaults |
| `templates/deployment.yaml` | Пароли БД, JWT и payment key читаются через `secretKeyRef` | Секретные значения не попадают в Git, values или rendered manifests |
| `templates/deployment.yaml` | Добавлены startup/readiness/liveness probes | Kubernetes не направляет трафик в неготовый pod и может восстановить зависший процесс |
| `templates/deployment.yaml` | Добавлены non-root, read-only root filesystem, seccomp и drop capabilities | Контейнер получает минимально необходимые runtime-привилегии |
| `templates/serviceaccount.yaml` | Отдельный ServiceAccount без automount API token | Приложению не выдаётся Kubernetes credential, которое ему не требуется |
| `templates/networkpolicy.yaml` | Ingress разрешён только pod-ам API gateway из namespace `platform` | Billing service не доступен произвольным workload-ам кластера |
| `templates/deployment.yaml` | RDS CA bundle монтируется read-only из ConfigMap | `verify-full` может проверить цепочку и hostname сертификата RDS |
| `.github/workflows/deploy.yml` | `env.dbHost` получает точный Terraform output через environment variable `RDS_ENDPOINT` | В репозитории не остаётся фиктивный hostname, а TLS `verify-full` проверяет реальный RDS endpoint |

## B3 — CI/CD

Файл: `.github/workflows/deploy.yml`.

- Workflow запускается только после push в `main`.
- `npm ci` использует committed lockfile, затем `npm audit` блокирует HIGH/CRITICAL
  dependency findings.
- Helm chart проходит lint и render до сборки образа.
- Build job принимает отдельную AWS role через GitHub OIDC и пушит только в
  выделенный ECR repository.
- Образ получает immutable tag, равный commit SHA; после push CI разрешает
  точный ECR digest.
- Trivy проверяет именно этот digest и завершает pipeline с ошибкой при
  CRITICAL OS/library vulnerability.
- Deploy job использует GitHub Environment `cell-01-production`: required
  reviewers и разрешение deploy только из `main` настраиваются в GitHub и
  образуют manual approval gate. Ограничение ветки важно, поскольку
  environment-scoped OIDC `sub` содержит environment, а не имя ветки.
- Деплой идёт с self-hosted runner внутри private network, поскольку K3s API
  намеренно недоступен из интернета.
- Перед Helm deploy проверяется и передаётся environment-scoped
  `RDS_ENDPOINT`, полученный из Terraform output.
- Deploy-role может проверить digest и скачать слои только выделенного ECR
  repository; эти права используются краткоживущим registry token в pull
  Secret и не дают push/delete.
- Helm получает `image.digest`, поэтому повторный workflow не может проверить
  один локальный build, а развернуть другой ранее существовавший образ.
- `helm upgrade --install --atomic --cleanup-on-fail --wait` автоматически
  откатывает неуспешный релиз.

## B4 — provisioning script

Файл: `scripts/provision-cell.sh`.

- Обязательные параметры: `CUSTOMER_ID`, `AWS_REGION`, `TIER`,
  `TF_STATE_BUCKET`, `TF_LOCK_TABLE`.
- Скрипт валидирует идентификаторы и допустимые EU-регионы для regulated tier.
- Пути plan/audit формируются только после validation `CELL_ID`, что исключает
  path traversal через параметры.
- Без `--apply` выполняется только plan; с `--apply` применяется именно
  сохранённый plan, а не новый нерассмотренный расчёт.
- Для каждой стадии создаётся JSONL audit event с timestamp, actor ARN,
  cell/customer ID, git commit, result и SHA-256 плана.
- Audit log имеет права `0600` и при необходимости загружается в зашифрованный
  S3 audit prefix.
- `set -x` не используется, чтобы значения из окружения не попадали в логи.

## B5 — security documentation

Файл: `SECURITY.md`.

- Описаны ровно три требуемых SOC 2 control area: CC6, CC7 и CC8.
- Для каждого контроля указаны техническая реализация и собираемые evidence.
- Зафиксированы ровно пять главных рисков, mitigations, residual risk и owner.
- Добавлены vulnerability remediation SLA и порядок исключений.
- Rotation runbook покрывает RDS application password, JWT key и payment
  provider key, включая проверку, rollback и audit evidence.

## Проверка и эксплуатационные ограничения

Локально проверяются HCL/YAML/Bash/Node syntax, lockfile, `npm ci`, `npm audit`
и отсутствие распространённых секретов/небезопасных конструкций. Полные
`terraform validate`, `helm lint`, `helm template`, Docker build и Trivy scan
выполняются в среде, где установлены соответствующие CLI; необходимые команды
описаны в `README.md` и встроены в CI.

Оставшиеся ограничения явно перечислены в `README.md`: single-node K3s,
один NAT Gateway, внешний private runner, внешний backend bootstrap и внешний
secret controller.
