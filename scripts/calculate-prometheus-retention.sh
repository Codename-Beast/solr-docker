#!/usr/bin/env bash
# Prometheus Retention Calculator v2.5.0
# Calculates optimal Prometheus retention time based on available disk space

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || {
    echo "Error: Failed to load common.sh library"
    exit 1
}

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default values (can be overridden via command line)
AVAILABLE_DISK_GB=${1:-50}
SCRAPE_INTERVAL_SEC=${2:-15}
METRICS_PER_SCRAPE=${3:-1000}
BYTES_PER_METRIC=${4:-5}
SAFETY_MARGIN_PERCENT=${5:-80}

# ============================================================================
# DISPLAY BANNER
# ============================================================================

cat <<'EOF'
═══════════════════════════════════════════════════════════════
  Prometheus Retention Calculator v2.5.0
═══════════════════════════════════════════════════════════════
EOF

echo ""

# ============================================================================
# CALCULATION
# ============================================================================

log_info "Calculating optimal Prometheus retention..."
echo ""

echo "Input Parameters:"
echo "  Available Disk Space:  ${AVAILABLE_DISK_GB} GB"
echo "  Scrape Interval:       ${SCRAPE_INTERVAL_SEC} seconds"
echo "  Metrics per Scrape:    ${METRICS_PER_SCRAPE}"
echo "  Bytes per Metric:      ${BYTES_PER_METRIC}"
echo "  Safety Margin:         ${SAFETY_MARGIN_PERCENT}%"
echo ""

# Calculate samples per day
samples_per_day=$(( (86400 / SCRAPE_INTERVAL_SEC) * METRICS_PER_SCRAPE ))
log_debug "Samples per day: $samples_per_day"

# Calculate bytes per day
bytes_per_day=$(( samples_per_day * BYTES_PER_METRIC ))
log_debug "Bytes per day: $bytes_per_day"

# Convert available disk to bytes
available_bytes=$(( AVAILABLE_DISK_GB * 1024 * 1024 * 1024 ))
log_debug "Available bytes: $available_bytes"

# Apply safety margin (use only N% of available space)
safe_bytes=$(( available_bytes * SAFETY_MARGIN_PERCENT / 100 ))
log_debug "Safe bytes (${SAFETY_MARGIN_PERCENT}%): $safe_bytes"

# Calculate retention in days
retention_days=$(( safe_bytes / bytes_per_day ))

# ============================================================================
# DISPLAY RESULTS
# ============================================================================

log_success "Calculation complete!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Storage Estimates:"
echo "  Samples per Day:       $(printf "%'d" $samples_per_day)"
echo "  Storage per Day:       $(printf "%.2f" $(echo "scale=2; $bytes_per_day / 1024 / 1024" | bc)) MB"
echo "  Storage per Month:     $(printf "%.2f" $(echo "scale=2; $bytes_per_day * 30 / 1024 / 1024 / 1024" | bc)) GB"
echo ""
echo "Recommended Retention:"
echo "  Retention Days:        ${retention_days} days"
echo "  Retention Weeks:       $(( retention_days / 7 )) weeks"
echo "  Retention Months:      $(( retention_days / 30 )) months"
echo ""

# ============================================================================
# CONFIGURATION RECOMMENDATIONS
# ============================================================================

echo "═══════════════════════════════════════════════════════════════"
echo "  CONFIGURATION"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Add to your .env file:"
echo ""
echo "  PROMETHEUS_RETENTION=${retention_days}d"
echo ""

# Generate alternative recommendations
echo "Alternative Retention Options:"
echo ""

# Conservative (60% disk usage)
conservative_days=$(( safe_bytes * 60 / 100 / bytes_per_day ))
echo "  Conservative (60% disk): PROMETHEUS_RETENTION=${conservative_days}d"

# Moderate (80% disk usage) - DEFAULT
moderate_days=$(( safe_bytes * 80 / 100 / bytes_per_day ))
echo "  Moderate (80% disk):     PROMETHEUS_RETENTION=${moderate_days}d  ← Recommended"

# Aggressive (95% disk usage)
aggressive_days=$(( safe_bytes * 95 / 100 / bytes_per_day ))
echo "  Aggressive (95% disk):   PROMETHEUS_RETENTION=${aggressive_days}d"

echo ""

# ============================================================================
# WARNINGS
# ============================================================================

if [ $retention_days -lt 7 ]; then
    log_warn "Retention < 7 days: Consider allocating more disk space!"
elif [ $retention_days -lt 30 ]; then
    log_warn "Retention < 30 days: Acceptable but limited historical data"
elif [ $retention_days -gt 365 ]; then
    log_warn "Retention > 1 year: Consider downsampling or remote storage"
else
    log_success "Retention is within recommended range (30-365 days)"
fi

echo ""

# ============================================================================
# ADDITIONAL TIPS
# ============================================================================

cat <<'EOF'
═══════════════════════════════════════════════════════════════
  OPTIMIZATION TIPS
═══════════════════════════════════════════════════════════════

1. Increase Scrape Interval
   - Change from 15s to 30s: Doubles retention!
   - Edit: monitoring/prometheus/prometheus.yml
   - Trade-off: Lower resolution metrics

2. Reduce Metric Cardinality
   - Remove unused labels
   - Use recording rules for aggregations
   - Filter unnecessary metrics in scrape config

3. Add More Disk Space
   - Mount larger volume for Prometheus data
   - Use network storage (NFS, EBS, etc.)

4. Enable Remote Write (Long-term Storage)
   - Thanos: https://thanos.io/
   - Cortex: https://cortexmetrics.io/
   - Grafana Cloud: https://grafana.com/products/cloud/

5. Compaction Settings
   - Prometheus automatically compacts blocks
   - Older blocks are less granular (downsampled)
   - Configure retention by size: --storage.tsdb.retention.size

Example with size-based retention:
  docker-compose.yml:
    command:
      - '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-30d}'
      - '--storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE:-45GB}'

═══════════════════════════════════════════════════════════════
EOF

echo ""
log_info "Calculation complete. Update your .env file and restart Prometheus."

# ============================================================================
# USAGE EXAMPLES
# ============================================================================

if [ "$AVAILABLE_DISK_GB" -eq 50 ]; then
    echo ""
    echo "Usage Examples:"
    echo "  $0 100              # 100GB available disk"
    echo "  $0 100 30           # 100GB disk, 30s scrape interval"
    echo "  $0 100 30 2000      # 100GB disk, 30s interval, 2000 metrics"
    echo "  $0 100 30 2000 10   # Custom bytes per metric"
    echo "  $0 100 30 2000 10 70 # 70% safety margin"
fi
