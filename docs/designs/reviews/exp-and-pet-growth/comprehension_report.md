# Stage 6 — Comprehension Test 보고서

- 대상: `docs/designs/exp-and-pet-growth.md` (FeatureRange 1..247, DetailedRange 248..406)
- 검토자: egm-comprehension (문서 표준 없음, 자기완결성 시험)
- 날짜: 2026-11-02

**What this proposes**

이 문서는 경험치(EXP) 서비스 계층을 설계한다. HTTP 엔드포인트는 범위에 넣지 않았다. `ExpService`는 다른 기능(계획·할 일 기능)이 그 기능의 트랜잭션 안에서 호출하는 서비스다. 계획 확정(PLAN), 할 일 완료(TASK), 하루 마감 정산(MAIN_GOAL, REFLECTION, BONUS_RATE, STREAK)에 지급하고, 체크 해제 시 TASK 지급을 회수한다. 모든 지급은 펫 행 비관적 잠금 → 하루 상한 100(STREAK 제외)으로 지급액 자르기 → `INSERT ... ON CONFLICT DO NOTHING`으로 멱등 삽입 → `pets.total_exp`를 로그 합계로 덮어쓰기 → `PetStage.of`로 단계 갱신 순서다. 날짜는 `DayClock`(서울 04:00 경계, 계획 마감 12:00)이 주입된 `Clock`으로 계산한다. 산출물은 Flyway V1(users, pets, exp_logs), 엔티티·리포지토리·DTO, 단위·통합 테스트이며, D1~D5가 미결정으로 남아 있다.

**How the existing system works, per this document**

백엔드는 Spring Boot 뼈대다. Flyway 마이그레이션 폴더는 `.gitkeep`만 있고, JPA는 `ddl-auto: validate`다. 컨텍스트 로드 테스트 하나가 자기 안에 Testcontainers PostgreSQL을 띄운다. 스키마, API, 경험치 표, 동시성 방침은 아직 코드가 아니고 `concepts_brief.md`와 `AGENTS.md`(고정 결정)에만 있다. 뼈대 파일은 문서 설명과 일치했다.

## Findings

### 1. 🟡 Major — 문서 안 파일 번호가 틀렸다

- 범위: 250행 "6번 파일의 상한 쿼리", 314행 "9번 리포지토리의 네이티브 쿼리"
- 6번은 `Species.java`, 9번은 `ExpReason.java`다. 상한 쿼리·네이티브 쿼리는 11번 `ExpLogRepository.java`, 상한 로직은 12번 `ExpService.java`다. D2-B의 영향 범위를 잘못 이해하게 만든다.

### 2. 🟡 Major — 단계 하락 문제를 D2에 미뤘지만 D2 선택지에 없다

- 범위: 114행(CUJ 4), 199행
- D2의 A/B/C는 졸업 후 처리와 새 알 시점만 다룬다. 회수로 단계가 내려가는 것을 허용할지는 어디에도 없다. 고정 결정 7·브리프 2.3("퇴화하지 않는다")과 충돌하는지, "퇴화"를 좁게 해석한 것인지 독자가 알 수 없다. 해석을 문서에 쓰거나 별도 결정(D6)으로 분리해야 한다.

### 3. 🟡 Major — 브리프 6.2와 다른 잠금 순서를 밝히지 않았다

- 범위: 160행
- 브리프 6.2는 펫 행을 먼저 잠그고 `done`을 뒤집는데, 문서는 반대 순서이면서 차이와 이유를 적지 않았다. 다음 문서가 지켜야 할 계약이므로 한 줄 설명이 필요하다.

### 4. 🟢 Nit — 회수 흐름 "1~3은 같다"

- 2·3단계는 회수와 무관하다. "1단계(펫 잠금) 후"로 쓴다.

### 5. 🟢 Nit — "오늘 합계"가 실제로는 호출자가 넘긴 `planDate` 기준이다

- 범위: 148행, 108행
- 04:05 자동 마감 배치에서는 대상 날짜가 이미 "어제"다. "해당 planDate의 합계"로 써야 날짜를 호출자가 정한다는 점이 분명하다.

### 6. 🟢 Nit — `gainedExp`가 음수일 수 있다는 계약이 Detailed에만 있다

- 범위: 334행, 114행
- CUJ 4의 Then에 `gainedExp: -5`를 적어 계약을 한 곳에서 보이게 한다.

### 7. 🟢 Nit — "계획 기능", `grantX`가 정의 없이 쓰인다

- "계획 기능"은 `daily-plan-and-tasks.md`의 plan 패키지 코드임을 첫머리에서 밝히고, `grantX`가 grantPlan/grantTask/settle을 묶은 이름임을 흐름도 위에 적는다.

### 8. 🟢 Nit — D2-A에서 새 알을 고르지 않으면 졸업 펫이 계속 받는지 불명확

- 졸업 다음 날 이후에도 `is_active = true`로 남아 지급을 받는지 한 줄로 밝혀야 선택지를 비교할 수 있다.

## 판정

Blocker 없음. Major 3건은 문서 수정으로 해결된다. 정의되지 않은 프로젝트 고유 용어는 없었다.

## 확인하지 않은 것

기술적 정확성(SQL, JPA, 동시성)은 이 단계 범위가 아니다. SITEMAP.md는 열지 않았다.
