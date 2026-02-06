#!/usr/bin/env bash
# GonsAutoPilot - 변경 파일 분석기
# git diff 기반으로 변경된 파일을 프론트/백엔드/DB/설정으로 분류

set -euo pipefail

# 파일 경로 패턴으로 카테고리 분류
categorize_file() {
  local file="$1"

  # 테스트 파일 (다른 패턴보다 먼저 체크 — .test.tsx 등은 프론트가 아닌 테스트)
  if [[ "$file" =~ \.(test|spec)\.(ts|tsx|js|jsx)$ ]] || \
     [[ "$file" =~ ^(tests|__tests__|test|e2e|cypress)/ ]] || \
     [[ "$file" =~ /__(tests|mocks)__/ ]]; then
    echo "test"
    return
  fi

  # 프론트엔드 패턴
  if [[ "$file" =~ \.(tsx|jsx|css|scss|less|html|svg|vue|svelte)$ ]] || \
     [[ "$file" =~ ^(src/pages|src/components|src/styles|src/hooks|src/contexts|src/layouts|src/features|public|frontend|app|pages|components)/ ]] || \
     [[ "$file" == "tailwind.config"* ]] || \
     [[ "$file" == "postcss.config"* ]] || \
     [[ "$file" == "next.config"* ]] || \
     [[ "$file" == "vite.config"* ]] || \
     [[ "$file" == "nuxt.config"* ]] || \
     [[ "$file" == "svelte.config"* ]]; then
    echo "frontend"
    return
  fi

  # 백엔드 패턴
  if [[ "$file" =~ ^(server|api|backend|src/api|src/server|src/routes|src/middleware|src/controllers|src/services|src/models|src/repositories|src/graphql|src/resolvers|lib)/ ]] || \
     [[ "$file" =~ \.(go|py|rb|java|rs|php|ex|exs)$ ]]; then
    echo "backend"
    return
  fi

  # DB/마이그레이션 패턴
  if [[ "$file" =~ ^(migrations|prisma|drizzle|database|sql|seeds|db)/ ]] || \
     [[ "$file" =~ \.(sql|prisma)$ ]] || \
     [[ "$file" == "schema.prisma" ]] || \
     [[ "$file" == "drizzle.config"* ]]; then
    echo "database"
    return
  fi

  # 설정 패턴
  if [[ "$file" =~ ^(docker|\.docker|\.github|\.ci|\.circleci|nginx|deploy|infrastructure|infra|k8s|helm)/ ]] || \
     [[ "$file" == "docker-compose"* ]] || \
     [[ "$file" == "Dockerfile"* ]] || \
     [[ "$file" == ".env"* ]] || \
     [[ "$file" == "package.json" ]] || \
     [[ "$file" == "package-lock.json" ]] || \
     [[ "$file" == "yarn.lock" ]] || \
     [[ "$file" == "pnpm-lock.yaml" ]] || \
     [[ "$file" == "tsconfig"* ]] || \
     [[ "$file" == ".eslintrc"* ]] || \
     [[ "$file" == ".prettierrc"* ]] || \
     [[ "$file" == "gonsautopilot.yaml" ]] || \
     [[ "$file" == "Makefile" ]] || \
     [[ "$file" == ".gitignore" ]]; then
    echo "config"
    return
  fi

  # TypeScript/JavaScript는 경로로 추가 판단
  if [[ "$file" =~ \.(ts|js|mjs|cjs)$ ]]; then
    if [[ "$file" =~ ^(src/pages|src/components|src/hooks|src/contexts|src/layouts|src/features|frontend|app|pages|components)/ ]]; then
      echo "frontend"
    elif [[ "$file" =~ ^(server|api|backend|src/api|src/server|src/routes|src/middleware|src/controllers|src/services|src/models|lib)/ ]]; then
      echo "backend"
    else
      echo "shared"
    fi
    return
  fi

  echo "other"
}

# git diff에서 변경된 파일 목록 추출 및 분류
analyze_changes() {
  local mode="${1:-auto}"  # auto | staged | unstaged | commit:<ref> | range:<from>..<to>

  local changed_files=""

  case "$mode" in
    staged)
      # 스테이지된 변경만
      changed_files=$(git diff --name-only --cached 2>/dev/null || echo "")
      ;;
    unstaged)
      # 스테이지되지 않은 변경만
      changed_files=$(git diff --name-only 2>/dev/null || echo "")
      ;;
    commit:*)
      # 특정 커밋 기준
      local ref="${mode#commit:}"
      changed_files=$(git diff --name-only "${ref}" HEAD 2>/dev/null || echo "")
      ;;
    range:*)
      # 범위 지정 (from..to)
      local range="${mode#range:}"
      changed_files=$(git diff --name-only ${range} 2>/dev/null || echo "")
      ;;
    auto|*)
      # 자동 감지: 커밋→스테이지→언스테이지→working tree 순
      changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
      if [[ -z "$changed_files" ]]; then
        changed_files=$(git diff --name-only --cached 2>/dev/null || echo "")
      fi
      if [[ -z "$changed_files" ]]; then
        changed_files=$(git diff --name-only 2>/dev/null || echo "")
      fi
      if [[ -z "$changed_files" ]]; then
        changed_files=$(git status --porcelain 2>/dev/null | awk '{print $NF}' || echo "")
      fi
      ;;
  esac

  if [[ -z "$changed_files" ]]; then
    echo '{"frontend":[],"backend":[],"config":[],"database":[],"test":[],"shared":[],"other":[],"total":0}'
    return
  fi

  local frontend=() backend=() config=() database=() test_files=() shared=() other=()

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local category
    category=$(categorize_file "$file")
    case "$category" in
      frontend)  frontend+=("$file") ;;
      backend)   backend+=("$file") ;;
      config)    config+=("$file") ;;
      database)  database+=("$file") ;;
      test)      test_files+=("$file") ;;
      shared)    shared+=("$file") ;;
      *)         other+=("$file") ;;
    esac
  done <<< "$changed_files"

  # JSON 배열 생성 함수
  _to_json_array() {
    if [[ $# -eq 0 ]] || [[ -z "${1:-}" ]]; then
      echo "[]"
    else
      printf '%s\n' "$@" | jq -R . | jq -s .
    fi
  }

  local f_json b_json c_json d_json t_json s_json o_json
  f_json=$(_to_json_array "${frontend[@]+"${frontend[@]}"}")
  b_json=$(_to_json_array "${backend[@]+"${backend[@]}"}")
  c_json=$(_to_json_array "${config[@]+"${config[@]}"}")
  d_json=$(_to_json_array "${database[@]+"${database[@]}"}")
  t_json=$(_to_json_array "${test_files[@]+"${test_files[@]}"}")
  s_json=$(_to_json_array "${shared[@]+"${shared[@]}"}")
  o_json=$(_to_json_array "${other[@]+"${other[@]}"}")

  local total=$(( ${#frontend[@]} + ${#backend[@]} + ${#config[@]} + ${#database[@]} + ${#test_files[@]} + ${#shared[@]} + ${#other[@]} ))

  jq -n \
    --argjson frontend "$f_json" \
    --argjson backend "$b_json" \
    --argjson config "$c_json" \
    --argjson database "$d_json" \
    --argjson test "$t_json" \
    --argjson shared "$s_json" \
    --argjson other "$o_json" \
    --argjson total "$total" \
    '{
      frontend: $frontend,
      backend: $backend,
      config: $config,
      database: $database,
      test: $test,
      shared: $shared,
      other: $other,
      total: $total
    }'
}

# 변경 분석 결과를 바탕으로 필요한 테스트 종류 결정
determine_required_tests() {
  local changes_json="$1"
  local config_json="${2:-"{}"}"

  local has_frontend has_backend has_db has_config has_shared has_test
  has_frontend=$(echo "$changes_json" | jq '.frontend | length > 0')
  has_backend=$(echo "$changes_json" | jq '.backend | length > 0')
  has_db=$(echo "$changes_json" | jq '.database | length > 0')
  has_config=$(echo "$changes_json" | jq '.config | length > 0')
  has_shared=$(echo "$changes_json" | jq '.shared | length > 0')
  has_test=$(echo "$changes_json" | jq '.test | length > 0')
  local total
  total=$(echo "$changes_json" | jq '.total // 0')

  # 변경이 전혀 없으면
  if [[ "$total" == "0" ]]; then
    jq -n '{
      required_tests: [],
      skipped_tests: ["unit","e2e","performance","security"],
      skip_reasons: {"unit":"변경 파일 없음","e2e":"변경 파일 없음","performance":"변경 파일 없음","security":"변경 파일 없음"},
      build_targets: [],
      needs_migration: false,
      should_skip_pipeline: true
    }'
    return
  fi

  local tests=()
  local skips=()
  local -A skip_reasons=()

  # shared 변경 시 프론트+백엔드 모두 테스트
  if [[ "$has_shared" == "true" ]]; then
    has_frontend="true"
    has_backend="true"
  fi

  # 테스트 파일만 변경된 경우에도 unit 테스트 실행
  if [[ "$has_test" == "true" ]]; then
    has_frontend="true"
    has_backend="true"
  fi

  # 설정 변경에 따른 추가 판단
  local has_deps_change="false"
  if [[ "$has_config" == "true" ]]; then
    has_deps_change=$(echo "$changes_json" | jq '[.config[] | select(test("package.json|package-lock|yarn.lock|pnpm-lock"))] | length > 0')
  fi

  # 단위 테스트
  if [[ "$has_frontend" == "true" || "$has_backend" == "true" || "$has_deps_change" == "true" ]]; then
    tests+=("unit")
  else
    skips+=("unit")
    skip_reasons[unit]="코드 변경 없음 (설정/기타 파일만 변경)"
  fi

  # E2E 테스트
  if [[ "$has_frontend" == "true" || "$has_backend" == "true" ]]; then
    tests+=("e2e")
  else
    skips+=("e2e")
    skip_reasons[e2e]="UI/API 변경 없음"
  fi

  # 성능 테스트
  if [[ "$has_frontend" == "true" ]]; then
    tests+=("performance")
  else
    skips+=("performance")
    skip_reasons[performance]="프론트엔드 변경 없음"
  fi

  # 보안 테스트: 의존성 변경 시 반드시, 그 외에도 기본 실행
  if [[ "$has_deps_change" == "true" ]]; then
    tests+=("security")
  elif [[ "$has_frontend" == "true" || "$has_backend" == "true" ]]; then
    tests+=("security")
  else
    skips+=("security")
    skip_reasons[security]="코드/의존성 변경 없음"
  fi

  # 빌드 대상 결정
  local build_targets=()
  if [[ "$has_frontend" == "true" || "$has_config" == "true" ]]; then
    build_targets+=("frontend")
  fi
  if [[ "$has_backend" == "true" || "$has_db" == "true" || "$has_config" == "true" ]]; then
    build_targets+=("backend")
  fi

  # DB 마이그레이션
  local needs_migration="false"
  if [[ "$has_db" == "true" ]]; then
    needs_migration="true"
  fi

  # JSON 출력
  local tests_json skips_json builds_json reasons_json
  if [[ ${#tests[@]} -gt 0 ]]; then
    tests_json=$(printf '%s\n' "${tests[@]}" | jq -R . | jq -s .)
  else
    tests_json="[]"
  fi

  if [[ ${#skips[@]} -gt 0 ]]; then
    skips_json=$(printf '%s\n' "${skips[@]}" | jq -R . | jq -s .)
  else
    skips_json="[]"
  fi

  if [[ ${#build_targets[@]} -gt 0 ]]; then
    builds_json=$(printf '%s\n' "${build_targets[@]}" | jq -R . | jq -s .)
  else
    builds_json="[]"
  fi

  # skip_reasons을 JSON 객체로 변환
  reasons_json="{}"
  for key in "${!skip_reasons[@]}"; do
    reasons_json=$(echo "$reasons_json" | jq --arg k "$key" --arg v "${skip_reasons[$key]}" '. + {($k): $v}')
  done

  jq -n \
    --argjson tests "$tests_json" \
    --argjson skips "$skips_json" \
    --argjson skip_reasons "$reasons_json" \
    --argjson build_targets "$builds_json" \
    --argjson needs_migration "$needs_migration" \
    '{
      required_tests: $tests,
      skipped_tests: $skips,
      skip_reasons: $skip_reasons,
      build_targets: $build_targets,
      needs_migration: $needs_migration,
      should_skip_pipeline: false
    }'
}

# 분석 요약 출력 (사람이 읽기 좋은 형식)
print_summary() {
  local changes_json="$1"
  local plan_json="$2"

  echo ""
  echo "  ┌─ 변경 파일 감지"

  local categories=("frontend" "backend" "database" "config" "test" "shared" "other")
  local labels=("프론트엔드" "백엔드" "데이터베이스" "설정" "테스트" "공유" "기타")

  for i in "${!categories[@]}"; do
    local cat="${categories[$i]}"
    local label="${labels[$i]}"
    local count
    count=$(echo "$changes_json" | jq ".${cat} | length")
    if [[ "$count" -gt 0 ]]; then
      local files
      files=$(echo "$changes_json" | jq -r ".${cat}[]" | head -3)
      echo "  │  ${label}: ${count}개 파일"
      while IFS= read -r f; do
        echo "  │    - $f"
      done <<< "$files"
      if [[ "$count" -gt 3 ]]; then
        echo "  │    ... 외 $((count - 3))개"
      fi
    fi
  done

  echo "  │"
  echo "  ├─ AI 판단"

  # 필요한 테스트
  local required
  required=$(echo "$plan_json" | jq -r '.required_tests[]' 2>/dev/null)
  if [[ -n "$required" ]]; then
    echo "  │  실행할 테스트:"
    while IFS= read -r t; do
      echo "  │    ✓ $t"
    done <<< "$required"
  fi

  # 스킵 테스트
  local skipped
  skipped=$(echo "$plan_json" | jq -r '.skipped_tests[]' 2>/dev/null)
  if [[ -n "$skipped" ]]; then
    echo "  │  스킵할 테스트:"
    while IFS= read -r t; do
      local reason
      reason=$(echo "$plan_json" | jq -r ".skip_reasons.${t} // \"\"" 2>/dev/null)
      echo "  │    ✂️ $t ($reason)"
    done <<< "$skipped"
  fi

  # 빌드 대상
  local builds
  builds=$(echo "$plan_json" | jq -r '.build_targets[]' 2>/dev/null)
  if [[ -n "$builds" ]]; then
    echo "  │  빌드 대상: $(echo "$builds" | tr '\n' ', ' | sed 's/,$//')"
  fi

  # DB 마이그레이션
  local migration
  migration=$(echo "$plan_json" | jq -r '.needs_migration')
  if [[ "$migration" == "true" ]]; then
    echo "  │  ⚠️ DB 마이그레이션 필요"
  fi

  echo "  │"
}

# 메인
main() {
  local cmd="${1:-analyze}"
  shift || true

  case "$cmd" in
    analyze)          analyze_changes "$@" ;;
    determine-tests)  determine_required_tests "$@" ;;
    categorize)       categorize_file "$@" ;;
    summary)          print_summary "$@" ;;
    help)
      echo "GonsAutoPilot Change Analyzer"
      echo "사용법: change-analyzer.sh <command> [args]"
      echo ""
      echo "명령어:"
      echo "  analyze [mode]                  변경 파일 분석"
      echo "    mode: auto (기본), staged, unstaged, commit:<ref>, range:<from>..<to>"
      echo "  determine-tests <changes_json> [config_json]  필요한 테스트 종류 결정"
      echo "  categorize <file_path>          단일 파일 카테고리 판단"
      echo "  summary <changes_json> <plan_json>  분석 요약 출력"
      ;;
    *)
      echo "ERROR: 알 수 없는 명령어: $cmd" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
