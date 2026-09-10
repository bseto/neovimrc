if [ -n "$NVIM_AGENT_STATUS_FILE" ]; then
  temporary="${NVIM_AGENT_STATUS_FILE}.$$"
  if printf '%s\n' "$1" > "$temporary"; then
    mv -f "$temporary" "$NVIM_AGENT_STATUS_FILE"
  fi
fi
exit 0
