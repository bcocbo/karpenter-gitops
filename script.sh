#!/bin/bash

# Script para desplegar Karpenter en ArgoCD para cluster poc-kafka2

echo "🚀 Iniciando despliegue de Karpenter para cluster poc-kafka2..."

# Variables
CLUSTER_NAME="poc-kafka2"
AWS_REGION="us-east-1"  # Región actualizada
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📋 Información del cluster:"
echo "  - Cluster: $CLUSTER_NAME"
echo "  - Región: $AWS_REGION"
echo "  - Account ID: $AWS_ACCOUNT_ID"

# Verificar que kubectl está configurado para el cluster correcto
echo "🔍 Verificando conexión al cluster..."
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
    echo "⚠️  ADVERTENCIA: El contexto actual ($CURRENT_CONTEXT) no parece ser el cluster $CLUSTER_NAME"
    echo "¿Deseas continuar? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "❌ Abortando despliegue"
        exit 1
    fi
fi

# Paso 1: Crear el proyecto de ArgoCD
echo "📁 Creando proyecto de ArgoCD..."
kubectl apply -f argocd/project.yaml

# Paso 2: Instalar los CRDs de Karpenter primero (requerido para v1.0+)
echo "📋 Instalando CRDs de Karpenter..."
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "1.0.8" \
    --include-crds \
    --set "controller.image.repository=public.ecr.aws/karpenter/karpenter" \
    --set "settings.clusterName=$CLUSTER_NAME" | \
    grep -E '^apiVersion: apiextensions.k8s.io' -A 1000 | \
    kubectl apply -f -

# Paso 3: Actualizar los ARNs en la configuración
echo "🔧 Actualizando configuración con ARNs específicos para us-east-1..."
sed -i "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" argocd/karpenter-app.yaml

# Paso 4: Aplicar la aplicación de Karpenter
echo "🛠️  Desplegando Karpenter via ArgoCD..."
kubectl apply -f argocd/karpenter-app.yaml

# Paso 5: Esperar a que Karpenter esté listo
echo "⏳ Esperando a que Karpenter esté disponible..."
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || {
    echo "❌ Timeout esperando a Karpenter. Verificando estado..."
    kubectl get pods -n karpenter
    echo "Logs del pod de Karpenter:"
    kubectl logs -l app.kubernetes.io/name=karpenter -n karpenter --tail=50
}

# Paso 6: Aplicar NodePools y EC2NodeClasses
echo "🏗️  Configurando NodePools..."
kubectl apply -f nodepool/

# Verificación final
echo "✅ Verificando instalación..."
echo ""
echo "📊 Estado de Karpenter:"
kubectl get pods -n karpenter

echo ""
echo "📊 NodePools configurados:"
kubectl get nodepool -n karpenter

echo ""
echo "📊 EC2NodeClasses configurados:"
kubectl get ec2nodeclass -n karpenter

echo ""
echo "📊 Aplicaciones de ArgoCD:"
kubectl get applications -n argocd | grep karpenter

echo ""
echo "🎉 ¡Despliegue completado!"
echo ""
echo "📝 Próximos pasos:"
echo "1. Verificar que los NodePools estén activos: kubectl get nodepool -n karpenter"
echo "2. Probar creando un deployment que requiera nuevos nodos"
echo "3. Monitorear logs de Karpenter: kubectl logs -l app.kubernetes.io/name=karpenter -n karpenter -f"
echo ""
echo "🔗 Para acceder a ArgoCD:"
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"