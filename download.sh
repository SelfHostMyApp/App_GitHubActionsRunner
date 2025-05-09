# Create a folder
cd /home/docker
mkdir -p /home/docker/actions-runner/ && cd /home/docker/actions-runner/ 
# Download the latest runner package
curl -o actions-runner-linux-x64-2.323.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz 
# Optional: Validate the hash
echo "0dbc9bf5a58620fc52cb6cc0448abcca964a8d74b5f39773b7afcad9ab691e19  actions-runner-linux-x64-2.323.0.tar.gz" | shasum -a 256 -c 
# Extract the installer
tar xzf ./actions-runner-linux-x64-2.323.0.tar.gz