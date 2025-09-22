# argocd/project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: karpenter-project
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: "Proyecto para gestionar Karpenter en el cluster poc-kafka2"
  sourceRepos:
  - 'oci://public.ecr.aws/karpenter/*'
  - 'https://github.com/tu-usuario/karpenter-gitops'  # Repositorio de configuraciones
  destinations:
  - namespace: karpenter
    server: https://kubernetes.default.svc
  - namespace: kube-system
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: ""
    kind: ServiceAccount
  - group: ""
    kind: ConfigMap
  - group: ""
    kind: Secret
  - group: "apps"
    kind: Deployment
  - group: "apps"
    kind: DaemonSet
  - group: "rbac.authorization.k8s.io"
    kind: ClusterRole
  - group: "rbac.authorization.k8s.io"
    kind: ClusterRoleBinding
  - group: "rbac.authorization.k8s.io"
    kind: Role
  - group: "rbac.authorization.k8s.io"
    kind: RoleBinding
  - group: "admissionregistration.k8s.io"
    kind: ValidatingAdmissionWebhook
  - group: "admissionregistration.k8s.io"
    kind: MutatingAdmissionWebhook
  - group: "apiextensions.k8s.io"
    kind: CustomResourceDefinition
  - group: "karpenter.sh"
    kind: '*'
  - group: "karpenter.k8s.aws"
    kind: '*'
  namespaceResourceWhitelist:
  - group: ""
    kind: '*'
  - group: "apps"
    kind: '*'
  - group: "extensions"
    kind: '*'

---
# argocd/karpenter-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: karpenter-project
  source:
    repoURL: oci://public.ecr.aws/karpenter/karpenter
    targetRevision: "1.0.8"  # Versión estable más reciente de Karpenter
    chart: ""
    helm:
      values: |
        # Configuración para Karpenter v1.0+
        settings:
          clusterName: poc-kafka2
          # Para AWS
          aws:
            defaultInstanceProfile: KarpenterNodeRole-poc-kafka2
            enablePodENI: false
            enableENILimitedPodDensity: true
        
        # Configuración del controlador
        controller:
          image:
            repository: public.ecr.aws/karpenter/karpenter
          resources:
            requests:
              cpu: 1
              memory: 1Gi
            limits:
              cpu: 1
              memory: 1Gi
        
        # Service Account con anotación para IRSA
        serviceAccount:
          create: true
          name: karpenter
          annotations:
            eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/KarpenterNodeRole-poc-kafka2"
        
        # Tolerancias para el controlador
        tolerations:
          - key: CriticalAddonsOnly
            operator: Exists
        
        # Configuración de afinidad
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: karpenter.sh/provisioner-name
                  operator: DoesNotExist
        
        # Configuración de logs
        logLevel: info
        
        # Configuración del webhook
        webhook:
          enabled: true
          port: 8443
  
  destination:
    server: https://kubernetes.default.svc
    namespace: karpenter
  
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  
  revisionHistoryLimit: 5

---
# argocd/nodepool.yaml - Configuración de NodePool para Karpenter
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter-nodepool
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: karpenter-project
  source:
    repoURL: https://github.com/tu-usuario/karpenter-gitops  # Tu repositorio GitOps
    targetRevision: main
    path: nodepool
  destination:
    server: https://kubernetes.default.svc
    namespace: karpenter
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true