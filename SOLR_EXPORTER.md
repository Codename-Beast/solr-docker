# Solr Prometheus Exporter - Dokumentation

**Version**: 3.5.0
**Exporter**: Offizieller Apache Solr Prometheus Exporter
**Solr Version**: 9.9.0

---

## 📊 Übersicht

Dieses Setup verwendet den **offiziellen Apache Solr Prometheus Exporter**, der seit Solr 8.x direkt mit Solr ausgeliefert wird. Der Exporter befindet sich im Solr-Image unter `/opt/solr/contrib/prometheus-exporter/`.

### Warum der offizielle Exporter?

✅ **Vorteile:**
- Direkt von Apache Solr entwickelt und maintained
- Immer kompatibel mit der jeweiligen Solr-Version
- Umfangreiche Metrik-Abdeckung
- Flexible Konfiguration via XML
- Keine zusätzlichen Docker Images nötig
- Aktiv gewartet und dokumentiert

❌ **Alternative (nicht verwendet):**
- Drittanbieter-Exporter wie `mosuka/solr-exporter` sind veraltet
- Community-Exporter haben oft Kompatibilitätsprobleme
- Zusätzliche Maintenance-Burden

---

## 🏗️ Architektur

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Compose Stack                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐         ┌──────────────────┐              │
│  │              │         │                  │              │
│  │  Solr :8983  │────────▶│ Solr Exporter    │              │
│  │              │  Metrics│    :9854         │              │
│  └──────────────┘         └────────┬─────────┘              │
│                                    │                         │
│                                    │ Prometheus Format       │
│                                    │                         │
│                           ┌────────▼─────────┐              │
│                           │                  │              │
│                           │  Prometheus      │              │
│                           │    :9090         │              │
│                           └────────┬─────────┘              │
│                                    │                         │
│                                    │ PromQL                  │
│                                    │                         │
│                           ┌────────▼─────────┐              │
│                           │                  │              │
│                           │  Grafana :3000   │              │
│                           │                  │              │
│                           └──────────────────┘              │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Netzwerk-Segmentierung

- **Frontend Network (172.20.0.0/24)**: Solr, Grafana (extern erreichbar)
- **Backend Network (172.20.1.0/24)**: Exporter, Prometheus, Alertmanager (intern)

**Sicherheit**: Der Exporter ist standardmäßig nur im Backend-Netzwerk erreichbar und nur über `127.0.0.1:9854` vom Host zugreifbar.

---

## 🔧 Konfiguration

### 1. Exporter-Konfiguration (`config/solr-exporter-config.xml`)

Die Konfiguration erfolgt über eine XML-Datei, die folgende Metriken exportiert:

#### Kern-Metriken:

| Kategorie | Metriken | Beschreibung |
|-----------|----------|--------------|
| **Ping** | `solr_ping` | Solr Verfügbarkeit (1=OK, 0=FAILED) |
| **Core** | `solr_core_index_num_docs`<br>`solr_core_index_size_bytes`<br>`solr_core_index_deleted_docs` | Anzahl Dokumente<br>Index-Größe<br>Gelöschte Dokumente |
| **Query** | `solr_query_requests_total`<br>`solr_query_response_time_ms` | Anzahl Queries<br>Response-Zeit (mean, p50, p95, p99) |
| **Update** | `solr_update_requests_total`<br>`solr_update_response_time_ms` | Anzahl Updates<br>Update-Zeit |
| **Cache** | `solr_cache_lookups_total`<br>`solr_cache_hits_total`<br>`solr_cache_evictions_total` | Cache-Lookups<br>Cache-Hits<br>Cache-Evictions |
| **JVM** | `solr_jvm_heap_used_bytes`<br>`solr_jvm_gc_count_total`<br>`solr_jvm_gc_time_ms_total` | Heap-Auslastung<br>GC-Anzahl<br>GC-Zeit |
| **Node** | `solr_node_filesystem_total_bytes`<br>`solr_node_filesystem_usable_bytes` | Disk-Space Total<br>Disk-Space Frei |

#### Konfigurationsstruktur:

```xml
<config>
  <ping>
    <!-- Solr Ping Endpoint -->
  </ping>

  <metrics>
    <lst name="request">
      <lst name="query">
        <str name="path">/admin/metrics</str>
        <!-- Parameter -->
      </lst>
      <arr name="jsonQueries">
        <!-- jq-basierte Metrik-Extraktion -->
      </arr>
    </lst>
  </metrics>
</config>
```

**jq-Syntax**: Der Exporter verwendet `jq` (JSON-Prozessor) zur Extraktion von Metriken aus Solr's JSON-Responses.

### 2. Docker Compose Konfiguration

```yaml
solr-exporter:
  profiles: ["monitoring", "exporter-only"]
  image: solr:9.9.0
  volumes:
    - ./config/solr-exporter-config.xml:/opt/solr-exporter-config.xml:ro
  command: >
    bash -c "/opt/solr/contrib/prometheus-exporter/bin/solr-exporter
    -p 9854
    -b http://solr:8983/solr
    -f /opt/solr-exporter-config.xml
    -n 16"
  environment:
    JAVA_OPTS: "-Xms256m -Xmx512m"
```

#### Command-Line Parameter:

| Parameter | Wert | Beschreibung |
|-----------|------|--------------|
| `-p` | `9854` | Port für Prometheus Scraping |
| `-b` | `http://solr:8983/solr` | Solr Base URL |
| `-f` | `/opt/solr-exporter-config.xml` | Config-Datei Pfad |
| `-n` | `16` | Thread-Pool-Größe |

#### Environment:

- `JAVA_OPTS`: `-Xms256m -Xmx512m` (256 MB - 512 MB Heap)

### 3. Prometheus Konfiguration

```yaml
scrape_configs:
  - job_name: 'solr-exporter'
    scrape_interval: 10s
    scrape_timeout: 10s
    static_configs:
      - targets: ['solr-exporter:9854']
        labels:
          service: 'solr'
          instance: 'solr-main'
```

---

## 🚀 Deployment-Modi

### Modus 1: Minimal (Kein Monitoring)

```bash
docker compose up -d
```

Nur Solr läuft. Kein Exporter, kein Prometheus, kein Grafana.

### Modus 2: Exporter-Only (Remote Prometheus)

```bash
docker compose --profile exporter-only up -d
```

Nur Solr + Exporter. Für externe Prometheus-Instanzen.

**Zugriff auf Metriken:**
```bash
curl http://localhost:9854/metrics
```

### Modus 3: Full Monitoring Stack

```bash
docker compose --profile monitoring up -d
```

Komplett-Stack: Solr + Exporter + Prometheus + Grafana + Alertmanager.

**Zugriff:**
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (admin/admin)
- Alertmanager: http://localhost:9093

---

## 📈 Metriken Testen

### 1. Exporter Status

```bash
curl -s http://localhost:9854/metrics | head -20
```

**Erwartete Ausgabe:**
```
# HELP solr_ping Solr ping status (1 = OK, 0 = FAILED)
# TYPE solr_ping gauge
solr_ping 1.0

# HELP solr_core_index_num_docs Total number of indexed documents
# TYPE solr_core_index_num_docs gauge
solr_core_index_num_docs{core="moodle_customer_core"} 1234.0
...
```

### 2. Prometheus Targets

```bash
# Öffne Prometheus UI
make prometheus

# Navigiere zu: Status > Targets
# solr-exporter sollte "UP" sein
```

### 3. Grafana Dashboard

```bash
make grafana

# Login: admin / admin
# Dashboard: "Solr Performance Dashboard"
```

---

## 🔍 Metrik-Beispiele

### Query Performance

```promql
# Durchschnittliche Query-Zeit
rate(solr_query_response_time_ms{quantile="mean"}[5m])

# 95. Perzentil Query-Zeit
solr_query_response_time_ms{quantile="p95"}

# Queries pro Sekunde
rate(solr_query_requests_total[1m])
```

### Cache Efficiency

```promql
# Cache Hit Rate (%)
100 * (
  rate(solr_cache_hits_total[5m]) /
  rate(solr_cache_lookups_total[5m])
)
```

### Index Wachstum

```promql
# Dokument-Anzahl
solr_core_index_num_docs

# Index-Größe in GB
solr_core_index_size_bytes / 1024 / 1024 / 1024
```

### JVM Health

```promql
# Heap-Auslastung (%)
100 * (
  solr_jvm_heap_used_bytes /
  solr_jvm_heap_max_bytes
)

# GC-Rate (collections/sec)
rate(solr_jvm_gc_count_total[1m])
```

---

## 🛠️ Troubleshooting

### Problem: Exporter startet nicht

**Symptom:**
```
docker compose logs solr-exporter
ERROR: Failed to start exporter
```

**Lösung:**
```bash
# 1. Prüfe Config-Datei
xmllint --noout config/solr-exporter-config.xml

# 2. Prüfe Solr Erreichbarkeit
docker compose exec solr-exporter curl http://solr:8983/solr/admin/ping

# 3. Prüfe Logs
docker compose logs solr-exporter
```

### Problem: Keine Metriken

**Symptom:**
```bash
curl http://localhost:9854/metrics
# Leer oder nur HELP-Zeilen
```

**Lösung:**
```bash
# 1. Prüfe Solr Status
make health

# 2. Prüfe Exporter Config
docker compose exec solr-exporter cat /opt/solr-exporter-config.xml

# 3. Teste Solr Metrics API direkt
curl -u customer:password http://localhost:8983/solr/admin/metrics?wt=json
```

### Problem: Prometheus kann Exporter nicht scrapen

**Symptom:**
Prometheus Target "solr-exporter" ist "DOWN"

**Lösung:**
```bash
# 1. Prüfe Netzwerk-Connectivity
docker compose exec prometheus curl http://solr-exporter:9854/metrics

# 2. Prüfe Docker-Netzwerk
docker network ls
docker network inspect <CUSTOMER_NAME>_backend

# 3. Restart Exporter
docker compose restart solr-exporter
```

### Problem: Hoher Memory-Verbrauch

**Symptom:**
Exporter nutzt > 512 MB RAM

**Lösung:**
```bash
# 1. Reduziere Thread-Pool
# In docker-compose.yml: -n 8 statt -n 16

# 2. Reduziere Heap
# JAVA_OPTS: "-Xms128m -Xmx256m"

# 3. Reduziere Metrik-Abdeckung
# Entferne nicht benötigte Metriken aus config/solr-exporter-config.xml
```

---

## 📊 Erweiterte Konfiguration

### Eigene Metriken hinzufügen

**Beispiel: Facet-Count exportieren**

```xml
<lst name="request">
  <lst name="query">
    <str name="path">/solr/moodle_customer_core/select</str>
    <lst name="params">
      <str name="q">*:*</str>
      <str name="rows">0</str>
      <str name="facet">true</str>
      <str name="facet.field">type</str>
    </lst>
  </lst>
  <arr name="jsonQueries">
    <str>
      .facet_counts.facet_fields.type | to_entries | .[] |
      {
        name: "solr_facet_count",
        type: "GAUGE",
        help: "Facet count by type",
        label_names: ["type"],
        label_values: [.key],
        value: .value
      }
    </str>
  </arr>
</lst>
```

### Authentication

Wenn Solr BasicAuth aktiviert ist:

```bash
# Option 1: Via URL (in docker-compose.yml)
-b http://customer:password@solr:8983/solr

# Option 2: Via Environment (sicherer)
environment:
  JAVA_OPTS: "-Xms256m -Xmx512m"
  SOLR_AUTH_USER: "customer"
  SOLR_AUTH_PASSWORD: "password"
```

**Hinweis**: Aktuell nutzt der Exporter die interne Docker-Kommunikation ohne Auth. Die `/admin/metrics` Endpoint wird für Support-Rolle freigegeben.

---

## 📚 Ressourcen

### Offizielle Dokumentation

- **Solr Prometheus Exporter Guide**: https://solr.apache.org/guide/solr/latest/deployment-guide/monitoring-with-prometheus-and-grafana.html
- **Solr Metrics API**: https://solr.apache.org/guide/solr/latest/deployment-guide/metrics-reporting.html
- **Prometheus**: https://prometheus.io/docs/
- **Grafana**: https://grafana.com/docs/

### Exporter Source Code

Der Exporter ist Open Source und Teil des Solr-Projekts:
- **GitHub**: https://github.com/apache/solr/tree/main/solr/prometheus-exporter
- **JIRA**: https://issues.apache.org/jira/browse/SOLR (Component: prometheus-exporter)

### Community

- **Solr Mailing List**: solr-user@lucene.apache.org
- **Solr Slack**: https://solr.apache.org/community.html#slack

---

## 🔄 Updates

### Exporter Update (bei Solr-Update)

Da der Exporter Teil des Solr-Images ist, wird er automatisch aktualisiert:

```bash
# 1. Update SOLR_VERSION in .env
SOLR_VERSION=9.10.0

# 2. Pull neues Image
docker compose pull

# 3. Restart
make restart
```

### Config-Update

Nach Änderungen an `config/solr-exporter-config.xml`:

```bash
# 1. Validate XML
xmllint --noout config/solr-exporter-config.xml

# 2. Restart Exporter
docker compose restart solr-exporter

# 3. Verify Metriken
curl -s http://localhost:9854/metrics | grep -i "neue_metrik"
```

---

## ✅ Best Practices

### Performance

1. **Thread-Pool**: `-n 16` ist optimal für 1-5 Cores
2. **Scrape-Intervall**: 10-30 Sekunden (abhängig von Load)
3. **Timeout**: Immer < Scrape-Intervall
4. **Metrik-Reduktion**: Nur benötigte Metriken exportieren

### Sicherheit

1. **Netzwerk**: Exporter nur im Backend-Netzwerk
2. **Bind-IP**: `127.0.0.1` für lokalen Zugriff
3. **Firewall**: Port 9854 nicht öffentlich exponieren
4. **Auth**: Bei Remote-Zugriff BasicAuth aktivieren

### Monitoring

1. **Alerts**: Nutze `monitoring/prometheus/alerts.yml`
2. **Dashboards**: Grafana-Dashboard ist inkludiert
3. **Retention**: 30 Tage für Produktions-Metriken

### Wartung

1. **Log-Rotation**: Automatisch via Docker (10 MB, 3 files)
2. **Disk-Space**: Prometheus braucht ~1 GB/Tag bei default settings
3. **Backups**: Prometheus-Daten sind in Volume `prometheus_data`

---

## 📝 Changelog

### v3.5.0 (2025-11-10)
- ✅ Optimierte Exporter-Konfiguration hinzugefügt
- ✅ Dokumentation erstellt
- ✅ Custom metrics für Moodle-Workloads
- ✅ Debian-Kompatibilität sichergestellt

### v3.3.0 (vorher)
- ✅ Offizieller Solr Exporter integriert
- ✅ Netzwerk-Segmentierung implementiert
- ✅ Prometheus + Grafana Setup

---

**Autor**: Codename-Beast(BSC)
**Organisation**: Eledia GmbH
**Lizenz**: Apache License 2.0 (wie Apache Solr)
