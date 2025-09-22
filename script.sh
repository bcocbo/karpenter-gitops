#!/bin/bash

set -e

# Variables de configuración
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="1.7.1"
export K8S_VERSION="1.31"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export CLUSTER_NAME="poc-kafka2"

echo "🚀 Instalando Karpenter versión $KARPENTER_VERSION en cluster $CLUSTER_NAME"
echo "📋 Configuración:"
echo "  - Región AWS: $AWS_DEFAULT_REGION"
echo "  - Account ID: $AWS_ACCOUNT_ID"
echo "  - Namespace: $KARPENTER_NAMESPACE"
echo "  - Versión K8s: $K8S_VERSION"
echo "  - Rol IAM: KarpenterNodeRole-${CLUSTER_NAME}"

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
    
    # Verificar el rol de Karpenter (mismo para controller y nodos)
    if aws iam get-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" &> /dev/null; then
        echo "✅ Rol de Karpenter encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
    else
        echo "❌ Rol de Karpenter no encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
        echo "Crea el rol primero con los permisos necesarios"
        exit 1
    fi
    
    # Verificar el instance profile (mismo nombre que el rol)
    if aws iam get-instance-profile --instance-profile-name "KarpenterNodeRole-${CLUSTER_NAME}" &> /dev/null; then
        echo "✅ Instance profile encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
        
        # Verificar que el rol está asociado al instance profile
        ROLE_IN_PROFILE=$(aws iam get-instance-profile --instance-profile-name "KarpenterNodeRole-${CLUSTER_NAME}" \
            --query 'InstanceProfile.Roles[0].RoleName' --output text)
        
        if [[ "$ROLE_IN_PROFILE" == "KarpenterNodeRole-${CLUSTER_NAME}" ]]; then
            echo "✅ Rol correctamente asociado al instance profile"
        else
            echo "❌ El rol no está asociado al instance profile"
            exit 1
        fi
    else
        echo "❌ Instance profile no encontrado: KarpenterNodeRole-${CLUSTER_NAME}"
        echo "Crea el instance profile y asocia el rol"
        exit 1
    fi
    
    # Mostrar políticas del rol
    echo "📋 Políticas del rol:"
    aws iam list-attached-role-policies --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
        --query 'AttachedPolicies[].PolicyArn' --output table || echo "Sin políticas gestionadas"
    aws iam list-role-policies --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
        --query 'PolicyNames' --output table || echo "Sin políticas inline"
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
        # Mostrar las subredes encontradas
        aws ec2 describe-subnets \
            --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
            --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
            --output table
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
        # Mostrar los security groups encontrados
        aws ec2 describe-security-groups \
            --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
            --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Description:Description}' \
            --output table
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

# Función para verificar que la versión existe
verify_chart_version() {
    echo "📦 Verificando que la versión $KARPENTER_VERSION existe..."
    if helm show chart oci://public.ecr.aws/karpenter/karpenter --version "$KARPENTER_VERSION" &> /dev/null; then
        echo "✅ Versión $KARPENTER_VERSION encontrada"
    else
        echo "❌ Versión $KARPENTER_VERSION no encontrada"
        echo "Versiones disponibles:"
        helm search repo karpenter --versions | head -10
        exit 1
    fi
}

# Función para instalar CRDs
install_crds() {
    echo "📋 Instalando CRDs de Karpenter v$KARPENTER_VERSION..."
    
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
    echo "🛠️  Instalando Karpenter v$KARPENTER_VERSION con Helm..."
    
    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version "$KARPENTER_VERSION" \
        --namespace "$KARPENTER_NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout=300s \
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
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  
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
  
  tags:
    Name: "karpenter-node-${CLUSTER_NAME}"
    Environment: "poc"
    ManagedBy: "karpenter"
    Cluster: "${CLUSTER_NAME}"
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

# Función para crear NodePool optimizado para Kafka
create_kafka_nodepool() {
    echo "☕ Creando NodePool optimizado para Kafka..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: kafka-optimized
spec:
  amiFamily: AL2
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  
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
    
    # Optimizaciones para Kafka
    echo "vm.swappiness=1" >> /etc/sysctl.conf
    echo "vm.dirty_ratio=80" >> /etc/sysctl.conf
    echo "vm.dirty_background_ratio=5" >> /etc/sysctl.conf
    echo "net.core.rmem_max=134217728" >> /etc/sysctl.conf
    echo "net.core.wmem_max=134217728" >> /etc/sysctl.conf
    sysctl -p
    
    # Configurar límites de archivos para Kafka
    echo "* soft nofile 100000" >> /etc/security/limits.conf
    echo "* hard nofile 100000" >> /etc/security/limits.conf
  
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        iops: 5000
        throughput: 250
        deleteOnTermination: true
        encrypted: true
  
  tags:
    Name: "karpenter-kafka-node-${CLUSTER_NAME}"
    Environment: "poc"
    ManagedBy: "karpenter"
    Workload: "kafka"
    Cluster: "${CLUSTER_NAME}"
---
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: kafka-optimized
spec:
  template:
    metadata:
      labels:
        cluster: "${CLUSTER_NAME}"
        nodepool: "kafka-optimized"
        workload: "kafka"
    spec:
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: kafka-optimized
      
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]  # Kafka necesita estabilidad
        - key: node.kubernetes.io/instance-type
          operator: In
          values: 
            - m5.xlarge
            - m5.2xlarge
            - m5.4xlarge
            - m5.8xlarge
            - r5.xlarge
            - r5.2xlarge
            - r5.4xlarge
      
      taints:
        - key: "workload"
          value: "kafka"
          effect: NoSchedule
  
  limits:
    cpu: 500
    memory: 500Gi
  
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 60s
    expireAfter: 24h  # Kafka necesita nodos más estables
EOF

    echo "✅ NodePool para Kafka creado"
}

# Función para verificar la instalación
verify_installation() {
    echo "🔍 Verificando instalación..."
    
    # Esperar a que los pods estén listos
    echo "⏳ Esperando a que Karpenter esté listo..."
    kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n "$KARPENTER_NAMESPACE" || {
        echo "❌ Timeout esperando a Karpenter"
        echo "Estado del deployment:"
        kubectl describe deployment/karpenter -n "$KARPENTER_NAMESPACE"
        echo ""
        echo "Logs de Karpenter:"
        kubectl logs -l app.kubernetes.io/name=karpenter -n "$KARPENTER_NAMESPACE" --tail=50
        exit 1
    }
    
    echo "✅ Karpenter está ejecutándose"
    
    # Verificar NodePool
    if kubectl get nodepool default -o wide &> /dev/null; then
        echo "✅ NodePool 'default' creado"
    else
        echo "⚠️  NodePool 'default' no encontrado"
    fi
    
    if kubectl get ec2nodeclass default -o wide &> /dev/null; then
        echo "✅ EC2NodeClass 'default' creado"
    else
        echo "⚠️  EC2NodeClass 'default' no encontrado"
    fi
    
    # Verificar Service Account
    SA_ANNOTATION=$(kubectl get serviceaccount karpenter -n "$KARPENTER_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
    if [[ "$SA_ANNOTATION" =~ "KarpenterNodeRole-${CLUSTER_NAME}" ]]; then
        echo "✅ Service Account configurado correctamente con IRSA"
    else
        echo "⚠️  Service Account no tiene la anotación IRSA correcta"
    fi
    
    echo ""
    echo "📊 Estado actual:"
    kubectl get pods -n "$KARPENTER_NAMESPACE"
    echo ""
    kubectl get nodepool
    echo ""
    kubectl get ec2nodeclass
}

# Función para crear deployment de prueba
create_test_deployment() {
    echo "🧪 ¿Quieres crear un deployment de prueba para verificar Karpenter? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "📝 Creando deployment de prueba..."
        
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 0
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: test
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: 1
              memory: 1Gi
      tolerations:
        - key: "karpenter.sh/default"
          operator: "Exists"
          effect: "NoSchedule"
      nodeSelector:
        nodepool: "default"
EOF
        
        echo "✅ Deployment de prueba creado"
        echo ""
        echo "Para probar Karpenter, ejecuta:"
        echo "  kubectl scale deployment karpenter-test --replicas=3"
        echo "  kubectl get nodes -w"
        echo ""
        echo "Para limpiar:"
        echo "  kubectl delete deployment karpenter-test"
    fi
}

# Función para mostrar información post-instalación
post_install_info() {
    echo ""
    echo "🎉 ¡Instalación de Karpenter completada exitosamente!"
    echo ""
    echo "📊 Información del despliegue:"
    echo "  - Namespace: $KARPENTER_NAMESPACE"
    echo "  - Versión: $KARPENTER_VERSION"
    echo "  - Cluster: $CLUSTER_NAME"
    echo "  - Región: $AWS_DEFAULT_REGION"
    echo "  - Rol IAM: KarpenterNodeRole-${CLUSTER_NAME}"
    echo ""
    echo "📝 Comandos útiles:"
    echo "  - Ver logs: kubectl logs -l app.kubernetes.io/name=karpenter -n $KARPENTER_NAMESPACE -f"
    echo "  - Ver nodos creados: kubectl get nodes -l karpenter.sh/nodepool"
    echo "  - Ver NodePools: kubectl get nodepool"
    echo "  - Ver EC2NodeClass: kubectl get ec2nodeclass"
    echo "  - Ver eventos: kubectl get events -A --sort-by='.lastTimestamp' | grep -i karpenter"
    echo ""
    echo "🏗️  NodePools disponibles:"
    kubectl get nodepool -o wide
    echo ""
    echo "🔧 Para desinstalar:"
    echo "  kubectl delete nodepool --all"
    echo "  kubectl delete ec2nodeclass --all"
    echo "  helm uninstall karpenter -n $KARPENTER_NAMESPACE"
    echo "  kubectl delete namespace $KARPENTER_NAMESPACE"
}

# Ejecución principal
main() {
    echo "🎯 Iniciando instalación de Karpenter v$KARPENTER_VERSION..."
    echo ""
    
    check_prerequisites
    check_iam_resources
    check_vpc_tags
    authenticate_ecr
    verify_chart_version
    create_namespace
    install_crds
    install_karpenter
    create_default_nodepool
    create_kafka_nodepool
    verify_installation
    create_test_deployment
    post_install_info
    
    echo ""
    echo "✅ Proceso completado exitosamente!"
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi