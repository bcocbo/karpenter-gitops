# Análisis y Optimización de Karpenter en EKS  
**Entorno:** `eks-skillfullers-dev` (QA/Dev) → Producción  
**Objetivo:** Validar configuración actual + **máximo ahorro de costos** con **mínima disrupción**  
**Herramientas:** Karpenter v1.6.2, AL2023/Bottlerocket, Spot, gp3, EKS  
**Fecha:** 30 de octubre de 2025  

---

## 1. Análisis de Archivos Originales

### `Anexo5_nodepool.yaml` → **NodePool `spotvng`**
```yaml
consolidationPolicy: WhenEmptyOrUnderutilized
consolidateAfter: 20m
expireAfter: 720h
capacity-type: ["spot", "on-demand"]
instance-size: [4xlarge, 8xlarge, 9xlarge]
instance-generation: Gt 4