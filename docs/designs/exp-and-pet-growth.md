# 경험치 지급과 펫 성장 (exp-and-pet-growth)

*   **Author:** ParkJongHwan
*   **Status:** Draft (결정 필요 항목 D1~D5 승인 대기)
*   **Date:** 2026-11-02

--------------------------------------------------------------------------------

## Overview

펫 플래너의 모든 보상은 경험치(EXP)로 표현되고, 펫의 성장 단계는 누적 경험치로만 정해진다. 이 문서는 경험치를 지급·회수·정산하는 서버 로직(`ExpService`), 하루의 경계를 계산하는 `DayClock`, 단계를 계산하는 `PetStage`, 그리고 이를 저장하는 `pets`·`exp_logs` 테이블을 설계한다.

이 문서가 만드는 것은 HTTP 엔드포인트가 아니라 **다른 기능이 호출하는 서비스 계층**이다. 할 일 체크(`POST /tasks/{id}/toggle`)와 하루 마감(`POST /plans/today/close`)은 다음 문서 `daily-plan-and-tasks.md`에서 이 서비스를 호출한다. 기능 순서상 첫 번째인 이유는 나머지 기능이 모두 이 결과(`gainedExp`, `pet`, `settlement`)를 쓰기 때문이다 (`concepts_brief.md` 11.3).

## The Problem

경험치 규칙은 단순해 보이지만, 틀리면 사용자 신뢰가 바로 깨지는 지점이 여러 곳 있다.

*   **중복 지급**: 같은 요청이 두 번 오면(더블 탭, 네트워크 재시도) 같은 할 일로 경험치를 두 번 줄 수 있다.
*   **하루 상한 초과**: 두 요청이 동시에 "오늘 합계 95"를 읽으면 둘 다 +5를 넣어 105가 된다.
*   **되돌리기**: 체크를 해제하면 그 할 일로 받은 경험치만 정확히 빼야 한다. 총합에만 더해 두면 무엇을 빼야 할지 알 수 없다.
*   **날짜 경계**: 새벽 2시에 체크한 할 일은 "어제"의 것이다. 서버 기본 시간대나 `LocalDate.now()`를 쓰면 배포 환경에 따라 결과가 달라진다.
*   **단계 불일치**: 단계를 따로 더하거나 빼면 누적 경험치와 단계가 어긋날 수 있다.

해결 방향은 `concepts_brief.md`에서 이미 정했다. 경험치를 이벤트(`exp_logs`)로 쌓고, DB 유니크 제약으로 중복을 막고, 펫 행 잠금으로 상한을 지키고, 날짜는 `DayClock` 하나로, 단계는 `PetStage.of(totalExp)` 순수 함수 하나로 계산한다.

## Goals

*   할 일 완료, 계획 확정, 하루 마감 때 `concepts_brief.md` 2.2의 경험치 표대로 지급한다
*   같은 지급 사유(`reason`)와 대상(`ref_id`)에는 펫당 한 번만 지급한다. 같은 요청이 두 번 와도 결과가 같다
*   하루 지급 합계(STREAK 제외)가 100을 넘지 않는다. 동시 요청에서도 지킨다
*   체크 해제 시 그 할 일의 TASK 지급만 정확히 회수한다
*   `pets.total_exp`는 언제나 그 펫의 `exp_logs.amount` 합계와 같고, `pets.stage`는 언제나 `PetStage.of(total_exp)`와 같다
*   하루 경계(서울 04:00)와 계획 마감(서울 12:00) 판단이 `Clock`을 고정한 테스트로 검증된다

## Non-Goals

*   HTTP 엔드포인트 (할 일 체크, 하루 마감, 홈, 알 고르기, 도감). 이 문서는 서비스 계층만 만든다
*   `daily_plans`, `tasks` 테이블과 그 로직 (완료율 계산, 연속 기록 일수 계산, 04:05 자동 마감 배치)
*   로그인, 푸시, 광고, 프론트 화면
*   펫 기분(HAPPY/NORMAL/SAD) 계산 (D4 참고)
*   꾸미기 아이템 (`pet_items`, MVP 이후)

## Open Questions

답이 여러 개라 소유자가 골라야 하는 결정이다. 각 항목의 추천은 `concepts_brief.md`에 이미 정한 내용을 근거로 했다. 추천을 따르지 않으면 표시한 절이 바뀐다.

### D1. 할 일 체크 요청을 "뒤집기"로 둘지 "목표 상태 지정"으로 바꿀지

`concepts_brief.md` 6.4는 "같은 할 일을 빠르게 두 번 누르는 경우는 UNIQUE 제약이 막는다"고 하지만, 5장의 API는 `POST /tasks/{id}/toggle`(뒤집기)다. 뒤집기에서는 두 번째 요청이 첫 번째를 **되돌린다**(체크 → 해제). 유니크 제약은 "같은 지급이 두 번 들어가는 것"만 막고, 의도치 않은 해제는 막지 못한다. 이 문서의 `ExpService`는 두 방식 모두에서 동작하지만, 6.4의 의도가 실제로 성립하는지는 API 모양에 달려 있다.

*   **A. 뒤집기 유지** (`POST /tasks/{id}/toggle`): 프론트가 단순하다. 더블 탭과 재시도가 상태를 되돌린다. 프론트에서 버튼을 잠시 막아야 한다.
*   **B. 목표 상태 지정** (`PUT /tasks/{id}/done`, body `{"done": true|false}`): 같은 요청을 몇 번 보내도 결과가 같다. 6.4의 "두 번 눌러도 한 번만"이 서버에서 성립한다. 5장 API 표 한 줄이 바뀐다.
*   **추천: B.** 브리프 6.4가 원한 동작이 서버만으로 보장되고, `ExpService.grantTask`/`revokeTask`가 이미 멱등이라 추가 코드가 없다. 결정은 `daily-plan-and-tasks.md`에 반영한다.

### D2. 졸업(4,000 EXP) 이후 처리와 새 알을 고르는 시점

2.3은 "4,000 EXP에 도달하면 도감에 등록되고 새 알을 고를 수 있다"고만 정했다. 그런데 하루 상한과 중복 방지가 **펫 기준**(`exp_logs.pet_id`)이라, 같은 날 새 알로 바꾸면 그날의 PLAN·REFLECTION 지급을 새 펫이 한 번 더 받을 수 있다 (`ref_id`가 같은 plan id여도 `pet_id`가 다르면 유니크 제약에 걸리지 않음).

*   **A. 그날은 졸업한 펫이 끝까지 받고, 새 알은 다음 날부터 고른다**: 도달 즉시 `graduated_at`을 기록하고 단계는 GRADUATED로 둔다. 그날 남은 지급도 졸업한 펫에 쌓인다(4,000 초과 허용). 알 고르기(`POST /pets`)는 졸업 펫의 `graduated_at` 날짜(DayClock 기준)가 오늘보다 이전일 때만 허용하고, 그때 졸업 펫의 `is_active`를 false로 바꾼다. 스키마 변경이 없다.
*   **B. 즉시 비활성화하고 바로 새 알을 고른다**: 사용자 대기가 없다. 중복 지급을 막으려면 상한·유니크 기준을 사용자 단위로 바꿔야 한다 (`exp_logs`에 `user_id` 추가, 유니크 키 변경). 브리프 4장 스키마가 바뀐다.
*   **C. 졸업 후에도 계속 키우고, 새 알은 사용자가 원할 때 고른다**: 졸업 펫과 이별 시점을 사용자가 정한다. B와 같은 중복 문제가 "새 알을 고른 날"에 생기므로 A의 날짜 조건이 결국 필요하다.
*   **추천: A.** 브리프 4장 스키마와 "하루 상한 100"을 그대로 지키면서 하루에 두 펫이 같은 계획으로 지급받는 경우를 없앤다. 대기는 최대 하루다.

### D3. 첫 마이그레이션에 `users` 테이블을 넣을지

`pets.user_id`는 `users(id)`를 참조하지만 `users`는 로그인 문서(`auth-toss-login.md`)의 범위다.

*   **A. V1에 `users`를 브리프 4장 스키마 그대로 만든다**: FK가 처음부터 걸리고, 이후 문서에서 테이블을 다시 만들지 않는다. 로그인 로직은 만들지 않는다.
*   **B. V1은 `pets`, `exp_logs`만 만들고 FK 없이 `user_id BIGINT`만 둔다**: 범위가 깔끔하다. 로그인 문서에서 FK를 추가하는 마이그레이션이 하나 더 필요하고, 그 사이에 FK 없는 데이터가 생길 수 있다.
*   **추천: A.** `users` 스키마는 브리프에서 이미 확정됐고(`push_agreed_at` 포함), `ON DELETE CASCADE`로 탈퇴 시 삭제가 처음부터 보장된다.

### D4. 펫 기분 계산을 어느 문서에서 할지

기분은 "최근 3일 평균 완료율"인데, 완료율은 `daily_plans.completion_rate`에 있고 이 테이블은 다음 문서 범위다.

*   **A. 이 문서에서 기분 계산을 정의한다**: 2.3 범위를 이 문서에서 다 닫는다. 아직 없는 테이블을 전제로 설계해야 하고, 테스트할 데이터가 없다.
*   **B. `daily-plan-and-tasks.md`로 넘긴다**: 테이블과 계산이 같은 문서에 있다. 그 문서에서 "계획이 없던 날을 0%로 셀지"를 함께 정한다.
*   **추천: B.** 계산에 필요한 데이터가 생기는 문서에서 정하는 쪽이 검증할 수 있다.

### D5. 알 고르기·도감 API를 어느 문서가 맡을지

`POST /pets`와 `GET /pets/collection`은 브리프 5장에 있지만, 11.3 표의 네 문서 어디에도 배정되지 않았다.

*   **A. 이 문서에 추가한다**: 펫 관련이 한 문서에 모인다. 이번 범위(5장 제외)를 넓힌다.
*   **B. `daily-plan-and-tasks.md`에 넣는다**: 첫 API 문서에서 `GET /home`과 함께 다룬다. 온보딩에서 알을 고른 뒤 홈으로 가는 흐름이 한 문서에 있다.
*   **C. 별도 문서 `pet-selection-and-collection.md`를 만든다**: 각 문서가 작다. 문서가 하나 늘어난다.
*   **추천: B.** 이번 범위를 지키면서, 홈 화면이 처음 동작하는 데 필요한 API를 한 문서에서 만든다. D2의 "새 알 고르기 날짜 조건"도 그 문서에서 구현한다.

## Critical User Journeys (CUJs)

### CUJ 1: 할 일 체크로 경험치를 받는다

*   **Given**: 오늘 계획이 마감 전이고, 펫의 오늘 합계가 40 EXP다. 할 일 T는 정오 전에 추가됐다
*   **When**: 사용자가 T를 완료로 체크하고, 계획 기능이 `ExpService.grantTask`를 부른다
*   **Then**: `exp_logs`에 `(TASK, T.id, 5)`가 한 줄 생기고, 응답에 `gainedExp: 5`와 갱신된 펫(누적, 단계, 다음 단계 기준, 단계 변화 여부)이 담긴다

### CUJ 2: 같은 요청이 두 번 와도 한 번만 지급된다

*   **Given**: CUJ 1 직후다
*   **When**: 네트워크 재시도로 같은 지급 요청이 한 번 더 온다
*   **Then**: 새 줄이 생기지 않고 `gainedExp: 0`이다. 에러로 처리하지 않는다

### CUJ 3: 하루 상한에서 잘린다

*   **Given**: 펫의 오늘 합계가 98 EXP다
*   **When**: 할 일 하나를 체크한다
*   **Then**: `exp_logs`에 2 EXP만 쌓이고 `gainedExp: 2`다. 합계가 100이면 줄을 만들지 않고 `gainedExp: 0`이다

### CUJ 4: 체크를 해제하면 회수된다

*   **Given**: 할 일 T로 5 EXP를 받았다
*   **When**: 사용자가 T를 해제하고 계획 기능이 `ExpService.revokeTask`를 부른다
*   **Then**: `(TASK, T.id)` 줄이 지워지고, 누적 경험치가 5 줄고, 단계가 다시 계산된다 (내려갈 수 있다. D2 참고: 졸업은 되돌리지 않는다)

### CUJ 5: 하루 마감 정산

*   **Given**: 오늘 PLAN 10, TASK 25를 받았고, 핵심 목표 할 일이 완료 상태다. 완료율 83%, 회고가 있다. 오늘로 연속 기록이 7일째다
*   **When**: 계획 기능이 `ExpService.settle`을 부른다
*   **Then**: MAIN_GOAL 30, REFLECTION 10, BONUS_RATE 15(= (10+25+30+10) × 0.2), STREAK 50이 지급된다. 정산 결과에는 사유별 합계와 펫 상태가 담긴다. STREAK는 상한과 무관하게 지급된다

### CUJ 6: 새벽의 체크는 어제의 것이다

*   **Given**: 서울 시각 03:59다
*   **When**: `DayClock.today()`를 부른다
*   **Then**: 어제 날짜가 나온다. 04:00에는 오늘 날짜가 나온다

## Technical Plan (Architecture)

### 구성 요소

| 구성 요소 | 패키지 | 역할 |
| --- | --- | --- |
| `DayClock` | `exp` | 주입된 `Clock`으로 "오늘"(서울 04:00 경계)과 계획 마감(서울 12:00)을 계산한다. 날짜 계산의 유일한 입구 |
| `PetStage` | `pet` | 단계 enum. `of(totalExp)` 순수 함수와 다음 단계 기준값 |
| `Pet` | `pet` | `pets` 엔티티. 누적 경험치를 받으면 단계와 졸업 시각을 스스로 갱신한다 |
| `ExpLog`, `ExpReason` | `exp` | `exp_logs` 엔티티와 지급 사유 enum |
| `ExpService` | `exp` | 지급·회수·정산. 경험치 규칙(금액, 조건, 상한)은 모두 여기에만 있다 |

### 지급 흐름 (모든 지급 공통)

```text
호출자(계획 기능, 트랜잭션 안)
  └─ ExpService.grantX(...)                @Transactional (호출자 트랜잭션에 합류)
       1. pets 행 잠금: SELECT ... FOR UPDATE      ← 동시 요청 직렬화
       2. 지급 조건 확인 (예: PLAN은 할 일 3개 이상, 마감 전 확정)
       3. 요청액 결정 (TASK: 마감 후 추가면 2, 아니면 5)
       4. 오늘 합계 = SUM(amount) WHERE pet_id, plan_date, reason <> STREAK
       5. 지급액 = max(0, min(요청액, 100 - 오늘 합계))   (STREAK는 요청액 그대로)
       6. 지급액 > 0 이면
            INSERT ... ON CONFLICT (pet_id, reason, ref_id) DO NOTHING
            → 들어간 행이 0이면 "이미 지급됨" → 지급액 = 0
       7. total = SUM(amount) WHERE pet_id      ← 캐시 재계산 (직접 더하지 않음)
       8. pet.applyTotalExp(total, now)        ← 단계·졸업 갱신
       9. ExpResult(gainedExp, PetSnapshot) 반환
```

*   **중복 지급**: `ON CONFLICT DO NOTHING`을 쓴다. 제약 위반 예외를 잡는 방식은 PostgreSQL에서 트랜잭션 전체를 실패 상태로 만들어 호출자의 할 일 체크까지 롤백시키므로 쓸 수 없다. 결과는 브리프 6.4와 같다 ("이미 지급됨", 에러 아님).
*   **동시성**: 4~6단계는 펫 행 잠금 아래에서만 실행된다. 같은 펫에 대한 두 지급은 순서대로 처리되므로 상한 계산이 겹치지 않는다.
*   **잠금 순서**: 호출자는 자기 행(할 일 또는 계획)을 먼저 수정하고 마지막에 `ExpService`를 부른다. 펫 행은 항상 마지막에 잠그므로, 잠금을 거꾸로 잡는 경로가 생기지 않는다.
*   **캐시 재계산**: `pets.total_exp`에 증감을 더하지 않고 매번 합계로 덮어쓴다 (AGENTS.md 고정 결정 3). 펫당 로그는 하루 10줄 안팎이라 `ix_exp_logs_pet_date`(앞 열 `pet_id`)로 충분하다.

### 회수 흐름 (체크 해제)

1~3은 같다 (펫 잠금). `DELETE FROM exp_logs WHERE pet_id, reason = TASK, ref_id = taskId` 후 7~9를 실행한다. 지운 행이 없으면(상한 때문에 지급되지 않았던 할 일) 회수액은 0이다. 회수 뒤 다른 할 일을 체크하면 비워진 상한만큼 다시 받을 수 있다.

### 정산 흐름 (하루 마감)

`settle`은 호출자가 계산한 사실(핵심 목표 완료 여부, 회고 여부, 완료율, 연속 기록 일수)을 받아 아래 순서로 지급하고, 마지막에 그날의 로그를 사유별로 합쳐 돌려준다. 완료율과 연속 기록 일수의 계산은 `daily-plan-and-tasks.md`의 몫이다.

1. 핵심 목표 할 일 완료 → `MAIN_GOAL` 30 (ref: plan id, 상한 적용)
2. 회고 있음 → `REFLECTION` 10 (ref: plan id, 상한 적용). 자동 마감은 회고가 없으므로 지급되지 않는다
3. 완료율 ≥ 80 → `BONUS_RATE` = floor(그날 합계(STREAK 제외) × 0.2) (ref: plan id, 상한 적용)
4. 연속 기록 일수가 7의 배수 → `STREAK` 50 (ref: plan id, 상한 미적용)

한 번의 펫 잠금 아래에서 1~4를 처리하고, 캐시 재계산은 끝에 한 번 한다.

### 계획 확정 지급

`grantPlan`은 할 일 수와 확정 시각을 받아 "할 일 3개 이상"과 "확정 시각이 그날 서울 12:00 이전"을 `ExpService`에서 확인한다. 조건을 호출자에게 맡기지 않는 이유는 경험치 규칙이 `ExpService` 한 곳에만 있어야 하기 때문이다 (브리프 6장).

### 날짜 계산

```text
DayClock.today()                 = (now in Asia/Seoul) - 4h 의 날짜
DayClock.planDeadline(planDate)  = planDate 12:00 Asia/Seoul (Instant)
DayClock.isBeforePlanDeadline(planDate, at) = at < planDeadline(planDate)
```

`Clock` 빈은 `Clock.systemUTC()`로 등록한다. 시간대는 `DayClock`이 `Asia/Seoul`로 명시해 바꾸므로 서버 시간대와 무관하다.

### 단계 계산

```text
PetStage.of(e): e >= 4000 → GRADUATED, >= 1800 → ADULT, >= 600 → JUNIOR, >= 100 → BABY, 그 외 EGG
nextStageExp: EGG→100, BABY→600, JUNIOR→1800, ADULT→4000, GRADUATED→null
```

`Pet.applyTotalExp(total, now)`는 `totalExp`와 `stage = PetStage.of(total)`을 함께 바꾼다. 처음으로 GRADUATED가 되면 `graduatedAt = now`를 기록하고, 이후 회수로 단계가 내려가도 `graduatedAt`은 지우지 않는다 (동물은 퇴화하지 않는다는 원칙의 범위는 D2 결정과 함께 확정). `stageChanged`는 갱신 전후 단계가 다르면 true다.

## Alternatives Considered

### Alternative A: `pets.total_exp`에 증감만 더하기

*   **Pros**: 테이블 하나, 쿼리 하나로 끝난다
*   **Cons**: 중복 지급을 DB가 막을 수 없고, 해제 시 무엇을 빼야 할지 알 수 없으며, 숫자가 어긋났을 때 원인을 추적할 수 없다
*   **Reason for Rejection**: 브리프 9장과 AGENTS.md 고정 결정 3. 이 문서도 캐시를 합계로 덮어쓰고 증감을 더하지 않는다

### Alternative B: 클라이언트에서 경험치 계산

*   **Pros**: 서버 왕복 없이 즉시 연출할 수 있다
*   **Cons**: 조작이 쉽고 규칙이 두 곳에 생겨 어긋난다
*   **Reason for Rejection**: 브리프 9장, AGENTS.md 고정 결정 1

### Alternative C: 유니크 제약 위반 예외를 잡아 "이미 지급됨" 처리

*   **Pros**: JPA `save()`만으로 구현할 수 있다
*   **Cons**: PostgreSQL은 문장 하나가 실패하면 트랜잭션 전체를 실패 상태로 만든다. 할 일 체크와 같은 트랜잭션이므로 체크까지 롤백된다. 세이브포인트로 감싸면 코드가 늘어난다
*   **Reason for Rejection**: `INSERT ... ON CONFLICT DO NOTHING` 한 문장으로 같은 결과를 얻는다

### Alternative D: 낙관적 잠금(`@Version`)으로 상한 지키기

*   **Pros**: 잠금 대기가 없다
*   **Cons**: 충돌 시 재시도 로직이 필요하다. 같은 펫에 대한 요청은 한 사용자에게서만 오므로 잠금 대기가 짧다
*   **Reason for Rejection**: 브리프 6.4가 비관적 잠금(`PESSIMISTIC_WRITE`)으로 정했고, 재시도 코드가 필요 없다

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **정확성**: 위 Goals의 불변식(합계 = 캐시, 단계 = `PetStage.of(캐시)`, 하루 합계 ≤ 100)을 통합 테스트로 고정한다
*   **소유권**: `ExpService`는 `petId`를 받는다. 그 펫이 로그인 사용자의 것인지는 호출자가 확인한다 (AGENTS.md 6.1). `ExpService`는 사용자를 모른다
*   **롤백**: 스키마는 Flyway V1 하나다. 되돌릴 데이터가 없는 첫 마이그레이션이라 롤백 절차는 두지 않는다

--------------------------------------------------------------------------------

### Additional Resources

*   `concepts_brief.md` 2.2, 2.3, 4장, 6장, 9장
*   `AGENTS.md` 4장(고정 결정), 6.1(백엔드 규칙), 7장(테스트 규칙)

### Future Improvements

*   **로그 정리**: 졸업한 펫의 `exp_logs`를 요약 행으로 압축할 수 있다. 3개월에 펫당 1,000줄 안팎이라 MVP에서는 하지 않는다

--------------------------------------------------------------------------------

## Detailed Implementation Plan

D1~D5는 추천안 기준으로 적었다. D3에서 B를 고르면 1번 파일에서 `users`를 빼고 `pets.user_id`의 FK를 지운다. D2에서 B를 고르면 1번 파일의 `exp_logs`와 6번 파일의 상한 쿼리가 바뀐다.

### Target Files to Create/Modify

#### 1. `backend/src/main/resources/db/migration/V1__create_users_pets_exp_logs.sql` (Create)

*   **Type / Scope**: Flyway 마이그레이션
*   **Proposed Changes**: `concepts_brief.md` 4장의 `users`, `pets`, `uq_active_pet`, `exp_logs`, `ix_exp_logs_pet_date`를 그대로 만든다. `daily_plans`, `tasks`는 만들지 않는다. `pets.species`와 `pets.stage`는 `VARCHAR(20)`, `exp_logs.reason`은 `VARCHAR(30)`으로 enum 이름을 저장한다.
*   **Why**: `ddl-auto: validate`이므로 엔티티보다 스키마가 먼저 있어야 한다.

#### 2. `backend/src/main/resources/db/migration/.gitkeep` (Delete)

*   **Why**: V1이 생기면 빈 폴더 표시가 필요 없다.

#### 3. `backend/src/main/java/com/petplanner/common/ClockConfig.java` (Create)

*   **Type / Scope**: Spring 설정
*   **Proposed Changes**: `@Bean Clock clock()` → `Clock.systemUTC()`.
*   **Why**: 테스트에서 고정 `Clock`으로 바꿔 끼우기 위해 시간을 빈으로 주입한다 (AGENTS.md 7장).

#### 4. `backend/src/main/java/com/petplanner/exp/DayClock.java` (Create)

*   **Type / Scope**: `@Component`
*   **Proposed Changes**: 생성자로 `Clock`을 받는다. `ZoneId SEOUL = Asia/Seoul`, 경계 4시간, 마감 12:00 상수.
    *   `LocalDate today()`
    *   `Instant planDeadline(LocalDate planDate)`
    *   `boolean isBeforePlanDeadline(LocalDate planDate, Instant at)`
    *   `Instant now()` → `clock.instant()` (엔티티 시각 기록용)
*   **Why**: 날짜 계산의 유일한 입구 (AGENTS.md 고정 결정 2).

#### 5. `backend/src/main/java/com/petplanner/pet/PetStage.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**: `EGG(0), BABY(100), JUNIOR(600), ADULT(1800), GRADUATED(4000)`. `static PetStage of(int totalExp)` (음수는 EGG), `Integer nextStageExp()` (GRADUATED는 null).
*   **Why**: 단계 계산의 유일한 함수 (고정 결정 6).

#### 6. `backend/src/main/java/com/petplanner/pet/Species.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**: `DOG, CAT, PENGUIN, HAMSTER`.
*   **Why**: `pets.species` 매핑.

#### 7. `backend/src/main/java/com/petplanner/pet/Pet.java` (Create)

*   **Type / Scope**: JPA 엔티티 (`pets`)
*   **Proposed Changes**: 필드 `id, userId, species(@Enumerated STRING), name, stage(@Enumerated STRING), totalExp, active(is_active), graduatedAt(Instant), createdAt(Instant, insertable=false, updatable=false)`. setter 없음.
    *   `boolean applyTotalExp(int total, Instant now)`: `totalExp`, `stage` 갱신, 처음 GRADUATED가 되면 `graduatedAt = now`. 단계가 바뀌었으면 true 반환
    *   생성 팩토리는 이 문서에서 만들지 않는다 (D5에서 알 고르기 API와 함께). 테스트는 SQL로 펫을 넣는다
*   **Why**: 엔티티는 의미 있는 메서드로만 상태를 바꾼다 (AGENTS.md 6.1).

#### 8. `backend/src/main/java/com/petplanner/pet/PetRepository.java` (Create)

*   **Type / Scope**: Spring Data JPA
*   **Proposed Changes**: `@Lock(PESSIMISTIC_WRITE) @Query("select p from Pet p where p.id = :id") Optional<Pet> findByIdForUpdate(Long id)`.
*   **Why**: 지급 흐름 1단계의 펫 행 잠금.

#### 9. `backend/src/main/java/com/petplanner/exp/ExpReason.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**: `PLAN, TASK, MAIN_GOAL, REFLECTION, BONUS_RATE, STREAK`.

#### 10. `backend/src/main/java/com/petplanner/exp/ExpLog.java` (Create)

*   **Type / Scope**: JPA 엔티티 (`exp_logs`), 읽기 전용
*   **Proposed Changes**: 필드 `id, petId, planDate(LocalDate), amount, reason(@Enumerated STRING), refId, createdAt`. 쓰기는 9번 리포지토리의 네이티브 쿼리로만 한다. 생성자는 JPA용 protected 하나만 둔다.
*   **Why**: 리포지토리 타입과 `ddl-auto: validate` 검증에 필요하다.

#### 11. `backend/src/main/java/com/petplanner/exp/ExpLogRepository.java` (Create)

*   **Type / Scope**: Spring Data JPA, 네이티브 쿼리
*   **Proposed Changes**:
    *   `int insertIgnoringDuplicate(petId, planDate, amount, reason, refId)`: `INSERT ... ON CONFLICT (pet_id, reason, ref_id) DO NOTHING`, 반환값은 들어간 행 수 (`@Modifying`)
    *   `int deleteGrant(petId, reason, refId)` (`@Modifying`)
    *   `int sumForDayExcludingStreak(petId, planDate)`: `COALESCE(SUM(amount), 0)`, `reason <> 'STREAK'`
    *   `int sumTotal(petId)`: `COALESCE(SUM(amount), 0)`
    *   `List<ReasonTotal> sumByReasonForDay(petId, planDate)`: 정산 응답용, `reason`별 합계 (인터페이스 프로젝션)
*   **Why**: 지급 흐름 4~7단계.

#### 12. `backend/src/main/java/com/petplanner/exp/ExpService.java` (Create)

*   **Type / Scope**: `@Service`, 모든 공개 메서드 `@Transactional`
*   **Proposed Changes**: 금액 상수 `PLAN=10, TASK=5, TASK_LATE=2, MAIN_GOAL=30, REFLECTION=10, STREAK=50, DAILY_CAP=100, BONUS_RATE_PERCENT=20, BONUS_MIN_COMPLETION=80, MIN_TASKS_FOR_PLAN=3, STREAK_INTERVAL=7`.
    *   `ExpResult grantPlan(long petId, LocalDate planDate, long planId, int taskCount, Instant confirmedAt)`: 조건 미충족이면 지급 0
    *   `ExpResult grantTask(long petId, LocalDate planDate, long taskId, boolean lateAdded)`
    *   `ExpResult revokeTask(long petId, long taskId)`: 회수액을 음수 `gainedExp`로 돌려준다
    *   `Settlement settle(long petId, LocalDate planDate, long planId, boolean mainGoalDone, boolean hasReflection, int completionRate, int streakDays)`
    *   `static int capped(int requested, int todayTotal)`: `max(0, min(requested, DAILY_CAP - todayTotal))` (패키지 공개, 단위 테스트 대상)
    *   공통 private 흐름: 잠금 → 상한 → insert → 재계산 → `applyTotalExp`
    *   펫이 없으면 `IllegalStateException` (호출자가 소유권 확인 후 부르므로 정상 흐름에서 생기지 않음)
*   **Why**: 경험치 규칙의 유일한 위치 (브리프 6장).

#### 13. `backend/src/main/java/com/petplanner/exp/ExpResult.java`, `Settlement.java`, `PetSnapshot.java` (Create)

*   **Type / Scope**: `record` DTO
*   **Proposed Changes**:
    *   `PetSnapshot(PetStage stage, int totalExp, Integer nextStageExp, boolean stageChanged)`
    *   `ExpResult(int gainedExp, PetSnapshot pet)`
    *   `Settlement(LocalDate date, int completionRate, List<Item> items, int totalGained, PetSnapshot pet)`, `record Item(ExpReason reason, int amount)`. `items`는 그날 로그의 사유별 합계(0인 사유 제외), `totalGained`는 그 합
*   **Why**: 브리프 5장 정산 응답 예시와 같은 모양. 엔티티를 밖으로 내보내지 않는다 (AGENTS.md 6.1). `ReasonTotal` 프로젝션은 11번 파일 안의 인터페이스로 둔다.

#### 14. `backend/src/test/java/com/petplanner/TestcontainersConfiguration.java` (Create)

*   **Type / Scope**: `@TestConfiguration(proxyBeanMethods = false)`
*   **Proposed Changes**: `@Bean @ServiceConnection PostgreSQLContainer<?> postgres()` → `postgres:16-alpine`. 모든 통합 테스트가 `@Import`로 같은 컨테이너를 쓴다.

#### 15. `backend/src/test/java/com/petplanner/PetPlannerApplicationTests.java` (Modify)

*   **Proposed Changes**: 클래스 안의 컨테이너 필드와 `@Testcontainers`를 지우고 `@Import(TestcontainersConfiguration.class)`로 바꾼다.
*   **Why**: 컨테이너 설정을 한 곳에 둔다.

#### 16. `backend/src/test/java/com/petplanner/pet/PetStageTest.java` (Create)

*   **Type / Scope**: 단위 테스트
*   **Test cases**: 0→EGG, 99→EGG, 100→BABY, 599→BABY, 600→JUNIOR, 1799→JUNIOR, 1800→ADULT, 3999→ADULT, 4000→GRADUATED, 10000→GRADUATED. `nextStageExp`: EGG 100 … GRADUATED null.

#### 17. `backend/src/test/java/com/petplanner/exp/DayClockTest.java` (Create)

*   **Type / Scope**: 단위 테스트, `Clock.fixed`
*   **Test cases**: 서울 03:59:59 → 전날, 04:00:00 → 당일, 23:59 → 당일. 마감: 11:59:59 → 마감 전, 12:00:00 → 마감 후.

#### 18. `backend/src/test/java/com/petplanner/exp/ExpServiceCapTest.java` (Create)

*   **Type / Scope**: 단위 테스트 (`ExpService.capped`)
*   **Test cases**: (5, 0)→5, (5, 98)→2, (5, 100)→0, (5, 120)→0, (30, 80)→20.

#### 19. `backend/src/test/java/com/petplanner/exp/ExpServiceIntegrationTest.java` (Create)

*   **Type / Scope**: 통합 테스트 (`@SpringBootTest`, `@Import(TestcontainersConfiguration)`), 고정 `Clock` 빈을 `@TestConfiguration`으로 덮어쓴다. 각 테스트 전에 `users`, `pets`를 SQL로 넣고 끝나면 지운다
*   **Test cases**:
    *   할 일 체크 +5, 마감 후 추가 할 일 +2
    *   같은 할 일 두 번 지급 → 두 번째 0, 로그 1줄
    *   오늘 합계 98에서 체크 → 2, 100에서 → 0이고 로그 없음
    *   해제 → 로그 삭제, `total_exp` 감소, 지급 안 된 할 일 해제 → 0
    *   PLAN: 할 일 2개 → 0, 3개 + 정오 전 → 10, 정오 이후 확정 → 0
    *   정산: 브리프 5장 예시 재현 (PLAN 10, TASK 25 → MAIN_GOAL 30, REFLECTION 10, BONUS_RATE 15, 합 90)
    *   정산: 상한 근처에서 BONUS_RATE 잘림, STREAK는 상한 초과 지급
    *   단계: 99 → +5 → BABY, `stageChanged` true. 3999 → 졸업, `graduated_at` 기록
    *   동시성: 같은 펫, 서로 다른 할 일 20개를 스레드 20개로 동시에 지급 → 오늘 합계 정확히 100, `total_exp` = 로그 합계
    *   동시성: 같은 할 일을 두 스레드가 동시에 지급 → 로그 1줄
    *   불변식: 모든 테스트 끝에 `total_exp == SUM(exp_logs.amount)`, `stage == PetStage.of(total_exp)`

#### 20. `docs/designs/SITEMAP.md` (Modify)

*   **Proposed Changes**: 이 문서를 한 줄 등록한다.

### Verification Plan

*   **Compilation/Build**: `cd backend && ./gradlew build`
*   **Unit Tests**: `PetStageTest`, `DayClockTest`, `ExpServiceCapTest` (AGENTS.md 7장 필수 대상: 단계 경계, 하루 상한, 03:59/04:00, 정오 마감)
*   **E2E/Integration**: `ExpServiceIntegrationTest` (Docker 필요). 할 일 체크/해제와 하루 마감의 엔드포인트 통합 테스트는 `daily-plan-and-tasks.md`에서 이 서비스를 감싸 다시 작성한다
*   **Static Analysis & Linting**: 별도 도구 없음 (컴파일 경고 없음 확인)

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
