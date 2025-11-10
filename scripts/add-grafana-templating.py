#!/usr/bin/env python3
"""
Add Grafana Templating to Dashboard
Adds template variables for multi-instance support
"""

import json
import sys

dashboard_path = sys.argv[1] if len(sys.argv) > 1 else 'monitoring/grafana/dashboards/solr-dashboard.json'

# Read dashboard
with open(dashboard_path, 'r') as f:
    dashboard = json.load(f)

# Add templating section
dashboard['templating'] = {
    "list": [
        {
            "current": {
                "selected": False,
                "text": "All",
                "value": "$__all"
            },
            "datasource": "Prometheus",
            "definition": "label_values(up{job=\"solr-exporter\"}, instance)",
            "hide": 0,
            "includeAll": True,
            "label": "Instance",
            "multi": True,
            "name": "instance",
            "options": [],
            "query": {
                "query": "label_values(up{job=\"solr-exporter\"}, instance)",
                "refId": "StandardVariableQuery"
            },
            "refresh": 1,
            "regex": "",
            "skipUrlSync": False,
            "sort": 1,
            "type": "query"
        },
        {
            "current": {
                "selected": False,
                "text": "solr-exporter",
                "value": "solr-exporter"
            },
            "datasource": "Prometheus",
            "definition": "label_values(up, job)",
            "hide": 0,
            "includeAll": False,
            "label": "Job",
            "multi": False,
            "name": "job",
            "options": [],
            "query": {
                "query": "label_values(up, job)",
                "refId": "StandardVariableQuery"
            },
            "refresh": 1,
            "regex": ".*solr.*",
            "skipUrlSync": False,
            "sort": 0,
            "type": "query"
        },
        {
            "allValue": "",
            "current": {
                "selected": False,
                "text": "All",
                "value": "$__all"
            },
            "datasource": "Prometheus",
            "definition": "label_values(solr_metrics_core_query_requests_total, core)",
            "hide": 0,
            "includeAll": True,
            "label": "Core",
            "multi": True,
            "name": "core",
            "options": [],
            "query": {
                "query": "label_values(solr_metrics_core_query_requests_total, core)",
                "refId": "StandardVariableQuery"
            },
            "refresh": 1,
            "regex": "",
            "skipUrlSync": False,
            "sort": 1,
            "type": "query"
        }
    ]
}

# Update all panel queries to use template variables
for panel in dashboard.get('panels', []):
    if 'targets' in panel:
        for target in panel['targets']:
            if 'expr' in target:
                # Add instance filter if not present
                expr = target['expr']
                if 'instance=' not in expr and 'job="solr-exporter"' in expr:
                    expr = expr.replace('job="solr-exporter"', 'job="$job",instance=~"$instance"')
                elif 'job="solr-exporter"' in expr:
                    expr = expr.replace('job="solr-exporter"', 'job="$job"')

                # Add core filter where applicable
                if 'core=' not in expr and 'solr_metrics_core' in expr:
                    if 'core="' in expr:
                        # Already has hardcoded core, replace it
                        import re
                        expr = re.sub(r'core="[^"]*"', 'core=~"$core"', expr)
                    elif '}' in expr:
                        # Add core filter before closing brace
                        expr = expr.replace('}', ',core=~"$core"}')

                target['expr'] = expr

# Update title to show it supports multiple instances
dashboard['title'] = 'Solr Monitoring (Multi-Instance)'
dashboard['description'] = 'Solr performance monitoring dashboard with support for multiple instances. Use template variables to filter by instance, job, and core.'

# Update version
dashboard['version'] = dashboard.get('version', 0) + 1

# Write updated dashboard
with open(dashboard_path, 'w') as f:
    json.dump(dashboard, f, indent=2)

print(f"✓ Added templating to {dashboard_path}")
print("  - Instance variable (multi-select)")
print("  - Job variable")
print("  - Core variable (multi-select)")
print("  - Updated all queries to use template variables")
