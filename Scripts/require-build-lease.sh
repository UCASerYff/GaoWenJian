# Source from a zsh build script after PROJECT_DIR has been set. Positional
# arguments remain the caller's; ZSH_ARGZERO names its original script.
[[ -n "${PROJECT_DIR:-}" ]] || { print -u2 '统一构建锁门禁需要 PROJECT_DIR'; return 1; }
WORKSPACE_LEASE="$PROJECT_DIR/../合并迁移-2026-11-02/build_lease.py"
if [[ ! -f "$WORKSPACE_LEASE" ]]; then
  if [[ -f "$PROJECT_DIR/../AGENTS.md" || "${PROJECT_DIR:h:t}" == '搞app' ]]; then
    print -u2 '缺少当前工作区指定的统一构建锁脚本，停止编译'
    return 1
  fi
  # Public standalone checkouts do not own the local multi-App workspace lock.
  print -u2 '独立源码目录未发现父工作区；不使用本机专项构建锁'
  return 0
fi
if [[ -z "${GAO_BUILD_LEASE_OWNER:-}" && -z "${GAO_BUILD_LEASE_TOKEN:-}" ]]; then
  exec python3 "$PROJECT_DIR/Scripts/with-build-lease.py" -- /bin/zsh "$ZSH_ARGZERO" "$@"
fi
if [[ -z "${GAO_BUILD_LEASE_OWNER:-}" || -z "${GAO_BUILD_LEASE_TOKEN:-}" ]]; then
  print -u2 '统一构建锁 owner/token 不完整，停止编译'
  return 1
fi
# Delegate receipt path, owner, token, UID and mode validation to the canonical
# implementation. Never infer ownership from an arbitrary receipt file.
python3 "$WORKSPACE_LEASE" verify >/dev/null
