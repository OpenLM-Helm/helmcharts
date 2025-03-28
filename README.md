# OpenLM Helm Charts
---
## Description

OpenLM Helm Chart Repo that holds helm charts for OpenLM services.

> [!note]
> Each helm chart holds a microservice

[OpenLM Annapurna Documentation](openlm.com/documentation)

---
## Cluster preparations

We provide a collection of shell scripts for making the installation easier.

- `setup.sh`
- `grafana.sh`
- `deploy.sh`

The documentation will break down the steps of the scripts so it's possible to  
install without them as well as long as the requiremnts are met.

### Cluster preparations

Before any olm service deployment the next Kubernetes objects have to be created.  

The `setup.sh` can be used to easely create (1),(2) & (3).

1. Kubernetes Namespaces

    - openlm
    - openlm-telemetry
    - openlm-infrastructure

2. Kubernetes secrets

    | Secret Name | Namespace |
    | --- | --- |
    | openlm-lb-cert |openlm,openlm-telemetry |
    | kafkaui-lb-cert |openlm-infrastructure |

>[!Note]
>The `setup.sh` by default will add self-signed certificates. 

3. Download & Extract the openlm-infrastructure.tgz .

>[!Note]
>LoadBalancer & domain is not set by the `setup.sh` script.

4. Update openlm-infrastructure files

    - Change kafka ui var

    ``` sh
    find openlm-infrastructure/ -name "*.yaml" -type f -print0 | xargs -0 -I {} sed -i 's|\$KAFKAUI_HOST|kafkaui-dev-k8s-us-cloud.openlm.com|g' {}
    ```

    - Change domain var

    ``` sh
    find openlm-infrastructure/ -name "*.yaml" -type f -print0 | xargs -0 -I {} sed -i 's|\$LB_FQDN|dev-k8s-us-cloud.openlm.com|g' {}
    ```

    - Change nginx var

    ``` sh
    find openlm-infrastructure/ -name "*.yaml" -type f -print0 | xargs -0 -I {} sed -i 's|ingressClassName: public|ingressClassName: nginx|g' {}
    ```

    - Change storageclass in the following files
    You can do it via cli
    ``` sh
    find openlm-infrastructure/ -name "*.yaml" -type f -print0 | xargs -0 -I {} sed -i 's|storageClassName: public|storageClassName: nginx|g' {}
    ```

    grafana-operator/grafana.template.yaml:      storageClassName: harvester
    loki/values.template.yaml:    storageClass: harvester
    tempo/values.template.yaml:  storageClassName: harvester
    kube-prometheus-stack/values.template.yaml:          storageClassName: harvester

    - Inside openlm-infrastructure/grafana-operator/grafana.template.yaml change the next val(usually do bypas permissions issues)
        - runAsGroup: 0
        - runAsUser: 0
        - runAsNonRoot: false


### Grafana Deployment

`grafana.sh` allows to deploy the grafana deployments either one by one  
    or all at the same time.

###### Kafka and single component

``` sh
grafana.sh \
-n openlm-infrastructure \
-c /opt/helm/openlm-infrastructure \
-d kafka-ui/kafka-ui-0.7.5.tgz \
-v /opt/helm/openlm-infrastructure/kafka-ui/values.template.yaml \
-r kafkaui
```

###### Deploy all Grafana components with custom values and custom manifest lists

``` sh
grafana.sh \
-n openlm-telemetry \
-c /opt/helm/openlm-infrastructure \
-d loki/loki-5.41.4.tgz,promtail/promtail-6.15.3.tgz,tempo/tempo-1.7.1.tgz,kube-prometheus-stack/kube-prometheus-stack-56.7.0.tgz,otel-collector/opentelemetry-collector-0.77.0.tgz,grafana-operator/grafana-operator-v5.6.3.tgz \
-v /opt/helm/openlm-infrastructure/loki/values.template.yaml,/opt/helm/openlm-infrastructure/promtail/values.template.yaml,openlm-infrastructure/tempo/values.template.yaml,openlm-infrastructure/kube-prometheus-stack/values.template.yaml,openlm-infrastructure/otel-collector/values.template.yaml \
-r grafana-loki,grafana-promtail,grafana-tempo,kube-prometheus-stack,otel-collector,grafana-operator \
-m kube-prometheus-stack/otel-collector-scrape-config.yaml,kube-prometheus-stack/nginx-ingress-scrape-config.template.yaml,grafana-operator/grafana.template.yaml,grafana-operator/datasources/prometheus-datasource.yaml,grafana-operator/datasources/loki-datasource.yaml,grafana-operator/datasources/tempo-datasource.yaml,grafana-operator/dashboards
```

---
## OpenLM Service Deployment

OpenLM Helm Chart provides `deploy.sh` script to facilitate the deployment process.  
You can run the script as follows:

### Usage Examples

1) List available charts in the repo
``` sh
./deploy -l
```

2) Download chart
``` sh
./deploy.sh -d servicenowalertintegration.tgz
```

3) Extract
``` sh
./deploy.sh -e -c servicenowalertintegration.tgz
```

4) Install chart
``` sh
./deploy.sh -c servicenowalertintegration
```

5) Uninstall 
``` sh
./deploy.sh -u -c servicenowalertintegration
```

6) For a full list of options:
``` sh
./deploy -h
```


>[!Note]
>You are free to use other installation methods for helm charts. Keep in mind  
>many services might require you to update the values.yaml before deployment.
