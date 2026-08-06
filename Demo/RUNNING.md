# AmazingHand Demo 실행 가이드

`Demo/` 폴더의 dora-rs 데이터플로우를 실제로 돌리기 위한 상세 안내서입니다.
공식 [README.md](README.md)의 명령들을 실제 실행 순서, 환경 확인, 에러 대처까지 포함해 풀어 썼습니다.

> **검증 범위** (Ubuntu / dora-cli 0.5.0 / 2026-08-05 기준)
> - ✅ `dataflow_angle_simu.yml`: 아래 절차 그대로 빌드·실행 확인
> - ✅ `cargo build -p AHControl` 및 `-h` 도움말 출력 확인
> - ⛔ 웹캠(`/dev/video*`)·시리얼(`/dev/ttyACM*`) 장치가 없어 3-B, 3-C는 실행 미확인
>   (설정 파일·소스 기준으로 작성했으므로 하드웨어 연결 후 확인 필요)

---

## 0. Demo 폴더가 하는 일

| 폴더 | 언어 | 역할 |
|---|---|---|
| `HandTracking/` | Python | 웹캠 + MediaPipe로 사람 손을 추적해 손끝 목표 자세를 내보냄 |
| `AHSimulation/` | Python | MuJoCo + mink으로 손을 시뮬레이션하고 **역기구학**을 풀어 서보 각도를 계산 |
| `AHControl/` | Rust | 계산된 각도를 Feetech SCS0009 서보에 시리얼로 전송 (실제 하드웨어) |

이들을 이어 붙이는 배선도가 최상위의 `dataflow_*.yml` 파일들이고, 실행 엔진이 **dora-rs**입니다.

```
[웹캠] → HandTracking → AHSimulation(IK) → AHControl → [실제 손]
                              ↑
              finger_angle_control.py (웹캠 없이 각도를 직접 생성)
```

> 참고: 최상위 `PythonExample/`, `ArduinoExample/`는 이것과 **별개**입니다.
> 조립 직후 서보 ID 설정과 손가락 캘리브레이션용 단순 스크립트라서, dora가 필요 없습니다.

---

## 1. 사전 준비물

### 1-1. 소프트웨어 설치

| 도구 | 확인 명령 | 설치 |
|---|---|---|
| Rust | `cargo --version` | https://www.rust-lang.org/tools/install |
| uv | `uv --version` | https://docs.astral.sh/uv/getting-started/installation/ |
| dora CLI | `dora --version` | https://dora-rs.ai/docs/guides/Installation/installing |

한 번에 확인:

```bash
cargo --version && uv --version && dora --version
```

### 1-2. 하드웨어 (데모별로 필요한 것만)

```bash
ls /dev/video*                  # 웹캠  → 트래킹 데모에 필요
ls /dev/ttyACM* /dev/ttyUSB*    # 시리얼 → 실제 하드웨어 데모에 필요
```

> 💡 장치 이름이 매번 바뀌는 게 번거로우면 [`ah_devices.sh`](ah_devices.sh)를 쓰세요.
> ```bash
> ./ah_devices.sh            # 뭐가 연결됐는지 확인
> ./ah_devices.sh install    # udev 규칙 설치 (sudo)
> ```
> 이후 로봇은 항상 **`/dev/ah`**, 카메라는 항상 **`/dev/ahv`** 로 잡힙니다.
> USB를 다시 꽂거나 재부팅해서 `/dev/videoN` 의 N이 바뀌어도 `/dev/ahv` 는 그대로입니다.
> (실제로 이 PC에서 재연결 한 번에 번호가 바뀌었습니다.)

- 시뮬레이션 데모만 돌릴 거면 **둘 다 필요 없습니다.**
- MuJoCo 뷰어 창이 뜨므로 **그래픽 디스플레이는 필요**합니다 (`echo $DISPLAY`가 비어 있으면 안 됨).
  SSH 접속이면 `ssh -X` 또는 VNC를 쓰세요.

---

## 2. 최초 1회 세팅

**모든 명령은 `Demo/` 폴더 안에서 실행합니다.** (상위 `AmazingHand/`가 아닙니다.)

```bash
cd ~/AmazingHand/Demo
```

### 2-1. 파이썬 가상환경(.venv) 만들기

```bash
cd ~/AmazingHand/Demo     # ← 반드시 Demo 안에서!
uv venv --python 3.12
```

성공하면 이렇게 나옵니다:

```
Using CPython 3.12.13
Creating virtual environment at: .venv
Activate with: source .venv/bin/activate
```

**⚠️ 위치가 중요합니다.** `Demo/.venv` 여야 합니다. 상위 폴더(`~/AmazingHand`)에서 만들면
`dora ... --uv` 가 찾지 못합니다. dora 는 dataflow 를 실행하는 디렉터리(=`Demo`)에서
`.venv` 를 찾기 때문입니다.

**⚠️ 반드시 3.12 여야 합니다.**

| 패키지 | 요구 버전 |
|---|---|
| `HandTracking` | `>=3.9,<=3.12` |
| `AHSimulation` | `>=3.12` |

교집합이 **3.12 뿐**입니다. 3.13 이상으로 만들면 트래킹 데모가 설치되지 않고,
3.11 이하면 시뮬레이션이 설치되지 않습니다.
시스템에 3.12 가 없어도 됩니다 — uv 가 알아서 내려받습니다(약 33MB, 최초 1회).

#### 확인

```bash
.venv/bin/python --version      # Python 3.12.13
uv pip list | head              # 설치된 패키지 (처음엔 비어 있음)
```

#### activate 는 안 해도 됩니다

`dora build` / `dora run` 에 `--uv` 를 붙이면 dora 가 이 venv 를 자동으로 씁니다.
직접 스크립트를 돌리거나 패키지를 살펴볼 때만 필요합니다:

```bash
source .venv/bin/activate       # 활성화
deactivate                      # 해제
```

활성화하지 않고 한 번만 쓸 거면 경로로 직접 부르는 게 편합니다:

```bash
.venv/bin/python -c "import mujoco; print(mujoco.__version__)"
```

#### 패키지는 언제 설치되나

`uv venv` 는 **빈 환경만** 만듭니다. 실제 의존성(mujoco, mink, mediapipe 등)은
2-3 의 `dora build` 가 각 노드의 `build:` 항목(`pip install -e ...`)을 실행하면서 채웁니다.
그래서 `uv venv` 직후 `uv pip list` 가 비어 있는 건 정상입니다.

#### 다시 만들기 / 지우기

환경이 꼬였을 때는 통째로 새로 만드는 게 가장 빠릅니다:

```bash
uv venv --python 3.12 --clear    # 기존 .venv 를 비우고 다시 생성
# 또는
rm -rf .venv && uv venv --python 3.12
```

그 다음 **`dora build` 를 다시 돌려야** 패키지가 채워집니다.
`--clear` 없이 그냥 `uv venv` 를 다시 실행하면
`A virtual environment already exists at: .venv` 오류가 납니다.

### 2-2. dora 데몬 실행

```bash
dora up
```

확인:

```bash
pgrep -a dora
# dora coordinator --quiet
# dora daemon --quiet
```

이 두 프로세스는 백그라운드에 계속 떠 있습니다. 재부팅하거나 `dora destroy` 하기 전까지 한 번만 하면 됩니다.

### 2-3. 데이터플로우 빌드 (원하는 것만)

```bash
dora build dataflow_angle_simu.yml --uv
```

각 노드의 `build:` 항목(`pip install -e ...`, `cargo build -p AHControl`)이 실행됩니다.
파이썬 의존성(mujoco, mink, qpsolvers, scipy 등)을 받느라 **첫 빌드는 몇 분 걸립니다.**

### 2-4. ⚠️ dora 버전 불일치 해결 (거의 필수)

레포의 `pyproject.toml`은 파이썬 `dora-rs`를 `<=0.3.13`(메시지 포맷 v0.6.0)으로 고정해 뒀습니다.
그런데 요즘 설치되는 dora CLI는 0.5.x(v0.8.0)라서, 그대로 실행하면 이렇게 죽습니다:

```
RuntimeError: Could not initiate node from environment variable.
Caused by:
   2: version mismatch: message format v0.6.0 is not compatible with expected message format v0.8.0
```

**해결: 파이썬 쪽을 CLI 버전에 맞춥니다.**

```bash
dora --version                       # 예: dora-cli 0.5.0
uv pip install "dora-rs==0.5.0"      # ← CLI와 같은 메이저·마이너 버전으로
```

> 🔁 **`dora build`를 다시 실행하면 pyproject의 핀 때문에 0.3.13으로 되돌아가 또 깨집니다.**
> 빌드할 때마다 위 `uv pip install` 한 줄을 다시 돌리거나,
> 아예 `AHSimulation/pyproject.toml`과 `HandTracking/pyproject.toml`의
> `"dora-rs>=0.3.11,<=0.3.13"`을 `"dora-rs>=0.5.0"`으로 고쳐 두세요.

반대 방향(CLI를 0.3.13으로 내리기)도 가능합니다. 그러면 Rust 쪽 `AHControl/Cargo.toml`의
`dora-node-api = "0.3.11"`과 그대로 맞아떨어지지만, CLI는 시스템 전역이라
다른 프로젝트의 dora 사용에도 영향을 줍니다. **버전 3개(CLI · 파이썬 `dora-rs` · Rust
`dora-node-api`)가 모두 같은 계열이기만 하면 됩니다.**

---

## 3. 데모 실행

> `uv pip install "dora-rs==0.5.0"` 줄은 pyproject 핀을 고친 뒤로는 필요 없습니다.
> (2-4 참고 — 이제 `dora build` 를 다시 해도 0.5.x 가 유지됩니다.)

### 어떤 dataflow 를 쓸까

| dataflow | 입력 | 오른손 | 왼손 | 실물 | 카메라 |
|---|---|:---:|:---:|:---:|:---:|
| `dataflow_motor_simu.yml` | 뷰어 슬라이더 | ✅ | ✅ | — | 불필요 |
| `dataflow_motor_real.yml` | 뷰어 슬라이더 | ✅ | — | ✅ | 불필요 |
| `dataflow_motor_real_2hands.yml` | 뷰어 슬라이더 | ✅ | ✅ | ✅ | 불필요 |
| `dataflow_angle_simu.yml` | 사인파 (자동) | ✅ | ✅ | — | 불필요 |
| `dataflow_tracking_simu.yml` | 웹캠 손 추적 | ✅ | ✅ | — | **필요** |
| `dataflow_tracking_real.yml` | 웹캠 손 추적 | ✅ | — | ✅ | **필요** |
| `dataflow_tracking_real_2hands.yml` | 웹캠 손 추적 | ✅ | ✅ | ✅ | **필요** |

실물 양손을 쓰는 것(`*_2hands`)은 `AHControl/config/2hands.toml`(모터 16개)을 참조합니다.

### 3-0. 모터각 직접 조절 — 카메라 불필요 🎛️ 하드웨어 점검에 가장 좋습니다

MuJoCo 뷰어의 **Control 패널 슬라이더 8개**로 서보 목표각을 직접 조절합니다.
카메라도 손 추적도 필요 없어서, 조립·영점 확인용으로 가장 편합니다.

```bash
# 시뮬레이션만 (로봇 없이 안전하게 확인)
dora build dataflow_motor_simu.yml --uv
dora run   dataflow_motor_simu.yml --uv

# 실물 오른손까지 움직이기
dora build dataflow_motor_real.yml --uv
dora run   dataflow_motor_real.yml --uv

# 실물 양손 (서보 16개, 2hands.toml)
dora build dataflow_motor_real_2hands.yml --uv
dora run   dataflow_motor_real_2hands.yml --uv
```

뷰어 오른쪽 패널이 안 보이면 아래 화살표(`>`)를 눌러 펼치고 **Control** 탭을 선택하세요.
슬라이더 이름은 `finger1_motor1` … `finger4_motor2` 로 서보 8개와 1:1 대응합니다.

- **범위**: ±90° (`ctrlrange`). MJCF 에서 관절 가동범위를 상속(`inheritrange="1"`)하므로
  슬라이더가 프로젝트의 각도 한계를 벗어날 수 없습니다.
- **시작 자세**: 켜자마자 튀지 않도록 `ctrl` 초기값을 현재(영점) 자세로 맞춰 둡니다.
- 이 모드에서는 역기구학을 돌리지 않고, `-m motor` 로 동작합니다
  (`mj_mink_right.py` / `mj_mink_left.py` 의 `step_with_ctrl`).

> 왜 `qpos` 에 값을 직접 넣지 않고 `mj_step` 을 쓰나: 이 손은 connect 등식 구속 20개로
> 묶인 폐루프 병렬 기구라, 모터 관절만 강제로 써 넣으면 링크가 어긋납니다
> (실측 구속 잔차 0.0168). 물리 적분을 거치면 잔차 0, 모터각 오차 4e-5 rad 입니다.

#### 움직임 기록하기 — `--save`

**시뮬레이션 노드를 쓰는 모든 dataflow에서 됩니다** (모터 모드든 트래킹이든):

```bash
./run.sh dataflow_motor_real.yml --save
./run.sh dataflow_motor_real_2hands.yml --save
./run.sh dataflow_tracking_real.yml --save
./run.sh dataflow_tracking_real_2hands.yml --save
./run.sh dataflow_tracking_simu.yml --save
```

⚠️ **`dora run` 에 `--save` 를 직접 붙일 수는 없습니다.** `dora run` 은 `--uv` 와
`--stop-after` 만 받고 나머지는 거부합니다 (`error: unexpected argument '--save'`).
그래서 `run.sh` 래퍼를 씁니다 — `--save` 를 걷어내 `AH_SAVE` 환경변수로 바꿔 전달하고,
`--uv` 는 자동으로 붙여 줍니다. 나머지 인자는 그대로 `dora run` 에 넘어갑니다.

저장 위치는 **`out/<날짜_시간>/`** 입니다 (예: `out/2026-08-05_18-01-29/`).
폴더 이름을 래퍼가 한 번만 정하므로 양손 dataflow 처럼 노드가 여러 개여도 **한 폴더에** 모입니다.

| 파일 | 내용 |
|---|---|
| `r_motors.png` / `r_motors_deg.csv` | 모터 관절 8개 각도 (손가락별 4단 그래프) |
| `r_joints.png` / `r_joints_deg.csv` | 종속 링크 관절 24개 각도 (손가락별 6개씩) |
| `r_tips.png` / `r_tips_mm.csv` | 손끝 `tip1`~`tip4` 위치 x/y/z (실선) |
| `r_targets_mm.csv` | 손끝 **목표** 위치 (트래킹 입력) |

`r_tips.png` 에는 실제 위치(실선)와 목표 위치(점선)가 겹쳐 그려집니다.
트래킹 데모에서는 이 그래프로 **역기구학이 카메라 목표를 얼마나 따라갔는지**를 볼 수 있습니다.
(모터 모드에서는 목표를 쓰지 않으므로 점선은 의미가 없습니다)

왼손이 있으면 `l_` 로 시작하는 같은 구성이 함께 저장됩니다.
샘플링은 `tick_ctrl` 주기(10ms, 100Hz)이고, 각도는 도(deg), 위치는 mm 단위입니다.

기록은 dataflow 가 멈출 때(`Ctrl+C`, `--stop-after`, 뷰어 창 닫기) 저장됩니다.

> 참고: 종료 시 노드가 `exited with code 139`(SIGSEGV)로 끝나는 경우가 있는데,
> 이는 MuJoCo 뷰어를 닫을 때 나는 기존 증상이라 `--save` 와 무관하며
> (기록을 끄고 돌려도 똑같이 납니다) 파일 저장은 그 전에 끝납니다.

### 3-A. 각도 제어 시뮬레이션 — 웹캠·하드웨어 불필요 ✅

```bash
cd ~/AmazingHand/Demo
dora build dataflow_angle_simu.yml --uv   # 최초 1회
uv pip install "dora-rs==0.5.0"           # 2-4 참고
dora run  dataflow_angle_simu.yml --uv
```

**정상 동작 모습**: MuJoCo 뷰어 창 2개(왼손·오른손)가 뜨고, 네 손가락이 1Hz 사인파로
굽혔다 펴지며 좌우로 벌어졌다 모입니다.

동작 원리: `AHSimulation/examples/finger_angle_control.py`가 50ms마다 손끝 목표 자세를
쿼터니언으로 만들어 보내고(`hand_quat`), 좌우 시뮬레이션 노드가 그 자세를 만족하는
관절각을 역기구학으로 풉니다. 굽힘 범위는 0°~140°, 벌림 범위는 -20°~+20°입니다.

**종료**: 터미널에서 `Ctrl+C`.

### 3-B. 웹캠 손 추적 → 시뮬레이션 — 웹캠 필요

```bash
dora build dataflow_tracking_simu.yml --uv
uv pip install "dora-rs==0.5.0"
dora run  dataflow_tracking_simu.yml --uv
```

카메라 앞에서 손을 움직이면 시뮬레이션 손이 따라 합니다.
MuJoCo 창 2개에 더해 웹캠 영상 창(`MediaPipe Hands`)도 뜹니다.

#### 목표 자세 떨림 보정 / 불필요한 연산 생략

추적 목표에는 늘 잡음이 섞여 있어, 손을 가만히 둬도 목표가 미세하게 떨립니다.
그대로 두면 역기구학(QP 풀이)을 쉬지 않고 돌리게 되므로, 시뮬레이션 노드가 두 단계로 거릅니다.

1. **데드밴드** — 목표 변화가 `--deadband`(기본 2mm)보다 작으면 잡음으로 보고 버립니다.
2. **저역통과** — 통과한 변화도 `--smooth`(기본 0.5)로 부드럽게 만듭니다.

그리고 tick 마다 **목표가 바뀌었거나 아직 수렴 중일 때만** IK 를 돌립니다.
해의 속도가 `--idle-eps`(기본 1e-3) 아래로 떨어지면 수렴으로 보고 계산을 멈춥니다.

종료할 때 얼마나 아꼈는지 찍힙니다:

```
[ik] l: tick 9233, IK 838회 (건너뜀 8395, 90.9%)   ← 왼손이 화면에 없을 때
[ik] r: tick 6537, IK 4701회 (건너뜀 1836, 28.1%)  ← 오른손을 실제로 움직이는 중
```

값을 바꾸려면 dataflow 의 `args` 에 붙이면 됩니다:

```yaml
args: --deadband 0.004 --smooth 0.7      # 더 둔하게(잡음에 강하게)
args: --deadband 0                       # 필터 끄기 (기존 동작)
```

- 손이 화면에 없거나 멈춰 있으면 IK 가 사실상 돌지 않습니다.
- 5cm 를 실제로 움직이면 입력 3회(≈150ms) 만에 오차 6mm 까지 따라붙습니다.
  더 민첩하게 하려면 `--smooth` 를 낮추세요(반응 빠름, 떨림 증가).

- **카메라 번호가 하드코딩돼 있습니다.** `HandTracking/HandTracking/main.py:177`의
  `cv2.VideoCapture(0)` — 웹캠이 `/dev/video0`이 아니면 이 숫자를 바꾸세요.
  RealSense처럼 `/dev/video*`를 여러 개 만드는 카메라는 0번이 깊이(depth) 노드라
  **열리지도 않습니다.** `./ah_devices.sh` 로 컬러 영상 노드가 몇 번인지 확인하세요.
  `ah_devices.sh install` 을 해뒀다면 고정 이름에서 번호를 얻어 쓰는 게 가장 안전합니다:
  ```python
  import os, re
  idx = int(re.search(r"\d+$", os.path.realpath("/dev/ahv")).group())
  cap = cv2.VideoCapture(idx)          # /dev/ahv 가 가리키는 번호로 열기
  ```
  (`cv2.VideoCapture("/dev/ahv")` 처럼 경로 문자열을 바로 넘기는 방식은
  OpenCV가 다른 백엔드를 시도하다 멈추는 경우가 있어 권하지 않습니다.)
- MediaPipe 손 검출 임계값은 0.5(`main.py:181`), 좌/우 판별 신뢰도가 **0.8을 넘는 손만**
  사용합니다(`main.py:34`). 조명이 어둡거나 손이 화면 끝에 있으면 잘 안 잡힙니다.
- 웹캠 창에 포커스를 두고 **`q`** 를 누르면 트래킹 노드가 종료됩니다(`main.py:209`).

### 3-C. 웹캠 손 추적 → 실제 하드웨어 — 웹캠 + 조립된 손 필요

```bash
dora build dataflow_tracking_real.yml --uv        # cargo 빌드 포함, 오래 걸림
uv pip install "dora-rs==0.5.0"
dora run  dataflow_tracking_real.yml --uv
```

**실행 전 반드시 확인할 것** (자세한 건 4장):

1. 시리얼 포트가 `/dev/ttyACM0`이 맞는지 → 아니면 `dataflow_tracking_real.yml`의
   `args: --serialport ...`를 수정
2. `AHControl/config/r_hand.toml`의 모터 ID와 offset이 내 손과 맞는지
3. 서보에 전원이 들어와 있는지

양손을 쓰려면 `dataflow_tracking_real_2hands.yml`을 쓰세요. 이건
`AHControl/config/2hands.toml`(모터 16개)을 참조하고, 좌우 시뮬레이션 노드가 각각 붙습니다.

> ⚠️ **Rust 노드도 같은 버전 문제를 겪습니다.**
> `AHControl/Cargo.toml`의 `dora-node-api = "0.3.11"`은 실제로 **0.3.13**으로 해석되고,
> 이건 2-4의 파이썬 쪽과 똑같이 메시지 포맷 v0.6.0이라 CLI 0.5.x와 맞지 않습니다.
> (빌드 자체는 성공하므로, 실행 시점에야 드러납니다.)
>
> 해결: `AHControl/Cargo.toml`에서
> ```toml
> dora-node-api = "0.5"    # 기존 "0.3.11"
> ```
> 로 고친 뒤 `cargo build -p AHControl`.
> **소스 코드 수정 없이 그대로 컴파일되는 것을 확인했습니다** (0.5.0으로 해석됨).

---

## 4. 실제 하드웨어 설정

### 4-1. 손가락·모터 이름 규칙

![Motors naming](docs/finger.png)
![Fingers naming](docs/r_hand.png)

손가락 하나당 서보 2개(`motor1`, `motor2`)가 병렬 기구로 굽힘과 벌림을 함께 만듭니다.
오른손 기본 ID 배치는 `r_finger1`이 1·2번, `r_finger2`가 3·4번, `r_finger3`이 5·6번,
`r_finger4`(엄지)가 7·8번입니다.

### 4-2. AHControl 유틸리티

모두 `Demo/`에서 실행합니다. 공통 인자는 `-s/--serialport`(기본 `/dev/ttyACM0`)와
`-b/--baudrate`(기본 `1000000`)입니다.

> ⚠️ `--config`의 기본값은 `config/r_hand.toml`인데, 이 경로는 **실행한 디렉터리 기준**입니다.
> `Demo/`에서 실행하면 그런 파일이 없으므로 `-c AHControl/config/r_hand.toml`을 꼭 붙이세요.

```bash
# 1) 모터 ID 변경 — 조립 시 서보마다 1~8번 부여
#    새 서보는 보통 ID 1이므로, 하나씩 연결해 바꿔 나갑니다
cargo run --bin=change_id -- --old-id 1 --new-id 3

# 2) 모터 하나를 특정 위치로 이동 — 배선·회전 방향 확인용
cargo run --bin=goto -- --id 3 --pos 0

# 3) 영점 잡기 — 모터를 컴플라이언트(힘 풀림) 상태로 만들고,
#    손을 원하는 기준 자세로 잡은 뒤 그때의 TOML 내용을 화면에 출력
cargo run --bin=get_zeros -- -c AHControl/config/r_hand.toml

# 4) 설정 파일의 영점 자세로 손을 이동 — 3)의 결과 검증용
cargo run --bin=set_zeros -- -c AHControl/config/r_hand.toml
```

**권장 순서**: `change_id`로 ID 부여 → `goto`로 각 모터가 제대로 도는지 확인 →
`get_zeros`로 영점 측정 → 출력된 내용을 `AHControl/config/r_hand.toml`에 반영 →
`set_zeros`로 검증 → 데이터플로우 실행.

각 도구의 전체 인자는 `cargo run --bin=<도구> -- -h`로 볼 수 있습니다.

### 4-3. 시리얼 포트 권한

포트를 못 열면 대개 권한 문제입니다.

```bash
ls -l /dev/ttyACM0
sudo usermod -aG dialout $USER    # 적용하려면 로그아웃 후 재로그인
```

---

## 5. 문제 해결

| 증상 | 원인 / 해결 |
|---|---|
| `version mismatch: message format v0.6.0 ... v0.8.0` | 2-4 참고. 파이썬 노드면 `uv pip install "dora-rs==<CLI버전>"`, `hand_controller` 노드면 `AHControl/Cargo.toml`의 `dora-node-api`를 올릴 것 |
| `failed to register node with dora-daemon` | 데몬이 안 떠 있음. `dora up` 후 `pgrep -a dora`로 확인 |
| MuJoCo 창이 안 뜸 / GL 에러 | 디스플레이 없음. `echo $DISPLAY` 확인, SSH면 `ssh -X` |
| `dora build` 시 파이썬 버전 에러 | venv가 3.12가 아님. `uv venv --python 3.12 --clear`로 다시 생성 |
| 웹캠 데모에서 손이 안 잡힘 | 카메라 인덱스(`main.py:177`) 또는 조명 확인 |
| `Permission denied (/dev/ttyACM0)` | 4-3의 `dialout` 그룹 추가 |
| 중단 후 파이썬 노드가 남아 있음 | `pkill -f mj_mink; pkill -f finger_angle_control` |
| 상태를 완전히 초기화하고 싶음 | `dora destroy` 후 `dora up`부터 다시 |

### 유용한 명령

```bash
dora list                  # 실행 중인 데이터플로우 목록
dora destroy               # coordinator·daemon 종료
rm -rf .venv && uv venv --python 3.12    # 파이썬 환경 완전 재생성
```

---

## 6. 전체 절차 요약 (복붙용)

```bash
# --- 최초 1회 ---
cd ~/AmazingHand/Demo
uv venv --python 3.12
dora up
dora build dataflow_angle_simu.yml --uv
uv pip install "dora-rs==0.5.0"       # dora --version 결과에 맞출 것

# --- 매번 ---
dora run dataflow_angle_simu.yml --uv
```
