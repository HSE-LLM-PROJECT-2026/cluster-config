# Cluster Config

## Описание

Инфраструктурный репозиторий для описания и подготовки Kubernetes-кластеров под LLM-платформу. Тут лежит Terraform для Proxmox, Talos-конфиги, GPU-настройки, node discovery, secrets и вспомогательные системные скрипты.

## Основные возможности

- описание VM в Proxmox через Terraform
- bootstrap/reset Talos-кластера
- настройка GPU runtime для Kubernetes
- node-feature-discovery и gpu-feature-discovery
- secret для Hugging Face token
- MinIO cache для моделей
- node autorecovery systemd-скрипты

## Структура проекта

- `llm_proj_terraform/` — Terraform-конфигурация Proxmox VM
- `llm_proj_talos/` — Talos bootstrap/reset и kubeconfig
- `llm_proj_talos_gpu/` — GPU runtime patches
- `node-feature-discovery-deployment/` — NFD
- `gpu-feature-discovery-deployment/` — GPU discovery
- `huggingface-token-secret-deployment/` — секрет Hugging Face
- `minio-model-cache-deployment/` — MinIO для cache моделей
- `node-autorecovery/` — host-level autorecovery
- `hardening-package/` — базовые hardening-настройки

## Terraform

```bash
cd llm_proj_terraform
terraform init
terraform plan
terraform apply
```

## Talos

```bash
cd llm_proj_talos
./bootstrap.sh
```

Сброс кластера:

```bash
cd llm_proj_talos
./reset-cluster.sh
```

## GPU runtime

GPU-ноды требуют отдельного Talos patch и Kubernetes runtime manifests из `llm_proj_talos_gpu/`.

## Важное

Секреты и реальные токены не коммитятся. Для локального запуска используются `.env.example` и переменные окружения.

## Автор

Igor Malysh
