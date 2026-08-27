#!/bin/bash
set -e

# --- System Update & Base packages -------------------------------------
# Run apt update to ensure packages are current before installation
apt-get update -y
apt-get install -y nginx stress python3 python3-pip python3-flask ruby wget curl

# --- CodeDeploy agent ----------------------------------------------------
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" http://169.254.169.254/latest/meta-data/placement/region)

cd /home/ubuntu
wget https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install
chmod +x ./install
./install auto

systemctl enable codedeploy-agent
systemctl start codedeploy-agent

# --- Deploy simple Flask App for /health check & CPU Stress Test -------
mkdir -p /opt/backend-app

cat > /home/ubuntu/app.py << 'EOF'
from flask import Flask
import subprocess

app = Flask(__name__)

@app.route('/health')
def health():
    return "Backend is Healthy", 200

@app.route('/')
def home():
    return "3-Tier Backend Application Running on Ubuntu!"

@app.route('/stress')
def stress():
    # Launches the CPU stress tool in the background for 3 minutes (180 seconds)
    subprocess.Popen(["stress", "--cpu", "4", "--timeout", "180"])
    return "CPU Stress Test Started! The server CPU is now maxed out. Check CloudWatch and your ASG Activity tab in 3 minutes.", 200

if __name__ == '__main__':
    # threaded=True ensures health checks still pass during the stress test
    app.run(host='127.0.0.1', port=5000, threaded=True)
EOF

# Run Flask app in the background
nohup python3 /home/ubuntu/app.py > /home/ubuntu/app.log 2>&1 &

# --- Create Load Testing Script (Command-line fallback) ----------------
cat > /home/ubuntu/load_test.sh << 'EOF'
#!/bin/bash
echo "Initiating CPU load to trigger ASG Scale-out (5 mins)..."
stress --cpu 4 --timeout 300
EOF
chmod +x /home/ubuntu/load_test.sh
chown ubuntu:ubuntu /home/ubuntu/load_test.sh

# --- nginx: reverse proxy ----------------------------------------------
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" http://169.254.169.254/latest/meta-data/instance-id)

cat > /etc/nginx/sites-available/backend <<EOF
server {
    listen 80 default_server;
    server_name _;

    location /health {
        proxy_pass http://127.0.0.1:5000/health;
        proxy_set_header Host \$host;
        proxy_connect_timeout 2s;
        proxy_read_timeout 2s;
        error_page 502 504 = @health_fallback;
    }
    
    location /stress {
        proxy_pass http://127.0.0.1:5000/stress;
        proxy_set_header Host \$host;
    }

    location @health_fallback {
        default_type text/plain;
        return 200 "starting up (instance ${INSTANCE_ID})";
    }

    location / {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Disable default Nginx site and enable the backend proxy
rm -f /etc/nginx/sites-enabled/default
ln -s /etc/nginx/sites-available/backend /etc/nginx/sites-enabled/backend

systemctl enable nginx
systemctl restart nginx