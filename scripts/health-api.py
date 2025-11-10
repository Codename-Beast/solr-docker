#!/usr/bin/env python3
"""
Solr Health API
Version: 1.0.0

Provides JSON status endpoint:
- Solr health status
- Core information
- System metrics
- Configuration status

Usage:
    python health-api.py

Endpoints:
    GET /health  - Full health status
    GET /ping    - Simple ping check
"""

import json
import os
import sys
import base64
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen, Request
from urllib.error import URLError
import socket

SOLR_URL = os.getenv('SOLR_URL', 'http://solr:8983')
CUSTOMER_NAME = os.getenv('CUSTOMER_NAME', 'default')
SOLR_ADMIN_USER = os.getenv('SOLR_ADMIN_USER', '')
SOLR_ADMIN_PASSWORD = os.getenv('SOLR_ADMIN_PASSWORD', '')
PORT = 8888


def create_auth_request(url, timeout=5):
    """Create authenticated request if credentials are provided"""
    request = Request(url)
    if SOLR_ADMIN_USER and SOLR_ADMIN_PASSWORD:
        credentials = f"{SOLR_ADMIN_USER}:{SOLR_ADMIN_PASSWORD}"
        encoded_credentials = base64.b64encode(credentials.encode()).decode()
        request.add_header("Authorization", f"Basic {encoded_credentials}")
    return urlopen(request, timeout=timeout)


class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        """Suppress default logging"""
        pass

    def do_GET(self):
        if self.path == '/health':
            self.handle_health()
        elif self.path == '/ping':
            self.handle_ping()
        else:
            self.send_error(404, "Not Found")

    def handle_ping(self):
        """Simple ping endpoint"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())

    def handle_health(self):
        """Comprehensive health check"""
        health_data = {
            "customer": CUSTOMER_NAME,
            "version": "2.2.0",
            "status": "unknown",
            "solr": {},
            "cores": [],
            "system": {},
            "errors": []
        }

        try:
            # Check Solr availability
            solr_health = self.check_solr()
            health_data["solr"] = solr_health

            if solr_health.get("available"):
                health_data["status"] = "healthy"

                # Get cores information
                cores = self.get_cores()
                health_data["cores"] = cores

                # Get system info
                system_info = self.get_system_info()
                health_data["system"] = system_info
            else:
                health_data["status"] = "unhealthy"
                health_data["errors"].append("Solr is not available")

        except Exception as e:
            health_data["status"] = "error"
            health_data["errors"].append(str(e))

        # Send response
        status_code = 200 if health_data["status"] == "healthy" else 503
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(health_data, indent=2).encode())

    def check_solr(self):
        """Check if Solr is responding"""
        try:
            response = create_auth_request(f"{SOLR_URL}/solr/admin/ping?wt=json")
            data = json.loads(response.read())
            return {
                "available": True,
                "status": data.get("status"),
                "response_time_ms": data.get("responseHeader", {}).get("QTime", 0)
            }
        except URLError as e:
            return {
                "available": False,
                "error": str(e)
            }
        except Exception as e:
            return {
                "available": False,
                "error": f"Unexpected error: {str(e)}"
            }

    def get_cores(self):
        """Get list of Solr cores"""
        try:
            response = create_auth_request(f"{SOLR_URL}/solr/admin/cores?action=STATUS&wt=json")
            data = json.loads(response.read())
            cores = []

            for core_name, core_data in data.get("status", {}).items():
                if core_name:  # Skip empty keys
                    cores.append({
                        "name": core_name,
                        "num_docs": core_data.get("index", {}).get("numDocs", 0),
                        "size_mb": round(core_data.get("index", {}).get("sizeInBytes", 0) / 1024 / 1024, 2),
                        "last_modified": core_data.get("index", {}).get("lastModified", "unknown")
                    })

            return cores
        except Exception as e:
            return [{"error": str(e)}]

    def get_system_info(self):
        """Get Solr system information"""
        try:
            response = create_auth_request(f"{SOLR_URL}/solr/admin/info/system?wt=json")
            data = json.loads(response.read())

            jvm = data.get("jvm", {})
            memory = jvm.get("memory", {}).get("raw", {})

            return {
                "solr_version": data.get("lucene", {}).get("solr-spec-version", "unknown"),
                "jvm_version": jvm.get("version", "unknown"),
                "memory": {
                    "used_mb": round(memory.get("used", 0) / 1024 / 1024, 2),
                    "total_mb": round(memory.get("total", 0) / 1024 / 1024, 2),
                    "max_mb": round(memory.get("max", 0) / 1024 / 1024, 2),
                    "usage_percent": round((memory.get("used", 0) / memory.get("max", 1)) * 100, 2) if memory.get("max") else 0
                },
                "uptime_seconds": data.get("jvm", {}).get("jmx", {}).get("upTimeMS", 0) // 1000
            }
        except Exception as e:
            return {"error": str(e)}


def main():
    """Start health API server"""
    server_address = ('', PORT)
    httpd = HTTPServer(server_address, HealthHandler)

    print(f"Health API starting on port {PORT}")
    print(f"Solr URL: {SOLR_URL}")
    print(f"Customer: {CUSTOMER_NAME}")
    print(f"Endpoints: /health, /ping")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        httpd.shutdown()
        sys.exit(0)


if __name__ == '__main__':
    main()
