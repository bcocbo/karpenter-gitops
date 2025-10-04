# Karpenter NodePool for poc-kafka2

Este repositorio contiene la configuración de GitOps para un NodePool en Karpenter que usa instancias Spot en el clúster EKS `poc-kafka2`.

## Estructura
- `karpenter/`: Recursos de Karpenter (EC2NodeClass, NodePool).
- `argocd/`: Configuraciones de ArgoCD Applications.

## Prerrequisitos
- Clúster EKS: poc-kafka2
- Región: us-east-1
- Karpenter: v0.34+ instalado en namespace `karpenter`
- Subnets/SGs con tag `karpenter.sh/discovery: poc-kafka2`

## Cómo desplegar
1. Clona el repo.
2. Asegúrate de que ArgoCD esté configurado.
3. Aplica la Application: `kubectl apply -f argocd/applications/karpenter-spot-kafka.yaml`