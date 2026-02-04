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

TAG_APPLICATION="${CFN_TAG_APPLICATION:-}"
TAG_ENVIRONMENT="${CFN_TAG_ENVIRONMENT:-}"
TAG_OWNER="${CFN_TAG_OWNER:-}"
TAG_COST_CENTER="${CFN_TAG_COST_CENTER:-}"
TAG_MANAGED_BY="${CFN_TAG_MANAGED_BY:-}"
TAG_REPOSITORY="${CFN_TAG_REPOSITORY:-}"

aws_cmd() { aws --region "$REGION" "$@"; }

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

has_param_override() {
  local key="$1"
  shift
  local kv
  for kv in "$@"; do
    if [[ "$kv" == "$key="* ]]; then
      return 0
    fi
  done
  return 1
}

get_param_override_value() {
  local key="$1"
  shift
  local kv
  local last=""
  for kv in "$@"; do
    if [[ "$kv" == "$key="* ]]; then
      last="${kv#*=}"
    fi
  done
  printf '%s' "$last"
}

upsert_param_override() {
  local key="$1"
  local value="$2"
  shift 2
  local -a out=()
  local kv
  for kv in "$@"; do
    if [[ "$kv" == "$key="* ]]; then
      continue
    fi
    out+=( "$kv" )
  done
  out+=( "${key}=${value}" )
  printf '%s\0' "${out[@]}"
}

validate_and_enforce_required_overrides() {
  local -a params=( "$@" )

  # Prefer explicit tag inputs (when provided) by upserting them into the final overrides.
  # (Last key wins for aws cloudformation deploy.)
  local -a next=()
  if [[ -n "$(trim "$TAG_APPLICATION")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagApplication" "$TAG_APPLICATION" "${params[@]}")
    params=( "${next[@]}" )
  fi
  if [[ -n "$(trim "$TAG_ENVIRONMENT")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagEnvironment" "$TAG_ENVIRONMENT" "${params[@]}")
    params=( "${next[@]}" )
  fi
  if [[ -n "$(trim "$TAG_OWNER")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagOwner" "$TAG_OWNER" "${params[@]}")
    params=( "${next[@]}" )
  fi
  if [[ -n "$(trim "$TAG_COST_CENTER")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagCostCenter" "$TAG_COST_CENTER" "${params[@]}")
    params=( "${next[@]}" )
  fi
  if [[ -n "$(trim "$TAG_MANAGED_BY")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagManagedBy" "$TAG_MANAGED_BY" "${params[@]}")
    params=( "${next[@]}" )
  fi

  # Auto-fill TagRepository from the current GitHub repo URL when possible.
  local derived_repo="${TAG_REPOSITORY:-}"
  derived_repo="$(trim "$derived_repo")"
  if [[ -z "$derived_repo" ]]; then
    if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
      derived_repo="${GITHUB_SERVER_URL%/}/${GITHUB_REPOSITORY}"
    fi
  fi
  if [[ -n "$(trim "$derived_repo")" ]]; then
    next=()
    while IFS= read -r -d '' item; do next+=( "$item" ); done < <(upsert_param_override "TagRepository" "$derived_repo" "${params[@]}")
    params=( "${next[@]}" )
  fi

  # Auto-fill TagStackName from the stack name input when not provided.
  if ! has_param_override "TagStackName" "${params[@]}"; then
    params+=( "TagStackName=$STACK_NAME" )
  fi

  local -a required=(
    TagApplication
    TagEnvironment
    TagOwner
    TagCostCenter
    TagManagedBy
    TagRepository
    TagStackName
  )

  local key raw value
  for key in "${required[@]}"; do
    if ! has_param_override "$key" "${params[@]}"; then
      echo "Missing required parameter override: ${key} (pass via tag_* inputs, parameters_file, or parameter_overrides)" >&2
      exit 1
    fi
    raw="$(get_param_override_value "$key" "${params[@]}")"
    value="$(trim "$raw")"
    if [[ -z "$value" ]]; then
      echo "Required parameter override ${key} must not be empty." >&2
      exit 1
    fi
  done

  value="$(trim "$(get_param_override_value "TagRepository" "${params[@]}")")"
  if [[ ! "$value" =~ ^https?:// ]]; then
    echo "Required parameter override TagRepository must be an http(s) URL (got: ${value})." >&2
    exit 1
  fi

  # Print as a NUL-delimited stream so caller can safely read into array
  printf '%s\0' "${params[@]}"
}

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

  # Enforce required tag parameters for all deployments, and auto-fill TagStackName.
  local -a validated_params=()
  while IFS= read -r -d '' item; do
    validated_params+=( "$item" )
  done < <(validate_and_enforce_required_overrides "${params[@]}")

  if [[ ${#validated_params[@]} -gt 0 ]]; then
    args+=( --parameter-overrides "${validated_params[@]}" )
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
