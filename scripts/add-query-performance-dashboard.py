#!/usr/bin/env python3
"""
Add Query Performance Dashboard to Grafana v2.5.0
Adds detailed query performance metrics to existing Solr dashboard
"""

import json
import sys
import os
from datetime import datetime

DASHBOARD_PATH = "monitoring/grafana/dashboards/solr-dashboard.json"

def add_query_performance_panels(dashboard):
    """Add query performance panels to dashboard"""

    # Get existing panels to determine next ID and position
    existing_panels = dashboard.get("panels", [])
    next_id = max([p.get("id", 0) for p in existing_panels], default=0) + 1
    next_y = max([p.get("gridPos", {}).get("y", 0) + p.get("gridPos", {}).get("h", 0)
                  for p in existing_panels], default=0)

    # Create new row for Query Performance
    query_row = {
        "collapsed": False,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": next_y},
        "id": next_id,
        "panels": [],
        "title": "Query Performance Analysis",
        "type": "row"
    }

    next_id += 1
    next_y += 1

    # Panel 1: Query Latency Percentiles (p50, p95, p99)
    panel_latency = {
        "id": next_id,
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": next_y},
        "type": "graph",
        "title": "Query Latency Percentiles",
        "description": "Query response time distribution (p50, p95, p99)",
        "targets": [
            {
                "expr": 'histogram_quantile(0.50, rate(solr_metrics_core_query_time_bucket{core=~"$core",instance=~"$instance"}[5m]))',
                "legendFormat": "p50 (median)",
                "refId": "A"
            },
            {
                "expr": 'histogram_quantile(0.95, rate(solr_metrics_core_query_time_bucket{core=~"$core",instance=~"$instance"}[5m]))',
                "legendFormat": "p95",
                "refId": "B"
            },
            {
                "expr": 'histogram_quantile(0.99, rate(solr_metrics_core_query_time_bucket{core=~"$core",instance=~"$instance"}[5m]))',
                "legendFormat": "p99",
                "refId": "C"
            }
        ],
        "yaxes": [
            {"format": "ms", "label": "Latency"},
            {"format": "short"}
        ],
        "xaxis": {"mode": "time", "show": True},
        "lines": True,
        "fill": 0,
        "linewidth": 2,
        "pointradius": 2,
        "points": False,
        "bars": False,
        "stack": False,
        "percentage": False,
        "legend": {
            "show": True,
            "values": True,
            "current": True,
            "max": True,
            "alignAsTable": True
        },
        "nullPointMode": "null",
        "tooltip": {"shared": True, "sort": 0, "value_type": "individual"},
        "thresholds": [
            {"value": 100, "colorMode": "critical", "op": "gt", "fill": True, "line": True},
            {"value": 500, "colorMode": "custom", "op": "gt", "fill": True, "line": True, "fillColor": "rgba(234, 112, 112, 0.2)", "lineColor": "rgb(234, 112, 112)"}
        ]
    }

    next_id += 1

    # Panel 2: Slow Query Count (>1s)
    panel_slow = {
        "id": next_id,
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": next_y},
        "type": "graph",
        "title": "Slow Queries (>1s)",
        "description": "Number of queries taking longer than 1 second",
        "targets": [
            {
                "expr": 'sum(rate(solr_metrics_core_query_time_bucket{core=~"$core",instance=~"$instance",le="1000"}[5m])) by (core)',
                "legendFormat": "{{core}} - queries >1s",
                "refId": "A"
            }
        ],
        "yaxes": [
            {"format": "reqps", "label": "Queries/sec"},
            {"format": "short"}
        ],
        "xaxis": {"mode": "time", "show": True},
        "lines": True,
        "fill": 2,
        "linewidth": 2,
        "pointradius": 2,
        "points": False,
        "bars": False,
        "stack": False,
        "percentage": False,
        "legend": {
            "show": True,
            "values": True,
            "current": True,
            "total": True,
            "alignAsTable": True
        },
        "nullPointMode": "null",
        "tooltip": {"shared": True, "sort": 2, "value_type": "individual"},
        "alert": {
            "name": "High Slow Query Rate",
            "conditions": [
                {
                    "evaluator": {"params": [10], "type": "gt"},
                    "operator": {"type": "and"},
                    "query": {"params": ["A", "5m", "now"]},
                    "reducer": {"params": [], "type": "avg"},
                    "type": "query"
                }
            ],
            "executionErrorState": "alerting",
            "frequency": "1m",
            "handler": 1,
            "message": "Slow query rate is high",
            "noDataState": "no_data",
            "notifications": []
        }
    }

    next_id += 1
    next_y += 8

    # Panel 3: Query Rate by Type
    panel_rate = {
        "id": next_id,
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": next_y},
        "type": "graph",
        "title": "Query Rate by Handler",
        "description": "Queries per second by request handler",
        "targets": [
            {
                "expr": 'sum(rate(solr_metrics_core_query_requests_total{core=~"$core",instance=~"$instance"}[5m])) by (handler)',
                "legendFormat": "{{handler}}",
                "refId": "A"
            }
        ],
        "yaxes": [
            {"format": "reqps", "label": "Queries/sec"},
            {"format": "short"}
        ],
        "xaxis": {"mode": "time", "show": True},
        "lines": True,
        "fill": 1,
        "linewidth": 2,
        "pointradius": 2,
        "points": False,
        "bars": False,
        "stack": True,
        "percentage": False,
        "legend": {
            "show": True,
            "values": True,
            "current": True,
            "total": True,
            "alignAsTable": True
        },
        "nullPointMode": "null as zero",
        "tooltip": {"shared": True, "sort": 2, "value_type": "individual"}
    }

    next_id += 1

    # Panel 4: Query Cache Hit Ratio
    panel_cache = {
        "id": next_id,
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": next_y},
        "type": "stat",
        "title": "Query Cache Hit Ratio",
        "description": "Percentage of queries served from cache",
        "targets": [
            {
                "expr": '100 * (rate(solr_metrics_core_query_result_cache_hits_total{core=~"$core",instance=~"$instance"}[5m]) / (rate(solr_metrics_core_query_result_cache_hits_total{core=~"$core",instance=~"$instance"}[5m]) + rate(solr_metrics_core_query_result_cache_misses_total{core=~"$core",instance=~"$instance"}[5m])))',
                "legendFormat": "{{core}}",
                "refId": "A"
            }
        ],
        "options": {
            "reduceOptions": {
                "values": False,
                "calcs": ["lastNotNull"],
                "fields": ""
            },
            "orientation": "auto",
            "textMode": "value_and_name",
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto"
        },
        "fieldConfig": {
            "defaults": {
                "unit": "percent",
                "decimals": 1,
                "min": 0,
                "max": 100,
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"value": 0, "color": "red"},
                        {"value": 50, "color": "yellow"},
                        {"value": 80, "color": "green"}
                    ]
                }
            }
        }
    }

    next_id += 1
    next_y += 8

    # Panel 5: Average Query Time Trend
    panel_trend = {
        "id": next_id,
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": next_y},
        "type": "graph",
        "title": "Average Query Time Trend",
        "description": "Average query execution time over time by core",
        "targets": [
            {
                "expr": 'rate(solr_metrics_core_query_time_sum{core=~"$core",instance=~"$instance"}[5m]) / rate(solr_metrics_core_query_requests_total{core=~"$core",instance=~"$instance"}[5m])',
                "legendFormat": "{{core}}",
                "refId": "A"
            }
        ],
        "yaxes": [
            {"format": "ms", "label": "Avg Time"},
            {"format": "short"}
        ],
        "xaxis": {"mode": "time", "show": True},
        "lines": True,
        "fill": 0,
        "linewidth": 2,
        "pointradius": 2,
        "points": False,
        "bars": False,
        "stack": False,
        "percentage": False,
        "legend": {
            "show": True,
            "values": True,
            "current": True,
            "avg": True,
            "max": True,
            "alignAsTable": True
        },
        "nullPointMode": "null",
        "tooltip": {"shared": True, "sort": 0, "value_type": "individual"},
        "thresholds": [
            {"value": 50, "colorMode": "custom", "op": "gt", "fill": False, "line": True, "lineColor": "rgba(245, 150, 40, 0.8)"},
            {"value": 100, "colorMode": "custom", "op": "gt", "fill": False, "line": True, "lineColor": "rgba(234, 112, 112, 0.8)"}
        ]
    }

    # Add all panels to dashboard
    dashboard["panels"].append(query_row)
    dashboard["panels"].append(panel_latency)
    dashboard["panels"].append(panel_slow)
    dashboard["panels"].append(panel_rate)
    dashboard["panels"].append(panel_cache)
    dashboard["panels"].append(panel_trend)

    # Update dashboard metadata
    dashboard["version"] = dashboard.get("version", 0) + 1
    dashboard["refresh"] = "30s"

    return dashboard

def main():
    """Main execution"""
    print("=" * 70)
    print("  Add Query Performance Dashboard v2.5.0")
    print("=" * 70)
    print()

    # Check if dashboard exists
    if not os.path.exists(DASHBOARD_PATH):
        print(f"❌ ERROR: Dashboard not found at {DASHBOARD_PATH}")
        sys.exit(1)

    # Backup original dashboard
    backup_path = f"{DASHBOARD_PATH}.backup-query-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    print(f"📦 Creating backup: {backup_path}")

    with open(DASHBOARD_PATH, 'r') as f:
        dashboard = json.load(f)

    with open(backup_path, 'w') as f:
        json.dump(dashboard, f, indent=2)

    print("✅ Backup created")
    print()

    # Add query performance panels
    print("🔧 Adding query performance panels...")
    dashboard = add_query_performance_panels(dashboard)
    print("✅ Added 6 new panels:")
    print("   - Query Latency Percentiles (p50, p95, p99)")
    print("   - Slow Queries (>1s)")
    print("   - Query Rate by Handler")
    print("   - Query Cache Hit Ratio")
    print("   - Average Query Time Trend")
    print()

    # Write updated dashboard
    print(f"💾 Writing updated dashboard to {DASHBOARD_PATH}")
    with open(DASHBOARD_PATH, 'w') as f:
        json.dump(dashboard, f, indent=2)

    print("✅ Dashboard updated successfully!")
    print()
    print("=" * 70)
    print("  Next Steps")
    print("=" * 70)
    print()
    print("1. Restart Grafana to load new dashboard:")
    print("   docker compose restart grafana")
    print()
    print("2. Open Grafana and navigate to Solr dashboard")
    print("   http://localhost:3000")
    print()
    print("3. Scroll down to see new 'Query Performance Analysis' section")
    print()
    print("Note: Some metrics require Solr Exporter with extended config.")
    print("      If panels show 'No data', check exporter configuration.")
    print()

if __name__ == "__main__":
    main()
