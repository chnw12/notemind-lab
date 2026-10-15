FROM vllm/vllm-openai:v0.8.5

# Use Hugging Face's standard HTTP downloader on the classroom network.
RUN python3 -m pip uninstall -y hf-xet hf-transfer || true
