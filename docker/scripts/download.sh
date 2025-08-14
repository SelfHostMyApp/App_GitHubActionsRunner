# Create a folder
cd /home/docker
mkdir -p /home/docker/actions-runner/ && cd /home/docker/actions-runner/
# Download the latest runner package
curl -o actions-runner-linux-x64-2.324.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.324.0/actions-runner-linux-x64-2.324.0.tar.gz
# Optional: Validate the hash
echo "e8e24a3477da17040b4d6fa6d34c6ecb9a2879e800aa532518ec21e49e21d7b4  actions-runner-linux-x64-2.324.0.tar.gz" | shasum -a 256 -c
# Extract the installer
tar xzf ./actions-runner-linux-x64-2.324.0.tar.gz
