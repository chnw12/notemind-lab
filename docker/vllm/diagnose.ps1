# Read-only diagnostics for the notemind vLLM chat container.
# Does NOT read .env, does NOT print container environment, deletes nothing.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File <path>\diagnose.ps1
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $dir 'diagnose-out.txt'
$expected = 2666027672   # model.safetensors size in bytes (Qwen/Qwen3-4B-AWQ, sha256 a7043493...)

function Redact($line) {
  $s = "$line"
  $s = $s -replace '(?i)(api_key\s*=\s*)[^,)\s]+', '$1<redacted>'
  $s = $s -replace 'hf_[A-Za-z0-9]{16,}', 'hf_<redacted>'
  $s = $s -replace '(?i)(Bearer\s+)\S+', '$1<redacted>'
  return $s
}
function Run([scriptblock]$b) { & $b 2>&1 | ForEach-Object { Redact $_ } }
function Section($t) { ''; "===== $t =====" }

$report = & {
  Section 'time'
  Get-Date -Format o

  Section 'containers (project notemind-vllm)'
  Run { docker ps -a --filter label=com.docker.compose.project=notemind-vllm --format '{{.Names}} | {{.State}} | {{.Status}}' }

  $cid = (docker ps -a -q --filter label=com.docker.compose.project=notemind-vllm --filter label=com.docker.compose.service=chat | Select-Object -First 1)
  if (-not $cid) { 'NO CHAT CONTAINER FOUND'; return }

  Section 'chat state'
  Run { docker inspect -f 'status={{.State.Status}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}} exit={{.State.ExitCode}} started={{.State.StartedAt}} created={{.Created}}' $cid }
  Run { docker inspect -f 'health={{if .State.Health}}{{.State.Health.Status}} failing_streak={{.State.Health.FailingStreak}}{{else}}none{{end}}' $cid }
  Section 'chat healthcheck actually applied (nanoseconds)'
  Run { docker inspect -f 'interval={{.Config.Healthcheck.Interval}} timeout={{.Config.Healthcheck.Timeout}} start_period={{.Config.Healthcheck.StartPeriod}} retries={{.Config.Healthcheck.Retries}}' $cid }
  Section 'chat mounts'
  Run { docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{println}}{{end}}' $cid }
  Section 'chat command args'
  Run { docker inspect -f '{{.Config.Cmd}}' $cid }

  Section 'chat logs (last 80 lines, redacted)'
  Run { docker logs --tail 80 $cid }

  Section 'cache: files (read-only helper container)'
  $sh1 = 'cd /root/.cache/huggingface/hub 2>/dev/null || { echo NO_HUB_DIR; exit 0; }; ls -d models--* 2>/dev/null; echo; M=models--Qwen--Qwen3-4B-AWQ; echo [blobs]; ls -la --time-style=+%F_%T $M/blobs 2>&1; echo [snapshots]; ls -la $M/snapshots/*/ 2>&1; echo [disk]; df -h /root/.cache/huggingface | tail -1'
  Run { docker run --rm --volumes-from "${cid}:ro" --entrypoint sh notemind-vllm:cuda12 -c $sh1 }

  Section "cache: growth of *.incomplete over 60s (expected final size $expected bytes)"
  $sh2 = 'cd /root/.cache/huggingface/hub/models--Qwen--Qwen3-4B-AWQ/blobs 2>/dev/null || { echo NO_BLOBS_DIR; exit 0; }; for i in 1 2 3 4 5 6 7; do for f in *.incomplete; do [ -e $f ] || { echo $(date +%T) no_incomplete_file; continue; }; echo $(date +%T) apparent_bytes=$(stat -c %s $f) disk_bytes=$(( $(stat -c %b $f) * 512 )) $f; done; [ $i -lt 7 ] && sleep 10; done'
  Run { docker run --rm --volumes-from "${cid}:ro" --entrypoint sh notemind-vllm:cuda12 -c $sh2 }

  Section 'chat container network/cpu, two samples 10s apart'
  Run { docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} net={{.NetIO}}' $cid }
  Start-Sleep -Seconds 10
  Run { docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} net={{.NetIO}}' $cid }

  Section 'sha256 of completed large blobs (file name must equal hash)'
  $sh3 = 'cd /root/.cache/huggingface/hub/models--Qwen--Qwen3-4B-AWQ/blobs 2>/dev/null || exit 0; for f in *; do case $f in *.incomplete|*.bad) ;; *) [ $(stat -c %s $f) -gt 100000000 ] && sha256sum $f ;; esac; done; echo done'
  Run { docker run --rm --volumes-from "${cid}:ro" --entrypoint sh notemind-vllm:cuda12 -c $sh3 }

  Section 'host: Hugging Face reachability (headers only)'
  Run { curl.exe -sI --max-time 20 https://huggingface.co/Qwen/Qwen3-4B-AWQ/resolve/main/model.safetensors } | Where-Object { $_ -match '^(HTTP/|x-linked-size|x-linked-etag|x-error)' }

  Section 'host: local health endpoints'
  Run { curl.exe -s -o NUL -w 'chat 8000 /health -> %{http_code}\n' --max-time 5 http://127.0.0.1:8000/health }
  Run { curl.exe -s -o NUL -w 'embedding 8001 /health -> %{http_code}\n' --max-time 5 http://127.0.0.1:8001/health }

  Section 'host: GPU'
  Run { nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv }
}
$report | Out-File -FilePath $out -Encoding utf8
"Wrote $out"
