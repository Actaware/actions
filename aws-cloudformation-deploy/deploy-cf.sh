#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${CFN_STACK_NAME:?CFN_STACK_NAME is required}"
TEMPLATE_FILE="${CFN_TEMPLATE_FILE:?CFN_TEMPLATE_FILE is required}"
REGION="${AWS_REGION:?AWS_REGION is required}"

CAPABILITIES="${CFN_CAPABILITIES:-}"
PARAMETERS_FILE="${CFN_PARAMETERS_FILE:-}"
INLINE_OVERRIDES="${CFN_PARAMETER_OVERRIDES:-}"
NO_FAIL_EMPTY="${CFN_NO_FAIL_ON_EMPTY_CHANGESET:-true}"
DELETE_ON_RB_COMPLETE="${CFN_DELETE_ON_ROLLBACK_COMPLETE:-true}"

aws_cmd() { aws --region "$REGION" "$@"; }

get_stack_status() {
  set +e
  local status
  status="$(aws_cmd cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null)"
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$status" || "$status" == "None" ]]; then
    echo "NOT_FOUND"
  else
    echo "$status"
  fi
}

delete_stack_and_wait() {
  echo "Deleting stack: $STACK_NAME"
  aws_cmd cloudformation delete-stack --stack-name "$STACK_NAME"
  echo "Waiting for stack deletion..."
  aws_cmd cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
}

# --- NEW: build params array from file + inline overrides ---
build_parameter_overrides() {
  local -a params=()

  if [[ -n "$PARAMETERS_FILE" ]]; then
    if [[ ! -f "$PARAMETERS_FILE" ]]; then
      echo "Parameters file not found: $PARAMETERS_FILE" >&2
      exit 1
    fi

    # Read Key=Value lines; ignore blank lines and #comments
    while IFS='=' read -r key value; do
      # Trim whitespace around key/value (simple trim)
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"

      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^# ]] && continue
      [[ -z "${value+x}" ]] && value=""

      params+=("${key}=${value}")
    done < "$PARAMETERS_FILE"
  fi

  if [[ -n "$INLINE_OVERRIDES" ]]; then
    # Inline overrides are space-separated Key=Value pairs
    # (If you need spaces in values, avoid inline and use the file instead.)
    # shellcheck disable=SC2206
    local extra=( $INLINE_OVERRIDES )
    params+=( "${extra[@]}" )
  fi

  # Print as a NUL-delimited stream so caller can safely read into array
  printf '%s\0' "${params[@]}"
}

deploy_stack() {
  echo "Deploying stack: $STACK_NAME"

  local -a args=(
    cloudformation deploy
    --stack-name "$STACK_NAME"
    --template-file "$TEMPLATE_FILE"
  )

  if [[ -n "$CAPABILITIES" ]]; then
    # shellcheck disable=SC2206
    local caps=( $CAPABILITIES )
    args+=( --capabilities "${caps[@]}" )
  fi

  if [[ "${NO_FAIL_EMPTY,,}" == "true" ]]; then
    args+=( --no-fail-on-empty-changeset )
  fi

  # Build parameter array (safe)
  local -a params=()
  while IFS= read -r -d '' item; do
    params+=( "$item" )
  done < <(build_parameter_overrides)

  if [[ ${#params[@]} -gt 0 ]]; then
    args+=( --parameter-overrides "${params[@]}" )
  fi

  aws_cmd "${args[@]}"
  echo "Deploy completed."
}

status="$(get_stack_status)"
echo "Current stack status: $status"

case "$status" in
  NOT_FOUND)
    deploy_stack
    ;;
  *_IN_PROGRESS)
    echo "Stack has an operation in progress ($status). Refusing to deploy concurrently."
    exit 1
    ;;
  ROLLBACK_COMPLETE)
    if [[ "${DELETE_ON_RB_COMPLETE,,}" == "true" ]]; then
      echo "Stack is in ROLLBACK_COMPLETE. Deleting and redeploying."
      delete_stack_and_wait
      deploy_stack
    else
      echo "Stack is in ROLLBACK_COMPLETE but delete_on_rollback_complete=false. Failing."
      exit 1
    fi
    ;;
  *)
    deploy_stack
    ;;
esac