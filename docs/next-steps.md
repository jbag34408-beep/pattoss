# 이어서 할 작업 (2026-11-02 기준)

다른 컴퓨터에서 이어 작업할 때 이 문서부터 읽는다. 다 끝난 항목은 지우거나 체크한다.

## 1. 현재 상태

| 영역 | 상태 |
| --- | --- |
| 기획 | `concepts_brief.md`, `AGENTS.md`를 앱인토스 가이드에 맞춰 보완함 |
| 프론트 | `frontend/`: create-ait-app `--tds` 기본 템플릿. 화면 없음, `npm run dev` 동작 확인 |
| 콘솔 등록 | **안 됨.** ait-console MCP 로그인 전에 멈춤 |
| 백엔드 | `backend/`: Spring Boot 3.5.16 뼈대 + **Phase 1 완료**(V1 마이그레이션, 테스트 설정). `./gradlew build` 통과 |
| 설계 | `docs/designs/exp-and-pet-growth.md` **Approved**(D1~D5 추천안, D6 A) |
| 검토 기록 | `docs/designs/reviews/exp-and-pet-growth/` (Stage 5~9, 종합 보고서) |

## 2. 집 컴퓨터 준비

1. 저장소 받기: `git clone https://github.com/jbag34408-beep/pattoss.git`
2. 필요한 도구
   - Docker Desktop: 통합 테스트(Testcontainers)에 필요하다. 실행해 둔다
   - JDK 17 이상: Gradle을 돌리는 데 쓴다. JDK 21은 foojay 플러그인이 자동으로 받는다
   - Node 24 이상: 프론트에 필요하다
3. Claude Code 플러그인(AGENTS.md 5.0)
   - `claude plugin marketplace add toss/apps-in-toss-harness` → `claude plugin install ait@apps-in-toss -y`
   - `claude plugin marketplace add google/elephant-goldfish-model` → `claude plugin install egm@egm`
   - ponytail MCP 서버 연결
   - `/mcp`에서 apps-in-toss-console 로그인
4. 확인
   - `cd backend` 후 `./gradlew build` (Windows는 `.\gradlew.bat build`)가 통과하면 된다
   - `cd frontend` 후 `npm install` → `npm run dev`

## 3. 다음 작업 (순서대로)

### 3.1 백엔드 Phase 2: 순수 로직

설계 문서 "Detailed Implementation Plan"의 파일 4, 5, 6, 7, 10, 17, 18번을 만든다.

- `common/ClockConfig.java`: `Clock.systemUTC()` 빈
- `exp/DayClock.java`: `today()`, `planDeadline()`, `isBeforePlanDeadline()`, `now()`
- `pet/PetStage.java`: `of()`, `nextStageExp()` (경계 100/600/1800/4000)
- `pet/Species.java`
- `exp/ExpReason.java`: 선언 순서가 정산 `items` 순서다
- 테스트: `PetStageTest`, `DayClockTest` (03:59:59/04:00:00, 11:59:59/12:00:00)
- 완료 조건: 단위 테스트 통과

### 3.2 백엔드 Phase 3: 엔티티와 서비스

파일 8, 9, 11~15, 19, 20번을 만든다. 설계 문서에서 다음 규칙을 반드시 지킨다.

- 엔티티 ID는 `GenerationType.IDENTITY`
- 네이티브 쿼리의 `reason`은 `String`으로 넘긴다 (`ExpReason.name()`)
- 펫 행을 먼저 잠근다 (`findByIdForUpdate`)
- 회수액은 삭제 전후 합계의 차이로 구한다
- STREAK는 `streakDays > 0 && % 7 == 0`일 때만 지급한다
- 고정 Clock은 `TestcontainersConfiguration`에 `@Primary` 빈으로 추가한다 (`2026-11-02T03:00:00Z`)
- 통합 테스트에는 `@Transactional`을 붙이지 않는다. 테스트 데이터는 `JdbcTemplate`으로 넣고, 누적 로그는 과거 `plan_date`로 넣는다
- 동시성 테스트: 할 일 25개 → 그날 합계가 정확히 100이고 로그는 20행
- 완료 조건: 단위·통합 테스트 통과

### 3.3 Phase 4: 문서

- `docs/designs/SITEMAP.md`에서 이 문서의 상태를 "구현 완료"로 갱신한다

### 3.4 콘솔 앱 등록 (4단계에서 남은 일)

- `/mcp`로 ait-console에 로그인한 뒤 `miniapp_create`로 `pet-planner`를 등록한다
- 등록 내용은 사용자에게 먼저 보여 주고 확인을 받는다

### 3.5 그다음 설계 문서

- `/egm:egm-draft`로 `daily-plan-and-tasks.md`를 만든다 (브리프 11.3 순서)
- 이 문서로 넘어온 항목
  - D1: `PUT /tasks/{id}/done` API
  - D4: 펫 기분 계산
  - D5: `POST /pets`, `GET /pets/collection`과 D2-A의 날짜 조건
  - PLAN 확정 뒤 할 일 삭제를 막을지 (Open Question)
  - 호출자 규칙: 트랜잭션 첫 단계에서 펫을 잠그고 소유권을 확인한다

## 4. 사용자 확인이 남은 것

- `foojay-resolver-convention` 플러그인(JDK 21 자동 다운로드)을 계속 쓸지. 빼려면 JDK 21을 직접 설치한다
- `backend/.gitignore`의 `*.zip` 규칙은 비밀 값이 아닌 zip까지 막는다. 필요하면 조정한다
