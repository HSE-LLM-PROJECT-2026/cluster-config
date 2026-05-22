# Cluster Config

## Описание

Набор инфраструктурных конфигов для развёртывания и сопровождения кластерного окружения платформы: Terraform, Talos, node tooling, MinIO, GitLab demo и служебные пакеты.

## Основные возможности

- provisioning и описание кластера через Terraform
- bootstrap/операции Talos-кластера
- deployment пакетов для GPU/NFD/MinIO/Hardening
- вспомогательные скрипты node autorecovery и GitLab demo

## Структура проекта

- `llm_proj_terraform/` - IaC-конфиги Terraform
- `llm_proj_talos/` - Talos bootstrap/reset/tooling
- `minio-model-cache-deployment/` - MinIO конфиг и deploy scripts
- `gpu-feature-discovery-deployment/`, `node-feature-discovery-deployment/`
- `hardening-package/`, `node-autorecovery/`, `gitlab-cicd-demo/`

## Применение

Каждый подпроект имеет собственные скрипты `deploy-from-scratch.sh` / `delete-all.sh` / `apply-new-variables.sh`.

Перед запуском проверь `.env.example` в нужной подпапке и создай рабочий `.env`.
