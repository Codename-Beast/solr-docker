#!/bin/sh
# Solr Init Container - Configuration Deployment
# Version: 3.3.0 - FIXED: Security.json Persistence
#
# CRITICAL FIX: security.json is now preserved across restarts
# to maintain tenant user credentials

set -e

echo "========================================="
echo "Solr Configuration Deployment v3.3.0"
echo "========================================="

# Install validation tools
echo "[1/6] Installing validation tools..."
apk add --no-cache jq libxml2-utils 2>&1 | grep -v 'fetch\|OK:' || true

# Create directory structure
echo "[2/6] Creating directory structure..."
mkdir -p /var/solr/data /var/solr/data/configs /var/solr/data/lang /var/solr/backup/configs
mkdir -p /var/solr/logs /var/solr/backups
mkdir -p /var/solr/data/configsets

# Create moodle configSet with full schema (needed for core creation)
if [ ! -d /var/solr/data/configsets/moodle ]; then
    echo "[2b/6] Creating moodle configSet with schema..."
    mkdir -p /var/solr/data/configsets/moodle/conf

    # Create solrconfig.xml
    cat > /var/solr/data/configsets/moodle/conf/solrconfig.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<config>
  <luceneMatchVersion>9.9</luceneMatchVersion>
  <dataDir>${solr.data.dir:}</dataDir>
  <directoryFactory name="DirectoryFactory" class="${solr.directoryFactory:solr.NRTCachingDirectoryFactory}"/>
  <codecFactory class="solr.SchemaCodecFactory"/>
  <schemaFactory class="ClassicIndexSchemaFactory"/>
  <updateHandler class="solr.DirectUpdateHandler2">
    <updateLog>
      <str name="dir">${solr.ulog.dir:}</str>
    </updateLog>
    <autoCommit>
      <maxTime>${solr.autoCommit.maxTime:15000}</maxTime>
      <openSearcher>false</openSearcher>
    </autoCommit>
    <autoSoftCommit>
      <maxTime>${solr.autoSoftCommit.maxTime:1000}</maxTime>
    </autoSoftCommit>
  </updateHandler>
  <requestHandler name="/select" class="solr.SearchHandler">
    <lst name="defaults">
      <str name="echoParams">explicit</str>
      <int name="rows">10</int>
    </lst>
  </requestHandler>
  <requestHandler name="/update" class="solr.UpdateRequestHandler"/>
  <requestHandler name="/admin/ping" class="solr.PingRequestHandler">
    <lst name="invariants">
      <str name="q">solrpingquery</str>
    </lst>
    <lst name="defaults">
      <str name="echoParams">all</str>
    </lst>
  </requestHandler>
</config>
EOF

    # Copy stopwords files
    mkdir -p /var/solr/data/configsets/moodle/conf/lang
    if [ -f /lang/stopwords.txt ]; then
        cp /lang/stopwords.txt /var/solr/data/configsets/moodle/conf/lang/
        echo "  ✓ Stopwords files copied"
    fi
    if [ -f /lang/stopwords_de.txt ]; then
        cp /lang/stopwords_de.txt /var/solr/data/configsets/moodle/conf/lang/
    fi
    if [ -f /lang/stopwords_en.txt ]; then
        cp /lang/stopwords_en.txt /var/solr/data/configsets/moodle/conf/lang/
    fi

    # Copy Moodle schema from config directory
    if [ -f /config/moodle_schema.xml ]; then
        cp /config/moodle_schema.xml /var/solr/data/configsets/moodle/conf/schema.xml
        echo "  ✓ Moodle schema copied"
    else
        echo "  ⚠ moodle_schema.xml not found, using minimal schema"
        # Fallback to minimal schema
        cat > /var/solr/data/configsets/moodle/conf/schema.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<schema name="moodle-schema" version="1.6">
  <uniqueKey>id</uniqueKey>
  <fieldType name="string" class="solr.StrField" sortMissingLast="true" docValues="true"/>
  <fieldType name="plong" class="solr.LongPointField" docValues="true"/>
  <fieldType name="text_general" class="solr.TextField" positionIncrementGap="100">
    <analyzer type="index">
      <tokenizer class="solr.StandardTokenizerFactory"/>
      <filter class="solr.LowerCaseFilterFactory"/>
    </analyzer>
    <analyzer type="query">
      <tokenizer class="solr.StandardTokenizerFactory"/>
      <filter class="solr.LowerCaseFilterFactory"/>
    </analyzer>
  </fieldType>
  <field name="id" type="string" indexed="true" stored="true" required="true" multiValued="false"/>
  <field name="_version_" type="plong" indexed="false" stored="false"/>
  <field name="_root_" type="string" indexed="true" stored="false" docValues="false"/>
  <field name="_text_" type="text_general" indexed="true" stored="false" multiValued="true"/>
</schema>
EOF
    fi

    echo "  ✓ Moodle configSet created"
fi

# CRITICAL FIX: Intelligent security.json deployment
echo "[3/6] Handling security.json deployment..."
if [ ! -f /var/solr/data/security.json ]; then
    echo "  ✓ First run detected - deploying initial security.json"
    cp /config/security.json /var/solr/data/security.json
    chmod 600 /var/solr/data/security.json
    chown 8983:8983 /var/solr/data/security.json
else
    echo "  ℹ️  security.json already exists - preserving (contains tenant data)"

    # Create backup before any potential merge
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp /var/solr/data/security.json /var/solr/backup/configs/security.json.$TIMESTAMP 2>/dev/null || true
    echo "  ✓ Backup created: security.json.$TIMESTAMP"

    # Optional: Merge new admin users from template without destroying tenant users
    if [ -f /config/security.json ]; then
        echo "  ℹ️  Checking for new admin users in template..."

        EXISTING_JSON="/var/solr/data/security.json"
        TEMPLATE_JSON="/config/security.json"
        TEMP_JSON="/tmp/security_merged_$$.json"

        # Use jq to merge only admin credentials if they don't exist yet
        # This allows adding admin users without destroying tenant users
        if jq -s '
            .[0] as $existing |
            .[1] as $template |
            $existing |
            # Merge admin/support credentials from template if missing
            .authentication.credentials += (
                $template.authentication.credentials |
                to_entries |
                map(select(.key | test("admin|support"))) |
                map(select(.key as $k | ($existing.authentication.credentials | has($k) | not))) |
                from_entries
            )
        ' "$EXISTING_JSON" "$TEMPLATE_JSON" > "$TEMP_JSON" 2>/dev/null; then

            # Validate merged JSON
            if jq empty "$TEMP_JSON" 2>/dev/null; then
                # Check if merge produced changes
                if ! diff -q "$EXISTING_JSON" "$TEMP_JSON" >/dev/null 2>&1; then
                    mv "$TEMP_JSON" "$EXISTING_JSON"
                    chmod 600 "$EXISTING_JSON"
                    chown 8983:8983 "$EXISTING_JSON"
                    echo "  ✓ Merged new admin users from template"
                else
                    rm "$TEMP_JSON"
                    echo "  ℹ️  No new admin users to merge"
                fi
            else
                echo "  ⚠️  Merge validation failed, keeping existing security.json"
                rm "$TEMP_JSON"
            fi
        else
            echo "  ⚠️  Merge failed, keeping existing security.json"
            rm -f "$TEMP_JSON"
        fi
    fi
fi

# Validate security.json
echo "[4/6] Validating security.json..."
if ! jq empty /var/solr/data/security.json 2>/dev/null; then
    echo "❌ ERROR: Invalid JSON in security.json"
    exit 1
fi

# Check for required credentials
CRED_COUNT=$(jq '.authentication.credentials | length' /var/solr/data/security.json)
if [ "$CRED_COUNT" -lt 1 ]; then
    echo "❌ ERROR: No credentials defined in security.json"
    exit 1
fi

echo "  ✓ security.json is valid ($CRED_COUNT users)"

# Validate other configuration files
echo "[5/6] Validating other configuration files..."
validate_file() {
    FILE=$1
    TYPE=$2

    if [ ! -f "$FILE" ]; then
        echo "  ⚠ Skipping $FILE (not found)"
        return 0
    fi

    echo "  ✓ Validating $(basename $FILE)"

    if [ "$TYPE" = "json" ]; then
        if ! jq empty "$FILE" 2>/dev/null; then
            echo "ERROR: Invalid JSON in $FILE"
            return 1
        fi
    elif [ "$TYPE" = "xml" ]; then
        if ! xmllint --noout "$FILE" 2>/dev/null; then
            echo "ERROR: Invalid XML in $FILE"
            return 1
        fi
    fi

    return 0
}

validate_file /config/solrconfig.xml xml || exit 1
validate_file /config/moodle_schema.xml xml || exit 1

# Deploy other configuration files (these can be safely overwritten)
echo "[6/6] Deploying other configuration files..."
deploy_file() {
    SRC=$1
    DEST=$2

    if [ -f "$SRC" ]; then
        echo "  ✓ Deploying $(basename $SRC)"
        cp "$SRC" "$DEST"
    fi
}

deploy_file /config/solrconfig.xml /var/solr/data/configs/solrconfig.xml
deploy_file /config/moodle_schema.xml /var/solr/data/configs/moodle_schema.xml
deploy_file /config/synonyms.txt /var/solr/data/configs/synonyms.txt
deploy_file /config/protwords.txt /var/solr/data/configs/protwords.txt
deploy_file /lang/stopwords.txt /var/solr/data/lang/stopwords.txt
deploy_file /lang/stopwords_de.txt /var/solr/data/lang/stopwords_de.txt
deploy_file /lang/stopwords_en.txt /var/solr/data/lang/stopwords_en.txt

# Set permissions
echo "Setting permissions..."
chown -R 8983:8983 /var/solr
chmod 600 /var/solr/data/security.json 2>/dev/null || true

echo "========================================="
echo "Deployment: SUCCESS"
echo "  - security.json: PRESERVED (tenants intact)"
echo "  - Other configs: UPDATED"
echo "========================================="
exit 0
