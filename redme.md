# Local LLM Server with Model Switching

A containerized LLM setup using llama.cpp server and Open-WebUI, **optimized for Oracle Cloud ARM free tier** (4 OCPUs, 24GB RAM).

## Architecture Overview

```
./                               # Project root
├── docker-compose.yml
├── switch_model.sh
└── models/                      # Model storage (relative to project)
    ├── model1.gguf              # Individual GGUF models
    ├── model2.gguf
    ├── current -> model1.gguf   # Symlink to active model
    └── .last_selected_model     # Switching history

Docker Services:
├── llama-server                 # llama.cpp server (port 8080)
└── open-webui                   # Web interface (port 3000)
```

## Oracle ARM Free Tier Optimizations

This setup is specifically tuned for Oracle Cloud's ARM-based free tier instances:

- **ARM-optimized llama.cpp**: Uses `amperecomputingai/llama.cpp:3.2.0` image
- **Memory efficiency**: f16 KV cache, optimized batch sizes for 24GB RAM
- **CPU-only inference**: No GPU required, leverages 4 ARM cores efficiently  
- **Flash attention**: Better performance on ARM architecture
- **Reasonable context sizes**: 4K tokens fits well within memory constraints

**Model Switching Strategy**: The `current` symlink enables hot-swapping:
- Container mounts `./models:/models:ro` (read-only)
- llama.cpp loads `/models/current` (which is a symlink)
- Switching script updates the symlink and restarts the container
- Fast switching without copying large files

## Quick Start

### 1. Clone and Setup

```bash
# Clone the project
git clone https://github.com/DaemonSmith/oracle-arm-llm.git
cd oracle-arm-llm

# Create models directory
mkdir models
touch models/current

# Download your GGUF models directly to the models folder
wget -O models/phi-3-mini-4k-instruct-q4.gguf "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
wget -O models/llama-3.2-3b-instruct-q4.gguf "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"

# Set initial model
ln -sf phi-3-mini-4k-instruct-q4.gguf models/current

# Make switcher script executable
chmod +x switch_model.sh
```

### 2. Start Services

```bash
docker-compose up -d
```

### 3. Initial Setup

1. Open Open-WebUI in your browser: 

```http://<server-ip>:3000```

2. Create the admin account (first run) or login.

3. Go to Admin Panel → Settings → Connections (or User → Admin Panel → Settings → Connections depending on UI version).

4. Click the wrench/manage icon (or "Add connection") and create a new connection:

- Type: OpenAI (or "Custom OpenAI-compatible")

- Name: llama-local (or any name)

- Base URL: http://llama-server:8080/v1

- API Key: dummy-key (Open-WebUI expects a key value but llama.cpp does not enforce it)

- Save.

### 3. Switch Models

```bash
./switch_model.sh
```

The script will:
- Show all available GGUF files
- Display current model and container status  
- Allow selection by number
- Update symlink atomically
- Restart container automatically
- Perform health checks with rollback on failure

## Docker Compose Configuration

### Key Configuration Notes

**llama-server service:**
- Uses ARM-optimized `amperecomputingai/llama.cpp:3.2.0` image
- Mounts models as read-only (`./models:/models:ro`)
- Loads `/models/current` (symlink to active model)
- CPU-only inference optimized for Oracle ARM instances
- f16 KV cache for ARM efficiency
- Flash attention and 256-token batching for performance

**open-webui service:**
- Provides web interface on port 3000
- Connects to llama-server via internal Docker network
- Ollama integration disabled (using llama.cpp instead)
- OpenAI-compatible API mode enabled


## Model Switcher Script Features

### Safety Features
- **Atomic symlink updates**: Uses temporary symlinks to prevent race conditions
- **Automatic rollback**: Restores previous model if health checks fail
- **Lock file protection**: Prevents multiple instances running simultaneously
- **Comprehensive validation**: Checks Docker status, file existence, permissions

### Smart Health Checking
- Waits up to 120 seconds for large models to load
- Polls `/v1/models` endpoint for readiness
- Shows progress dots during wait
- Automatic rollback on timeout/failure

### User Experience
- **Color-coded output**: Green for success, yellow for warnings, red for errors
- **Current model indication**: Shows which model is currently active
- **Model size display**: Shows file sizes to help with selection
- **History tracking**: Remembers last selected models

## Troubleshooting

### Common Issues

**"No .gguf files found"**
```bash
# Ensure models are directly in the models folder, not subdirectories:
ls -la ./models/
# Should show: model1.gguf, model2.gguf, etc.
```

**"Container not responding after switch"**
```bash
# Check container logs
docker logs llama-server --tail 50

# Common causes:
# - Model too large for available RAM
# - Corrupted GGUF file
# - Incompatible model format
```

**"Health check timeout"**
```bash
# Large models (>13B) may need more time
# Edit script: MAX_WAIT=300  # 5 minutes

# Or check if model loaded but API is slow:
curl -v http://localhost:8080/v1/models
```

### Model Size Guidelines for Oracle ARM Free Tier

| Model Size | RAM Usage | Load Time | Recommendation |
|------------|-----------|-----------|----------------|
| 3B Q4_K_M  | 2-3GB     | 5-15s     | ✅ **Perfect fit** |
| 7B Q4_K_M  | 4-6GB     | 15-30s    | ✅ **Good choice** |
| 13B Q4_K_M | 8-12GB    | 30-60s    | ⚠️  **Works but tight** |
| 70B Q4_K_M | 40GB+     | N/A       | ❌ **Too large** |

**Recommended models for Oracle free tier:**
- `microsoft/Phi-3-mini-4k-instruct-gguf` (3.8B) - Excellent for code
- `bartowski/Llama-3.2-3B-Instruct-GGUF` (3B) - Good general purpose  
- `bartowski/Mistral-7B-Instruct-v0.3-GGUF` (7B) - Best quality that fits

### Oracle Cloud Specific Notes

**Networking:**
```bash
# Open firewall ports for external access
sudo firewall-cmd --permanent --add-port=3000/tcp  # Web UI
sudo firewall-cmd --permanent --add-port=8080/tcp  # API (optional)
sudo firewall-cmd --reload

# Or use iptables:
sudo iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

**Storage:**
- Oracle free tier gives you ~200GB boot volume
- Models will use significant space (3-8GB each)
- Consider cleanup strategy for unused models

**Performance:**
- ARM Neoverse-N1 cores perform well with quantized models
- Memory bandwidth is good for inference workloads  
- CPU-only setup avoids GPU complexity and cost

## Advanced Usage

### Model Organization

```bash
# Organized model naming for easy identification:
models/
├── llama2-7b-chat-q4_k_m.gguf
├── llama2-13b-chat-q4_k_m.gguf
├── mistral-7b-instruct-v0.2-q4_k_m.gguf
├── codellama-13b-instruct-q4_k_m.gguf
└── current -> llama2-7b-chat-q4_k_m.gguf
```

### Quick Switch Commands

```bash
# List models without switching
find ./models/ -name "*.gguf" -exec basename {} \;

# Direct symlink update (advanced users)
ln -sf new-model.gguf ./models/current
docker restart llama-server

# Check current model
readlink ./models/current
```

### Automation Integration

```bash
# Use in scripts - non-interactive mode could be added:
echo "0" | ./switch_model.sh  # Select first model
```

## API Access

Once running:
- **Web UI**: http://your-server:3000
- **API Endpoint**: http://your-server:8080/v1
- **Health Check**: http://your-server:8080/v1/models

### OpenAI-Compatible API

```bash
# Test API directly
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "current",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

## Configuration Tuning

### Memory Optimization
```bash
# For memory-constrained systems, reduce context size:
# In docker-compose.yml, change:
"-c", "2048",     # Reduce from 4096
```

### Performance Tuning
```bash
# For high-performance systems:
"-t", "8",        # More threads
"-tb", "4",       # More batch threads  
"-b", "512",      # Larger batch size
```

## Security Notes

- Models directory mounted read-only for safety
- No external network access required (except for initial setup)
- All data stays on your server
- Web UI runs on internal network only (add reverse proxy for external access)

## Backup Strategy

```bash
# Backup script for models and configuration
#!/bin/bash
tar -czf "llm-backup-$(date +%Y%m%d).tar.gz" \
  ./models/ \
  ./docker-compose.yml \
  ./switch_model.sh
```

---

This setup gives you a production-ready, containerized LLM environment with seamless model switching capabilities. The root-level model storage and symlink strategy provides both performance and flexibility for experimenting with different models.