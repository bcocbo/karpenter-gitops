#!/bin/bash

set -e

# Variables de configuración
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="1.7.1"
export K8S_VERSION="1.31"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT="$(mktemp)"
export CLUSTER_NAME="poc-kafka2"

echo "🚀 Instalando Karpenter versión $KARPENTER_VERSION en cluster $CLUSTER_NAME"
echo "📋 Configuración:"
echo "  - Región AWS: $AWS_DEFAULT_REGION"
echo "  - Account ID: $AWS_ACCOUNT_ID"
echo "  - Namespace: $KARPENTER_NAMESPACE"
echo "  - Versión K8s: $K8S_VERSION"

# Función para verificar prerequisitos
check_prerequisites() {
    echo "🔍 Verificando prerequisitos..."
    
    # Verificar herramientas necesarias
    for cmd in kubectl helm aws; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ $cmd no está instalado"
            exit 1
        fi
    done
    echo "✅ Herramientas verificadas"
    
    # Verificar conexión al cluster
    if ! kubectl cluster-info &> /dev/null; then
        echo "❌ No se puede conectar al cluster de Kubernetes"
        exit 1
    fi
    echo "✅ Conexión al cluster verificada"
    
    # Verificar que el contexto es correcto
    CURRENT_CONTEXT=$(kubectl config current-context)
    if [[ ! "$CURRENT_CONTEXT" =~ "$CLUSTER_NAME" ]]; then
        echo "⚠️  ADVERTENCIA: El contexto actual ($CURRENT_CONTEXT) no parece ser el cluster $CLUSTER_NAME"
        echo "¿Deseas continuar? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "❌ Abortando instalación"
            exit 1
        fi
    fi
    echo "✅ Contexto del cluster verificado"
}

# Función para verificar recursos IAM
check_iam_resources() {
    echo "🔐 Verificando recursos IAM..."
    
    # Verificar el rol del controlador
    if aws iam get-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" &> /dev/null; then
        echo "✅ Rol del controlador encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
    else
        echo "❌ Rol del controlador no encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
        echo "Ejecuta primero: aws iam create-role..."
        exit 1
    fi
    
    # Verificar el instance profile
    if aws iam get-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" &> /dev/null; then
        echo "✅ Instance profile encontrado: KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
    else
        echo "❌ Instance profile no encontrado: KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
        echo "Ejecuta primero la configuración de IAM para Karpenter"
        exit 1
    fi
}

# Función para verificar tags en recursos VPC
check_vpc_tags() {
    echo "🏷️  Verificando tags en recursos VPC..."
    
    # Verificar subredes
    SUBNET_COUNT=$(aws ec2 describe-subnets \
        --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
        --query 'Subnets | length(@)' --output text)
    
    if [[ "$SUBNET_COUNT" -gt 0 ]]; then
        echo "✅ Encontradas $SUBNET_COUNT subredes con tag karpenter.sh/discovery=${CLUSTER_NAME}"
    else
        echo "❌ No se encontraron subredes con tag karpenter.sh/discovery=${CLUSTER_NAME}"
        echo "Ejecuta: aws ec2 create-tags --resources subnet-xxx --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
        exit 1
    fi
    
    # Verificar security groups
    SG_COUNT=$(aws ec2 describe-security-groups \
        --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
        --query 'SecurityGroups | length(@)' --output text)
    
    if [[ "$SG_COUNT" -gt 0 ]]; then
        echo "✅ Encontrados $SG_COUNT security groups con tag karpenter.sh/discovery=${CLUSTER_NAME}"
    else
        echo "❌ No se encontraron security groups con tag karpenter.sh/discovery=${CLUSTER_NAME}"
        echo "Ejecuta: aws ec2 create-tags --resources sg-xxx --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
        exit 1
    fi
}

# Función para autenticarse con ECR Public
authenticate_ecr() {
    echo "🔑 Autenticando con ECR Public..."
    aws ecr-public get-login-password --region us-east-1 | \
        helm registry login --username AWS --password-stdin public.ecr.aws
    echo "✅ Autenticación completada"
}

# Función para instalar CRDs
install_crds() {
    echo "📋 Instalando CRDs de Karpenter..."
    
    kubectl apply -f "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
    kubectl apply -f "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
    kubectl apply -f "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
    
    echo "✅ CRDs instalados"
}

# Función para crear namespace
create_namespace() {
    echo "📦 Creando namespace $KARPENTER_NAMESPACE..."
    kubectl create namespace "$KARPENTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Namespace creado"
}

# Función para instalar Karpenter usando Helm
install_karpenter() {
    echo "🛠️  Instalando Karpenter con Helm..."
    
    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version "$KARPENTER_VERSION" \
        --namespace "$KARPENTER_NAMESPACE" \
        --create-namespace \
        --wait \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.interruptionQueue=${CLUSTER_NAME}" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
        --set "controller.resources.requests.cpu=1" \
        --set "controller.resources.requests.memory=1Gi" \
        --set "controller.resources.limits.cpu=1" \
        --set "controller.resources.limits.memory=1Gi"
    
    echo "✅ Karpenter instalado"
}

# Función para crear configuración de NodePool por defecto
create_default_nodepool() {
    echo "🏗️  Creando NodePool por defecto..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
  
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  instanceStorePolicy: NVME
  
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh ${CLUSTER_NAME}
  
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        deleteOnTermination: true
        encrypted: true
  
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
---
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        cluster: "${CLUSTER_NAME}"
        nodepool: "default"
    spec:
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
      
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: 
            - t3.medium
            - t3.large
            - t3.xlarge
            - t3.2xlarge
            - m5.large
            - m5.xlarge
            - m5.2xlarge
            - m5.4xlarge
            - c5.large
            - c5.xlarge
            - c5.2xlarge
      
      taints:
        - key: "karpenter.sh/default"
          value: "true"
          effect: NoSchedule
  
  limits:
    cpu: 1000
    memory: 1000Gi
  
  disruption:
    consolidationPolicy: WhenUndersized
    consolidateAfter: 30s
    expireAfter: 30m
EOF

    echo "✅ NodePool por defecto creado"
}

# Función para verificar la instalación
verify_installation() {
    echo "🔍 Verificando instalación..."
    
    # Esperar a que los pods estén listos
    echo "⏳ Esperando a que Karpenter esté listo..."
    kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n "$KARPENTER_NAMESPACE" || {
        echo "❌ Timeout esperando a Karpenter"
        kubectl describe deployment/karpenter -n "$KARPENTER_NAMESPACE"
        kubectl logs -l app.kubernetes.io/name=karpenter -n "$KARPENTER_NAMESPACE" --tail=50
        exit 1
    }
    
    echo "✅ Karpenter está ejecutándose"
    
    # Verificar NodePool
    kubectl get nodepool default -o wide || echo "⚠️  NodePool no encontrado"
    kubectl get ec2nodeclass default -o wide || echo "⚠️  EC2NodeClass no encontrado"
    
    echo ""
    echo "📊 Estado actual:"
    kubectl get pods -n "$KARPENTER_NAMESPACE"
    echo ""
    kubectl get nodepool
    echo ""
    kubectl get ec2nodeclass
}

# Función para mostrar información post-instalación
post_install_info() {
    echo ""
    echo "🎉 ¡Instalación de Karpenter completada!"
    echo ""
    echo "📊 Información del despliegue:"
    echo "  - Namespace: $KARPENTER_NAMESPACE"
    echo "  - Versión: $KARPENTER_VERSION"
    echo "  - Cluster: $CLUSTER_NAME"
    echo "  - Región: $AWS_DEFAULT_REGION"
    echo ""
    echo "📝 Comandos útiles:"
    echo "  - Ver logs: kubectl logs -l app.kubernetes.io/name=karpenter -n $KARPENTER_NAMESPACE -f"
    echo "  - Ver nodos: kubectl get nodes -l karpenter.sh/provisioner-name"
    echo "  - Ver NodePools: kubectl get nodepool"
    echo "  - Ver EC2NodeClass: kubectl get ec2nodeclass"
    echo ""
    echo "🧪 Para probar Karpenter:"
    echo "  kubectl apply -f https://raw.githubusercontent.com/aws/karpenter/main/examples/v1beta1/inflate.yaml"
    echo ""
    echo "🔧 Para desinstalar:"
    echo "  helm uninstall karpenter -n $KARPENTER_NAMESPACE"
    echo "  kubectl delete namespace $KARPENTER_NAMESPACE"
}

# Ejecución principal
main() {
    echo "🎯 Iniciando instalación de Karpenter..."
    
    check_prerequisites
    check_iam_resources
    check_vpc_tags
    authenticate_ecr
    create_namespace
    install_crds
    install_karpenter
    create_default_nodepool
    verify_installation
    post_install_info
    
    echo ""
    echo "✅ Proceso completado exitosamente!"
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi