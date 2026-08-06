#!/usr/bin/env bash
# run.sh - dora run 래퍼. --save 로 기록을 켠다.
#
#   ./run.sh dataflow_motor_real.yml --save
#   ./run.sh dataflow_motor_real_2hands.yml --save
#   ./run.sh dataflow_motor_simu.yml            # 기록 없이 그냥 실행
#
# 왜 래퍼가 필요한가:
#   `dora run` 은 --uv 와 --stop-after 만 받고 그 밖의 플래그는 거부한다
#   (error: unexpected argument '--save' found). 그래서 --save 는 여기서 걷어내고
#   AH_SAVE 환경변수로 바꿔서 노드에 전달한다.
#
# 저장 위치: out/<날짜_시간>/   예) out/2026-08-05_17-42-10/
#   폴더 이름을 여기서 한 번 정해 두기 때문에, 양손 dataflow 처럼 노드가 여러 개여도
#   전부 같은 폴더에 기록된다 (파일 앞머리 r_ / l_ 로 구분).
#
# 남는 파일:
#   r_motors.png / r_motors_deg.csv   모터 관절 8개 각도
#   r_joints.png / r_joints_deg.csv   종속 링크 관절 24개 각도
#   r_tips.png   / r_tips_mm.csv      손끝 tip1~tip4 위치 xyz
#   (왼손이 있으면 l_ 로 시작하는 같은 구성)

set -euo pipefail

SAVE=0
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --save) SAVE=1 ;;
        *)      ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "사용법: ./run.sh <dataflow.yml> [--save] [dora run 옵션...]" >&2
    echo "예:     ./run.sh dataflow_motor_real.yml --save" >&2
    exit 2
fi

# --uv 가 없으면 붙여 준다 (이 프로젝트는 항상 uv venv 를 쓴다)
HAS_UV=0
for a in "${ARGS[@]}"; do
    [[ "$a" == "--uv" ]] && HAS_UV=1
done
[[ $HAS_UV -eq 0 ]] && ARGS+=("--uv")

if [[ $SAVE -eq 1 ]]; then
    STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
    export AH_SAVE="$STAMP"
    echo "[run.sh] 기록 켜짐 → out/$STAMP/"
else
    unset AH_SAVE 2>/dev/null || true
fi

echo "[run.sh] dora run ${ARGS[*]}"
exec dora run "${ARGS[@]}"
