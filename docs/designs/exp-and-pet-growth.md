# 경험치 지급과 펫 성장 (exp-and-pet-growth)

*   **Author:** ParkJongHwan
*   **Status:** Approved (2026-11-02, D1~D6 소유자 승인)
*   **Date:** 2026-11-02

--------------------------------------------------------------------------------

## Overview

펫 플래너의 보상은 모두 경험치(EXP)이고, 펫의 성장 단계는 누적 경험치로 정해진다. 이 문서는 다음을 설계한다.

*   경험치를 지급·회수·정산하는 서버 로직(`ExpService`)
*   하루의 경계를 계산하는 `DayClock`
*   단계를 계산하는 `PetStage`
*   이를 저장하는 `pets`·`exp_logs` 테이블

이 문서가 만드는 것은 HTTP 엔드포인트가 아니라 **다른 기능이 호출하는 서비스 계층**이다.

*   할 일 체크와 하루 마감은 다음 문서 `daily-plan-and-tasks.md`의 `plan` 패키지 코드(이하 **호출자**)에서 이 서비스를 호출한다.
*   이 문서를 기능 순서상 가장 먼저 쓰는 이유는 나머지 기능이 모두 이 결과(`gainedExp`, `pet`, `settlement`)를 쓰기 때문이다.

이하 `concepts_brief.md`는 **브리프**로 줄여 쓰고, 절 번호는 "브리프 N.N"으로 적는다.

## The Problem

경험치 규칙이 틀리면 사용자가 보는 숫자가 틀린다. 틀리기 쉬운 지점은 다음과 같다.

*   **중복 지급**: 같은 요청이 두 번 오면(더블 탭, 네트워크 재시도) 같은 할 일로 경험치를 두 번 줄 수 있다.
*   **하루 상한 초과**: 두 요청이 동시에 "그날 합계 95"를 읽으면 둘 다 +5를 넣어 105가 된다.
*   **되돌리기**: 체크를 해제하면 그 할 일로 받은 경험치만 정확히 빼야 한다. 총합에만 더해 두면 무엇을 빼야 할지 알 수 없다.
*   **날짜 경계**: 새벽 2시에 체크한 할 일은 "어제"의 것이다. 서버 기본 시간대나 `LocalDate.now()`를 쓰면 배포 환경에 따라 결과가 달라진다.
*   **단계 불일치**: 단계를 따로 더하거나 빼면 누적 경험치와 단계가 어긋날 수 있다.

해결 방향은 브리프에서 이미 정했다.

*   경험치를 이벤트(`exp_logs`)로 쌓는다
*   DB 유니크 제약으로 중복을 막는다
*   펫 행 잠금으로 상한을 지킨다
*   날짜는 `DayClock` 하나로 계산한다
*   단계는 `PetStage.of(totalExp)` 순수 함수 하나로 계산한다

## Goals

*   할 일 완료, 계획 확정, 하루 마감 때 브리프 2.2의 경험치 표대로 지급한다
*   같은 지급 사유(`reason`)와 대상(`ref_id`)에는 펫당 한 번만 지급한다. 같은 요청이 두 번 와도 결과가 같다
*   하루 지급 합계(STREAK 제외)가 100을 넘지 않는다. 동시 요청에서도 지킨다
*   체크 해제 시 그 할 일의 TASK 지급만 정확히 회수한다
*   불변식 두 가지를 지킨다
    *   `pets.total_exp`는 언제나 그 펫의 `exp_logs.amount` 합계와 같다
    *   `pets.stage`는 `graduated_at`이 있으면 GRADUATED이고, 없으면 `PetStage.of(total_exp)`와 같다 (D6)
*   하루 경계(서울 04:00)와 계획 마감(서울 12:00) 판단을 `Clock`을 고정한 테스트로 검증한다

## Non-Goals

*   HTTP 엔드포인트 (할 일 체크, 하루 마감, 홈, 알 고르기, 도감). 이 문서는 서비스 계층만 만든다
*   `daily_plans`, `tasks` 테이블과 그 로직 (완료율 계산, 연속 기록 일수 계산, 04:05 자동 마감 배치)
*   로그인, 푸시, 광고, 프론트 화면
*   펫 기분(HAPPY/NORMAL/SAD) 계산 (D4 참고)
*   꾸미기 아이템 (`pet_items`, MVP 이후)

## Open Questions

답이 여러 개라 이 문서의 소유자(작성자 ParkJongHwan)가 골라야 하는 결정이다.

*   각 항목의 추천은 브리프에 이미 정한 내용을 근거로 했다.
*   각 항목 끝의 "영향"은 추천을 따르지 않을 때 바뀌는 곳이다.

### D1. 할 일 체크 요청을 "뒤집기"로 둘지 "목표 상태 지정"으로 바꿀지

브리프 6.4는 "같은 할 일을 빠르게 두 번 누르는 경우는 UNIQUE 제약이 막는다"고 하지만, 브리프 5장의 API는 `POST /tasks/{id}/toggle`(뒤집기)다.

*   뒤집기에서는 두 번째 요청이 첫 번째를 **되돌린다**(체크 → 해제).
*   유니크 제약은 "같은 지급이 두 번 들어가는 것"만 막고, 의도치 않은 해제는 막지 못한다.

`ExpService`는 두 방식 모두에서 동작한다. 다만 브리프 6.4의 의도가 실제로 성립하는지는 API 모양에 달려 있다.

*   **A. 뒤집기 유지** (`POST /tasks/{id}/toggle`)
    *   프론트 코드가 줄어든다.
    *   더블 탭과 재시도가 상태를 되돌리므로 프론트에서 버튼을 잠시 막아야 한다.
*   **B. 목표 상태 지정** (`PUT /tasks/{id}/done`, body `{"done": true|false}`)
    *   같은 요청을 몇 번 보내도 결과가 같다. 브리프 6.4의 "두 번 눌러도 한 번만"이 서버에서 성립한다.
    *   늦게 도착한 재시도(`done: true`)가 그 사이 사용자가 한 해제를 덮어쓸 수 있다. 이 경우 마지막 요청이 이긴다.
*   **추천: B.**
    *   브리프 6.4가 원한 동작을 서버만으로 보장한다.
    *   `ExpService.grantTask`/`revokeTask`가 이미 멱등이라 추가 코드가 없다.
*   **영향**: 이 문서의 코드는 바뀌지 않는다. 브리프 5장 API 표 한 줄과 `daily-plan-and-tasks.md`의 엔드포인트가 바뀐다.

### D2. 졸업(4,000 EXP) 이후 처리와 새 알을 고르는 시점

브리프 2.3은 "4,000 EXP에 도달하면 도감에 등록되고 새 알을 고를 수 있다"고만 정했다. 그런데 하루 상한과 중복 방지는 **펫 기준**(`exp_logs.pet_id`)이다. 같은 날 새 알로 바꾸면 다음 두 경로로 지급이 샌다.

*   **하루 100이 사용자 기준으로 깨진다**: 새 펫의 그날 합계는 0부터 시작한다.
*   **TASK가 펫을 넘나든다**:
    1. 펫 1로 할 일 T를 체크해 +5를 받는다.
    2. 같은 날 펫 2로 바꾼 뒤 T를 해제한다. 펫 2에는 지울 행이 없으므로 펫 1의 +5가 그대로 남는다.
    3. T를 다시 체크하면 펫 2가 +5를 또 받는다.

선택지는 세 가지다.

*   **A. 그날은 졸업한 펫이 끝까지 받고, 새 알은 다음 날부터 고른다**
    *   도달 즉시 `graduated_at`을 기록하고 단계는 GRADUATED로 둔다(D6).
    *   그날 남은 지급도 졸업한 펫에 쌓인다(4,000 초과 허용).
    *   알 고르기(`POST /pets`)는 졸업 펫의 `graduated_at` 날짜(`DayClock` 기준)가 오늘보다 이전일 때만 허용한다. 그때 졸업 펫의 `is_active`를 false로 바꾼다.
    *   스키마 변경이 없다.
*   **B. 즉시 비활성화하고 바로 새 알을 고른다**
    *   사용자가 기다리지 않는다.
    *   중복 지급을 막으려면 상한·유니크 기준을 사용자 단위로 바꿔야 한다(`exp_logs`에 `user_id` 추가, 유니크 키 변경). 브리프 4장 스키마가 바뀐다.
*   **C. 졸업 후에도 계속 키우고, 새 알은 사용자가 원할 때 고른다**
    *   졸업 펫과 헤어질 시점을 사용자가 정한다.
    *   B와 같은 누수가 "새 알을 고른 날"에 생기므로 A의 날짜 조건이 결국 필요하다.
*   **추천: A.** 브리프 4장 스키마와 "하루 상한 100"을 그대로 지키면서, 하루에 두 펫이 지급받는 경우를 날짜 조건 하나로 없앤다. 사용자는 최대 하루를 기다린다.
*   **영향**:
    *   A: 브리프 5장 `POST /pets` 조건이 "활성 펫 없음"에서 "활성 펫 없음, 또는 활성 펫이 전날 이전에 졸업"으로 바뀐다(`ACTIVE_PET_EXISTS`의 뜻도 같이 바뀜). 새 알을 고르기 전까지는 졸업 펫이 계속 지급받는다(하루 100 유지). 알 고르기도 아래 "잠금 순서" 규칙대로 기존 펫 행을 먼저 잠근다.
    *   B: V1 마이그레이션의 `exp_logs`, `ExpLogRepository`의 상한 쿼리, `ExpService`의 상한 계산이 바뀐다.

### D3. 첫 마이그레이션에 `users` 테이블을 넣을지

`pets.user_id`는 `users(id)`를 참조하지만 `users`는 로그인 문서(`auth-toss-login.md`)의 범위다.

*   **A. V1에 `users`를 브리프 4장 스키마 그대로 만든다**
    *   FK가 처음부터 걸리고, 이후 문서에서 테이블을 다시 만들지 않는다.
    *   로그인 로직은 만들지 않는다.
*   **B. V1은 `pets`, `exp_logs`만 만들고 FK 없이 `user_id BIGINT`만 둔다**
    *   로그인 문서에서 FK를 추가하는 마이그레이션이 하나 더 필요하다.
    *   통합 테스트 데이터에서 `users` 행을 만들지 않아도 된다.
*   **추천: A.**
    *   `users` 스키마는 브리프에서 이미 확정됐다(`push_agreed_at` 포함).
    *   `ON DELETE CASCADE`로 탈퇴 시 삭제가 처음부터 보장된다.
*   **영향**: B를 고르면 V1 마이그레이션에서 `users`를 빼고 `pets.user_id`의 FK를 지운다. 통합 테스트의 `users` 데이터 넣기도 빠진다.

### D4. 펫 기분 계산을 어느 문서에서 할지

기분은 "최근 3일 평균 완료율"로 정한다. 완료율은 `daily_plans.completion_rate`에 있고, 이 테이블은 다음 문서의 범위다.

*   **A. 이 문서에서 기분 계산을 정의한다**
    *   브리프 2.3 범위를 이 문서에서 다 닫는다.
    *   아직 없는 테이블을 전제로 설계해야 하고, 테스트할 데이터가 없다.
*   **B. `daily-plan-and-tasks.md`로 넘긴다**
    *   테이블과 계산이 같은 문서에 있다.
    *   그 문서에서 "계획이 없던 날을 0%로 셀지"를 함께 정한다.
*   **추천: B.** 계산에 필요한 데이터가 생기는 문서에서 정해야 테스트로 검증할 수 있다.
*   **영향**: A를 고르면 `pet` 패키지에 기분 계산 파일과 테스트가 추가되고, `daily_plans` 스키마를 이 문서에서 먼저 정해야 한다.

### D5. 알 고르기·도감 API를 어느 문서가 맡을지

`POST /pets`와 `GET /pets/collection`은 브리프 5장에 있지만, 브리프 11.3 표의 네 문서 어디에도 배정되지 않았다.

*   **A. 이 문서에 추가한다**: 펫 관련 내용이 한 문서에 모인다. 이번 범위(브리프 5장 제외)가 넓어진다.
*   **B. `daily-plan-and-tasks.md`에 넣는다**: 첫 API 문서에서 `GET /home`과 함께 다룬다. 온보딩에서 알을 고른 뒤 홈으로 가는 흐름이 한 문서에 있다.
*   **C. 별도 문서 `pet-selection-and-collection.md`를 만든다**: 문서마다 범위가 좁아진다. 대신 문서가 하나 늘어난다.
*   **추천: B.** 이번 범위를 지키면서, 홈 화면이 처음 동작하는 데 필요한 API를 한 문서에서 만든다. D2의 "새 알 고르기 날짜 조건"도 그 문서에서 구현한다.
*   **영향**: A를 고르면 `Pet` 생성 팩토리, 펫 컨트롤러와 도감 조회가 이 문서에 추가된다.

### D6. 체크 해제로 단계가 내려가도 되는지 (결정됨: A)

AGENTS.md 고정 결정 7은 "동물은 죽거나 퇴화하지 않는다"이다. 그런데 "단계 = `PetStage.of(total_exp)`"이면 다음과 같이 단계가 내려간다.

*   예: 100 EXP로 BABY가 된 뒤 할 일 체크를 하나 풀면 95가 되고 EGG로 돌아간다.

선택지는 두 가지였다.

*   **A. "퇴화"는 처벌 장치만 뜻한다고 해석한다**
    *   근거: 브리프 1.3의 비목표가 "동물 사망, 퇴화 같은 처벌 장치"다.
    *   실수로 체크를 해제해 단계가 내려가는 것은 처벌이 아니므로 허용한다.
    *   단, 한 번 졸업한 펫(`graduated_at` 있음)은 GRADUATED를 유지한다.
    *   단계는 계속 `PetStage.of` 순수 함수로 계산한다(고정 결정 6).
*   **B. 단계는 도달한 최고 단계로 둔다** (`max(현재, of(total))`)
    *   고정 결정 7의 문구를 그대로 지킨다.
    *   단계가 누적 경험치와 별개인 상태가 되어 고정 결정 6과 맞지 않는다.

**결정: A** (2026-11-02, 소유자 승인).

*   고정 결정 7은 "처벌로 죽거나 퇴화하지 않는다"로 읽는다.
*   졸업 판정의 기준은 `graduated_at` 하나다.

## Critical User Journeys (CUJs)

### CUJ 1: 할 일 체크로 경험치를 받는다

*   **Given**: 오늘 계획이 하루 마감 전이고, 펫의 그날 합계가 40 EXP다. 할 일 T는 계획 마감(12:00) 전에 추가됐다
*   **When**: 사용자가 T를 완료로 체크하고, 호출자가 `ExpService.grantTask`를 부른다
*   **Then**:
    *   `exp_logs`에 `reason = TASK`, `ref_id = T.id`, `amount = 5`인 행이 하나 생긴다.
    *   응답에는 `gainedExp: 5`와 `pet`이 담긴다. `pet`은 `PetSnapshot`(`totalExp`, `stage`, `nextStageExp`, `stageChanged`)이다.

### CUJ 2: 같은 요청이 두 번 와도 한 번만 지급된다

*   **Given**: CUJ 1 직후다
*   **When**: 네트워크 재시도로 같은 지급 요청이 한 번 더 온다
*   **Then**: 새 행이 생기지 않고 `gainedExp: 0`이다. 에러로 처리하지 않는다

### CUJ 3: 하루 상한에서 잘린다

*   **Given**: 펫의 그날 합계가 98 EXP다
*   **When**: 할 일 하나를 체크한다
*   **Then**: `exp_logs`에 2 EXP만 쌓이고 `gainedExp: 2`다

### CUJ 4: 하루 상한에 닿으면 지급하지 않는다

*   **Given**: 펫의 그날 합계가 100 EXP다
*   **When**: 할 일 하나를 체크한다
*   **Then**: 행을 만들지 않고 `gainedExp: 0`이다

### CUJ 5: 체크를 해제하면 회수된다

*   **Given**: 할 일 T로 5 EXP를 받았다
*   **When**: 사용자가 T를 해제하고 호출자가 `ExpService.revokeTask`를 부른다
*   **Then**:
    *   `reason = TASK`, `ref_id = T.id`인 행이 지워진다.
    *   응답은 `gainedExp: -5`이고 `totalExp`가 5 줄어든다.
    *   단계는 다시 계산되어 내려갈 수 있다. 졸업한 펫은 GRADUATED를 유지한다 (D6).

### CUJ 6: 하루 마감 정산

*   **Given**: 그날 PLAN 10, TASK 25를 받았다. 핵심 목표 할 일이 완료 상태다. 완료율 83%, 회고가 있다. 오늘로 연속 기록이 7일째다
*   **When**: 호출자가 `ExpService.settle`을 부른다
*   **Then**:
    *   MAIN_GOAL 30, REFLECTION 10, BONUS_RATE 15(= floor((10+25+30+10) × 0.2)), STREAK 50이 지급된다.
    *   정산 결과에는 사유별 합계와 펫 상태가 담긴다.
    *   STREAK는 상한과 무관하게 지급된다.

### CUJ 7: 새벽 04:00 전은 전날이다

*   **Given**: 서울 시각 03:59:59다
*   **When**: `DayClock.today()`를 부른다
*   **Then**: 전날 날짜가 나온다

### CUJ 8: 04:00부터는 당일이다

*   **Given**: 서울 시각 04:00:00이다
*   **When**: `DayClock.today()`를 부른다
*   **Then**: 당일 날짜가 나온다

## Technical Plan (Architecture)

### 스키마

브리프 4장 스키마를 그대로 쓴다. V1 마이그레이션은 `users`(D3), `pets`, `exp_logs`만 만든다.

### 구성 요소

| 구성 요소 | 패키지 | 역할 |
| --- | --- | --- |
| `DayClock` | `exp` | 주입된 `Clock`으로 "오늘"(서울 04:00 경계)과 계획 마감(서울 12:00)을 계산한다. 날짜 계산은 이 클래스만 한다 |
| `PetStage` | `pet` | 단계 enum. `of(totalExp)` 순수 함수와 다음 단계 기준값 |
| `Pet` | `pet` | `pets` 엔티티. `applyTotalExp`로 누적 경험치, 단계, 졸업 시각을 함께 갱신한다 |
| `ExpLog`, `ExpReason` | `exp` | `exp_logs` 엔티티와 지급 사유 enum |
| `ExpService` | `exp` | 지급·회수·정산. 경험치 규칙(금액, 조건, 상한)은 모두 여기에만 있다 |

### 잠금 순서 (모든 경로 공통)

**펫 행을 맨 먼저 잠근다.** 브리프 6.2와 같은 순서이며, 이 펫에 대한 하루의 변경이 모두 이 잠금 뒤에 한 줄로 선다.

*   호출자는 트랜잭션의 첫 단계에서 `PetRepository.findByIdForUpdate(petId)`로 펫을 잠근다.
    *   소유권(`pet.userId == 로그인 사용자`)도 이 결과로 확인한다.
    *   그다음에 계획·할 일 행을 읽고 수정한 뒤 `ExpService`를 부른다.
    *   대상 경로: 할 일 체크, 하루 마감, 04:05 자동 마감 배치, 알 고르기.
*   호출자는 그 전에 `Pet`을 잠금 없이 읽지 않는다.
    *   Hibernate는 이미 영속성 컨텍스트에 있는 엔티티를 잠금 조회로 새로 고치지 않는다.
    *   먼저 읽어 두면 오래된 `stage`·`graduatedAt`으로 계산하게 된다.
*   `ExpService`도 같은 메서드로 펫을 잠근다.
    *   같은 트랜잭션에서는 대기 없이 같은 인스턴스를 받는다.
    *   테스트처럼 `ExpService`를 직접 부르면 여기서 처음 잠근다.
*   모든 경로가 같은 행을 같은 순서로 잠그므로 교착이 생기지 않는다.
    *   체크 요청이 하루 마감 직후에 와도, 펫 잠금을 얻은 뒤 계획 상태를 읽으므로 이미 마감된 날을 본다.
*   잠금 대기 시간 제한은 두지 않는다. 한 펫에 대한 요청은 한 사용자에게서만 오기 때문이다.

### 지급 흐름 (`grantPlan`, `grantTask`, `settle` 공통)

```text
호출자(plan 패키지, 트랜잭션 안. 펫은 이미 잠금)
  └─ ExpService.grantPlan / grantTask / settle   @Transactional (호출자 트랜잭션에 합류)
       1. pets 행 잠금: findByIdForUpdate           ← 이미 잠갔으면 같은 인스턴스
       2. 지급 조건 확인 (예: PLAN은 할 일 3개 이상, 계획 마감 전 확정)
       3. 요청액 결정 (TASK: lateAdded면 2, 아니면 5)
       4. 그날 합계 = SUM(amount) WHERE pet_id, plan_date = 호출자가 넘긴 planDate, reason <> 'STREAK'
       5. 지급액 = max(0, min(요청액, 100 - 그날 합계))   (STREAK는 요청액 그대로)
       6. 지급액 > 0 이면
            INSERT ... ON CONFLICT (pet_id, reason, ref_id) DO NOTHING
            → 들어간 행이 0이면 "이미 지급됨" → 지급액 = 0
       7. total = SUM(amount) WHERE pet_id      ← 캐시 재계산 (직접 더하지 않음)
       8. pet.applyTotalExp(total, dayClock.now())   ← 단계·졸업 갱신
       9. ExpResult(gainedExp, PetSnapshot) 반환
```

*   **중복 지급**: `ON CONFLICT DO NOTHING`을 쓴다.
    *   제약 위반 예외를 잡는 방식은 쓸 수 없다. PostgreSQL에서는 트랜잭션 전체가 실패 상태가 되어 호출자의 할 일 체크까지 롤백된다.
    *   결과는 브리프 6.4와 같다("이미 지급됨", 에러 아님).
*   **동시성**: 4~6단계는 펫 행 잠금 아래에서만 실행된다. 같은 펫에 대한 두 지급은 순서대로 처리되므로 상한 계산이 겹치지 않는다.
*   **캐시 재계산**: `pets.total_exp`에 증감을 더하지 않고 매번 합계로 덮어쓴다(AGENTS.md 4장 3항).
    *   펫당 로그는 졸업까지 약 1,000행(3개월)이다.
    *   `ix_exp_logs_pet_date`(앞 열 `pet_id`)로 충분하다.
*   **날짜**: 4단계의 날짜는 호출자가 넘긴 `planDate`다. 04:05 자동 마감 배치에서는 "어제"가 넘어온다.
*   **늦게 추가된 할 일**: TASK 2 EXP 판정에는 호출자가 넘긴 `lateAdded`(브리프 4장 `tasks.is_late_added`)를 쓴다.

### 회수 흐름 (체크 해제)

1. 펫 잠금 (지급 흐름 1단계)
2. `before = SUM(amount) WHERE pet_id`
3. `DELETE FROM exp_logs WHERE pet_id = ? AND reason = 'TASK' AND ref_id = taskId`
4. 지급 흐름 7~8단계 (`total` 재계산, `applyTotalExp`)
5. `gainedExp = total - before` (0 또는 음수)

*   지운 행이 없으면 회수액은 0이다. 상한 때문에 지급되지 않았던 할 일이 그렇다.
*   회수 뒤 다른 할 일을 체크하면 비워진 상한만큼 다시 받을 수 있다.
*   회수에는 지급 조건(2~3단계)을 적용하지 않는다.

### 정산 흐름 (하루 마감)

`settle`은 호출자가 계산한 사실(핵심 목표 완료 여부, 회고 여부, 완료율, 연속 기록 일수)을 받는다. 완료율과 연속 기록 일수의 계산은 `daily-plan-and-tasks.md`가 맡는다. 아래 순서로 지급한다.

1. 핵심 목표 할 일 완료 → `MAIN_GOAL` 30 (`ref_id = plan.id`, 상한 적용)
2. 회고 있음 → `REFLECTION` 10 (`ref_id = plan.id`, 상한 적용). 자동 마감은 회고가 없으므로 지급되지 않는다
3. 완료율 ≥ 80 → `BONUS_RATE` = floor(1~2 지급 뒤 planDate 합계(STREAK 제외) × 0.2) (`ref_id = plan.id`, 상한 적용)
4. `streakDays > 0`이고 `streakDays % 7 == 0` → `STREAK` 50 (`ref_id = plan.id`, 상한 미적용)

*   1~4는 한 번의 펫 잠금 아래에서 처리하고, 캐시 재계산은 끝에 한 번 한다.
*   결과 `items`는 그날 로그를 사유별로 합친 것이다.
    *   순서는 `ExpReason` 선언 순서(PLAN, TASK, MAIN_GOAL, REFLECTION, BONUS_RATE, STREAK)이며, 브리프 5장 정산 응답 예시와 같다.
    *   같은 `settle`을 다시 불러도 추가 지급은 0이고 `items`는 같다.

### 계획 확정 지급

`grantPlan`은 할 일 수와 확정 시각을 받아 두 조건을 `ExpService`에서 확인한다.

*   할 일 3개 이상
*   확정 시각이 planDate의 계획 마감(서울 12:00) 이전

조건을 호출자에게 맡기지 않는 이유는 경험치 규칙이 `ExpService` 한 곳에만 있어야 하기 때문이다(브리프 6장).

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

`Pet.applyTotalExp(total, now)`는 다음 순서로 상태를 바꾼다(D6).

1. `totalExp = total`
2. `graduatedAt`이 없고 `PetStage.of(total)`이 GRADUATED이면 `graduatedAt = now`
3. `stage = graduatedAt != null ? GRADUATED : PetStage.of(total)`
4. 갱신 전후 `stage`가 다르면 true를 반환하고, 이 값이 `stageChanged`가 된다

### 한계

*   **PLAN은 확정 시점의 판정만 본다.** 할 일 3개로 확정해 +10을 받은 뒤 할 일을 지워 3개 미만이 돼도 회수하지 않는다(최대 10 EXP). 확정 뒤 삭제를 막을지는 `daily-plan-and-tasks.md`의 Open Question으로 넘긴다.
*   **캐시가 어긋나도 다음 쓰기에서 저절로 맞춰진다.** 모든 쓰기가 합계로 덮어쓰기 때문이다. 지급·회수 내역은 `exp_logs`가 감사 기록이므로 별도 로그나 지표는 두지 않는다.
*   **펫이 없으면 `IllegalStateException`을 던진다.** 호출자가 먼저 펫을 잠그고 소유권을 확인하므로 정상 흐름에서는 생기지 않는다.
*   **04:05 배치를 다시 실행해도 안전하다.** `ON CONFLICT`가 같은 지급을 막고, 당일 체크와의 경합은 잠금 순서 규칙이 막는다.

## Alternatives Considered

### Alternative A: `pets.total_exp`에 증감만 더하기

*   **Pros**: 테이블 하나, 쿼리 하나로 끝난다
*   **Cons**: 중복 지급을 DB가 막을 수 없다. 해제 시 무엇을 빼야 할지 알 수 없고, 숫자가 어긋났을 때 원인을 추적할 수 없다
*   **Reason for Rejection**: 중복 방지와 정확한 회수를 할 수 없다. 브리프 9장과 AGENTS.md 4장 3항도 이벤트 로그 방식으로 정했다

### Alternative B: 클라이언트에서 경험치 계산

*   **Pros**: 서버 왕복 없이 즉시 연출할 수 있다
*   **Cons**: 조작이 쉽고 규칙이 두 곳에 생겨 어긋난다
*   **Reason for Rejection**: 사용자가 값을 조작할 수 있다. 브리프 9장, AGENTS.md 4장 1항도 서버에서만 계산하도록 정했다

### Alternative C: 유니크 제약 위반 예외를 잡아 "이미 지급됨" 처리

*   **Pros**: JPA `save()`만으로 구현할 수 있다
*   **Cons**:
    *   PostgreSQL은 문장 하나가 실패하면 트랜잭션 전체를 실패 상태로 만든다.
    *   할 일 체크와 같은 트랜잭션이므로 체크까지 롤백된다.
    *   세이브포인트로 감싸면 코드가 늘어난다.
*   **Reason for Rejection**: `INSERT ... ON CONFLICT DO NOTHING` 한 문장으로 같은 결과를 얻는다

### Alternative D: 낙관적 잠금(`@Version`)으로 상한 지키기

*   **Pros**: 잠금 대기가 없다
*   **Cons**: 충돌 시 재시도 로직이 필요하다
*   **Reason for Rejection**:
    *   같은 펫에 대한 요청은 한 사용자에게서만 오므로 비관적 잠금의 대기가 짧고, 재시도 코드도 필요 없다.
    *   브리프 6.4도 비관적 잠금(`PESSIMISTIC_WRITE`)으로 정했다.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **정확성**: Goals의 불변식(합계 = 캐시, 단계 규칙, 하루 합계 ≤ 100)을 통합 테스트로 고정한다
*   **소유권**: `ExpService`는 `petId`를 받고 사용자를 모른다. 그 펫이 로그인 사용자의 것인지는 호출자가 펫을 잠근 직후 확인한다(AGENTS.md 6.1, 위 "잠금 순서")
*   **롤백**: 스키마는 Flyway V1 하나다. 되돌릴 데이터가 없는 첫 마이그레이션이라 롤백 절차는 두지 않는다

--------------------------------------------------------------------------------

### Additional Resources

*   브리프 1.3, 2.2, 2.3, 4장, 5장, 6장, 9장
*   `AGENTS.md` 4장(고정 결정), 6.1(백엔드 규칙), 7장(테스트 규칙)

### Future Improvements

*   **로그 정리**: 졸업한 펫의 `exp_logs`를 요약 행으로 압축할 수 있다. 3개월에 펫당 약 1,000행이라 MVP에서는 하지 않는다

--------------------------------------------------------------------------------

## Detailed Implementation Plan

*   D1~D5는 추천안대로, D6은 A로 승인됐다(2026-11-02).
*   추천을 따르지 않을 때 바뀌는 곳은 각 D 항목의 "영향"에 있다.
*   모든 테스트에는 한국어 `@DisplayName`을 붙인다(AGENTS.md 7장).

### Phases

각 단계는 `.\gradlew.bat build`(macOS/Linux는 `./gradlew build`)가 통과한 상태로 끝낸다. `ddl-auto: validate` 때문에 스키마가 엔티티보다 먼저 있어야 한다.

| 단계 | 파일 | 끝나는 조건 |
| --- | --- | --- |
| Phase 1: 스키마와 테스트 기반 | 1, 2, 3, 15, 16 | `contextLoads`가 V1을 적용한 DB에서 통과 |
| Phase 2: 순수 로직 | 4, 5, 6, 7, 10, 17, 18 | 단위 테스트 통과 |
| Phase 3: 엔티티와 서비스 | 8, 9, 11, 12, 13, 14, 15(Clock 추가), 19, 20 | 단위·통합 테스트 통과 |
| Phase 4: 문서 | 21 | 승인 상태 반영 |

### Target Files to Create/Modify

#### 1. `backend/src/main/resources/db/migration/V1__create_users_pets_exp_logs.sql` (Create)

*   **Type / Scope**: Flyway 마이그레이션
*   **Proposed Changes**:
    *   브리프 4장의 `users`, `pets`, `uq_active_pet`, `exp_logs`, `ix_exp_logs_pet_date`를 그대로 만든다. `daily_plans`, `tasks`는 만들지 않는다.
    *   `pets.species`와 `pets.stage`는 `VARCHAR(20)`, `exp_logs.reason`은 `VARCHAR(30)`으로 enum 이름을 저장한다.
    *   `id`는 브리프대로 `BIGINT GENERATED ALWAYS AS IDENTITY`다.
*   **Why**: `ddl-auto: validate`이므로 엔티티보다 스키마가 먼저 있어야 한다.

#### 2. `backend/src/main/resources/db/migration/.gitkeep` (Delete)

*   **Type / Scope**: 빈 파일 삭제
*   **Why**: V1이 생기면 빈 폴더 표시가 필요 없다.

#### 3. `backend/build.gradle` (Modify)

*   **Type / Scope**: 의존성 정리
*   **Proposed Changes**: `testImplementation 'org.testcontainers:junit-jupiter'`를 지운다.
*   **Why**: 16번 파일에서 `@Testcontainers`/`@Container`를 쓰지 않게 되면 이 의존성을 쓰는 곳이 없다.

#### 4. `backend/src/main/java/com/petplanner/common/ClockConfig.java` (Create)

*   **Type / Scope**: Spring 설정
*   **Proposed Changes**: `@Bean Clock clock()` → `Clock.systemUTC()`.
*   **Why**: 테스트에서 고정 `Clock`으로 바꿔 끼우기 위해 시간을 빈으로 주입한다(AGENTS.md 7장).

#### 5. `backend/src/main/java/com/petplanner/exp/DayClock.java` (Create)

*   **Type / Scope**: `@Component`
*   **Proposed Changes**: 생성자로 `Clock`을 받는다. 상수는 `ZoneId SEOUL = Asia/Seoul`, 하루 경계 04:00(서울), 계획 마감 12:00(서울)이다.
    *   `LocalDate today()`
    *   `Instant planDeadline(LocalDate planDate)`
    *   `boolean isBeforePlanDeadline(LocalDate planDate, Instant at)`
    *   `Instant now()` → `clock.instant()` (`graduatedAt` 기록용)
*   **Why**: 날짜 계산은 이 클래스만 한다(AGENTS.md 4장 2항).

#### 6. `backend/src/main/java/com/petplanner/pet/PetStage.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**:
    *   값: `EGG(0), BABY(100), JUNIOR(600), ADULT(1800), GRADUATED(4000)`.
    *   `static PetStage of(int totalExp)`: 음수는 EGG.
    *   `Integer nextStageExp()`: GRADUATED는 null.
*   **Why**: 단계 계산은 이 함수만 한다(AGENTS.md 4장 6항).

#### 7. `backend/src/main/java/com/petplanner/pet/Species.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**: `DOG, CAT, PENGUIN, HAMSTER`.
*   **Why**: `pets.species` 매핑.

#### 8. `backend/src/main/java/com/petplanner/pet/Pet.java` (Create)

*   **Type / Scope**: JPA 엔티티 (`pets`)
*   **Proposed Changes**:
    *   필드: `id`, `userId`, `species`, `name`, `stage`, `totalExp`, `active`, `graduatedAt`, `createdAt`.
        *   `id`: `@Id @GeneratedValue(strategy = GenerationType.IDENTITY)`
        *   `species`, `stage`: `@Enumerated(EnumType.STRING)`
        *   `active`: `@Column(name = "is_active")`
        *   `graduatedAt`: `Instant`
        *   `createdAt`: `Instant`, `insertable = false, updatable = false`
    *   setter는 두지 않는다.
    *   `boolean applyTotalExp(int total, Instant now)`: Technical Plan "단계 계산"의 1~4를 그대로 구현한다.
    *   생성 팩토리는 D5의 알 고르기 API 설계에서 만든다. 테스트는 SQL로 펫을 넣는다.
*   **Why**: 엔티티는 의미 있는 메서드로만 상태를 바꾼다(AGENTS.md 6.1). `IDENTITY`를 명시하지 않으면 Hibernate가 시퀀스를 기대해 `validate`에서 기동이 실패한다.

#### 9. `backend/src/main/java/com/petplanner/pet/PetRepository.java` (Create)

*   **Type / Scope**: Spring Data JPA
*   **Proposed Changes**: `@Lock(LockModeType.PESSIMISTIC_WRITE) @Query("select p from Pet p where p.id = :id") Optional<Pet> findByIdForUpdate(Long id)`.
*   **Why**: Technical Plan "잠금 순서"의 펫 행 잠금. 호출자와 `ExpService`가 함께 쓴다.

#### 10. `backend/src/main/java/com/petplanner/exp/ExpReason.java` (Create)

*   **Type / Scope**: enum
*   **Proposed Changes**: `PLAN, TASK, MAIN_GOAL, REFLECTION, BONUS_RATE, STREAK`. 이 선언 순서가 정산 `items`의 순서다.
*   **Why**: `exp_logs.reason` 매핑.

#### 11. `backend/src/main/java/com/petplanner/exp/ExpLog.java` (Create)

*   **Type / Scope**: JPA 엔티티 (`exp_logs`), `@org.hibernate.annotations.Immutable`
*   **Proposed Changes**:
    *   필드: `id`, `petId`, `planDate`, `amount`, `reason`, `refId`, `createdAt`.
        *   `id`: `@Id @GeneratedValue(strategy = GenerationType.IDENTITY)`
        *   `planDate`: `LocalDate`
        *   `reason`: `@Enumerated(EnumType.STRING)`
        *   `createdAt`: `insertable = false, updatable = false`
    *   쓰기는 `ExpLogRepository`의 네이티브 쿼리로만 한다.
    *   생성자는 JPA용 `protected` 하나만 둔다.
*   **Why**: 리포지토리 타입과 `ddl-auto: validate` 검증에 필요하다.

#### 12. `backend/src/main/java/com/petplanner/exp/ExpLogRepository.java` (Create)

*   **Type / Scope**: Spring Data JPA, 네이티브 쿼리
*   **Proposed Changes**:
    *   **파라미터 규칙**
        *   `reason`은 `String`으로 받고, 호출 측에서 `ExpReason.name()`을 넘긴다. Hibernate 6은 네이티브 쿼리에 enum을 넘기면 순번(숫자)으로 바인딩해 `VARCHAR` 컬럼과 맞지 않는다.
        *   나머지 타입은 `long petId`, `LocalDate planDate`, `int amount`, `long refId`다.
        *   `@Param`은 쓰지 않는다. Spring Boot Gradle 플러그인이 `-parameters`를 켜므로 이름으로 바인딩된다.
    *   `@Modifying int insertIgnoringDuplicate(long petId, LocalDate planDate, int amount, String reason, long refId)`
        *   `INSERT INTO exp_logs (pet_id, plan_date, amount, reason, ref_id) VALUES (...) ON CONFLICT (pet_id, reason, ref_id) DO NOTHING`
        *   반환값은 들어간 행 수(0 또는 1)다.
        *   `created_at`은 DB 기본값 `now()`이며, 주입한 `Clock`과 무관하다(로그 시각은 감사용이라 실제 시각이 맞다).
    *   `@Modifying int deleteGrant(long petId, String reason, long refId)`
    *   `int sumForDayExcludingStreak(long petId, LocalDate planDate)`: `CAST(COALESCE(SUM(amount), 0) AS int)`, `reason <> 'STREAK'`
    *   `int sumTotal(long petId)`: `CAST(COALESCE(SUM(amount), 0) AS int)`
    *   `List<ReasonTotal> sumByReasonForDay(long petId, LocalDate planDate)`
        *   SQL: `SELECT reason AS reason, CAST(SUM(amount) AS int) AS total ... GROUP BY reason`
        *   `ReasonTotal`은 이 파일 안의 인터페이스로 둔다: `interface ReasonTotal { String getReason(); int getTotal(); }`
        *   정렬은 하지 않는다(13번 파일이 정렬).
*   **Why**: 지급 흐름 4~7단계와 회수 흐름.

#### 13. `backend/src/main/java/com/petplanner/exp/ExpService.java` (Create)

*   **Type / Scope**: `@Service`, 모든 public 메서드 `@Transactional`
*   **Proposed Changes**:
    *   금액·조건 상수는 브리프 2.2 표를 그대로 둔다. `PLAN=10, TASK=5, TASK_LATE=2, MAIN_GOAL=30, REFLECTION=10, STREAK=50, DAILY_CAP=100, BONUS_RATE_PERCENT=20, BONUS_MIN_COMPLETION=80, MIN_TASKS_FOR_PLAN=3, STREAK_INTERVAL=7`
    *   `ExpResult grantPlan(long petId, LocalDate planDate, long planId, int taskCount, Instant confirmedAt)`: 조건을 충족하지 않으면 지급 0
    *   `ExpResult grantTask(long petId, LocalDate planDate, long taskId, boolean lateAdded)`
    *   `ExpResult revokeTask(long petId, long taskId)`: Technical Plan "회수 흐름"대로 `gainedExp = total - before`(0 또는 음수)
    *   `Settlement settle(long petId, LocalDate planDate, long planId, boolean mainGoalDone, boolean hasReflection, int completionRate, int streakDays)`
        *   STREAK 조건: `streakDays > 0 && streakDays % STREAK_INTERVAL == 0`
        *   `items`: `sumByReasonForDay` 결과를 `ExpReason.valueOf`로 바꾸고 `ordinal()` 순으로 정렬한다. 합계 0인 사유는 없다(행이 없으므로).
    *   `static int capped(int requested, int dayTotal)`: `max(0, min(requested, DAILY_CAP - dayTotal))`. package-private(접근 제한자 없음)이며 단위 테스트 대상이다.
    *   공통 private 흐름: 펫 잠금 → 상한 → 삽입 → 재계산 → `applyTotalExp`
    *   펫이 없으면 `IllegalStateException`
*   **Why**: 경험치 규칙은 이 클래스에만 둔다(브리프 6장).

#### 14. `backend/src/main/java/com/petplanner/exp/ExpResult.java`, `Settlement.java`, `PetSnapshot.java` (Create)

*   **Type / Scope**: `record` DTO
*   **Proposed Changes**:
    *   `PetSnapshot(PetStage stage, int totalExp, Integer nextStageExp, boolean stageChanged)`
    *   `ExpResult(int gainedExp, PetSnapshot pet)`
    *   `Settlement(LocalDate date, int completionRate, List<Item> items, int totalGained, PetSnapshot pet)`
        *   `record Item(ExpReason reason, int amount)`
        *   `items`는 그날 로그의 사유별 합계다.
        *   `totalGained`는 `items`의 합이다.
*   **Why**: 브리프 5장 정산 응답 예시와 같은 모양이다. 엔티티를 밖으로 내보내지 않는다(AGENTS.md 6.1).

#### 15. `backend/src/test/java/com/petplanner/TestcontainersConfiguration.java` (Create)

*   **Type / Scope**: `@TestConfiguration(proxyBeanMethods = false)`
*   **Proposed Changes**:
    *   Phase 1: `@Bean @ServiceConnection PostgreSQLContainer<?> postgres()` → `postgres:16-alpine`.
    *   Phase 3: `@Bean @Primary Clock fixedClock()` → `Clock.fixed(Instant.parse("2026-11-02T03:00:00Z"), ZoneOffset.UTC)`(서울 2026-11-02 12:00).
        *   Spring Boot는 빈 덮어쓰기를 막으므로 같은 이름으로 다시 정의하지 않고 `@Primary`로 우선한다.
        *   `ExpService`에서 `Clock`이 쓰이는 곳은 `graduatedAt` 기록뿐이다. `planDate`와 `confirmedAt`은 인자로 받으므로 고정 시각 하나로 충분하다.
*   **Why**: 모든 통합 테스트가 같은 설정을 `@Import`하므로 Spring 테스트 컨텍스트 하나와 컨테이너 하나를 함께 쓴다.

#### 16. `backend/src/test/java/com/petplanner/PetPlannerApplicationTests.java` (Modify)

*   **Type / Scope**: 기존 테스트 수정
*   **Proposed Changes**: 클래스 안의 컨테이너 필드와 `@Testcontainers`를 지우고 `@Import(TestcontainersConfiguration.class)`로 바꾼다.
*   **Why**: 컨테이너 설정을 한 곳에 둔다.

#### 17. `backend/src/test/java/com/petplanner/pet/PetStageTest.java` (Create)

*   **Type / Scope**: 단위 테스트
*   **Test cases**:
    *   `of`: 0→EGG, 99→EGG, 100→BABY, 599→BABY, 600→JUNIOR, 1799→JUNIOR, 1800→ADULT, 3999→ADULT, 4000→GRADUATED, 10000→GRADUATED, -1→EGG.
    *   `nextStageExp`: EGG 100, BABY 600, JUNIOR 1800, ADULT 4000, GRADUATED null.

#### 18. `backend/src/test/java/com/petplanner/exp/DayClockTest.java` (Create)

*   **Type / Scope**: 단위 테스트, `Clock.fixed`
*   **Test cases**:
    *   `today`: 서울 03:59:59 → 전날, 04:00:00 → 당일, 23:59:59 → 당일.
    *   `isBeforePlanDeadline`: planDate 당일 서울 11:59:59 → 마감 전, 12:00:00 → 마감 후.

#### 19. `backend/src/test/java/com/petplanner/exp/ExpServiceCapTest.java` (Create)

*   **Type / Scope**: 단위 테스트 (`ExpService.capped`)
*   **Test cases**: (5, 0)→5, (5, 98)→2, (5, 100)→0, (5, 120)→0, (30, 80)→20.

#### 20. `backend/src/test/java/com/petplanner/exp/ExpServiceIntegrationTest.java` (Create)

*   **Type / Scope**: 통합 테스트 (`@SpringBootTest`, `@Import(TestcontainersConfiguration.class)`)
*   **Test data**:
    *   `JdbcTemplate`으로 넣는다.
        *   `users`: 브리프 4장의 NOT NULL 컬럼만 채운다.
        *   `pets`: `INSERT ... RETURNING id`로 id를 받는다.
    *   누적 경험치가 필요하면 `exp_logs`에도 넣는다.
        *   **과거 `plan_date`**(고정 시각 기준 전날)에 `reason = 'TASK'`, 음수 `ref_id`(-1, -2 …)로 넣는다. 그날 날짜로 넣으면 상한에 걸리기 때문이다.
        *   같은 값을 `pets.total_exp`와 `pets.stage`에도 넣는다.
    *   "그날 합계 98"은 오늘 `plan_date`로 98짜리 한 행을 넣는다.
    *   테스트마다 끝나면 `DELETE FROM users`(CASCADE)로 지운다.
    *   테스트 클래스·메서드에 `@Transactional`을 붙이지 않는다. 동시성 테스트는 커밋된 데이터가 필요하고, 서비스 호출마다 자기 트랜잭션으로 커밋돼야 한다.
*   **Test cases**:
    *   할 일 체크 → +5. `lateAdded` 할 일 → +2
    *   같은 할 일 두 번 지급 → 두 번째 0, 로그 1행
    *   그날 합계 98에서 체크 → 2. 그날 합계 100에서 → 0이고 새 로그 없음
    *   해제 → 로그 삭제, `gainedExp` -5, `total_exp` 5 감소
    *   지급 안 된 할 일 해제 → `gainedExp` 0
    *   PLAN: 할 일 2개 → 0. 3개이고 계획 마감 전 확정 → 10. 계획 마감 이후 확정 → 0
    *   정산(브리프 5장 예시)
        *   기존 로그: PLAN 10, TASK 25
        *   입력: 핵심 목표 완료, 회고 있음, 완료율 83, 연속 3일
        *   결과: MAIN_GOAL 30, REFLECTION 10, BONUS_RATE 15 추가, 그날 합 90. `items` 순서는 PLAN, TASK, MAIN_GOAL, REFLECTION, BONUS_RATE
    *   정산(상한)
        *   기존 로그: PLAN 10, TASK 45
        *   입력: 핵심 목표 완료, 회고 있음, 완료율 90, 연속 7일
        *   결과: MAIN_GOAL 30, REFLECTION 10, BONUS_RATE 5(요청 19가 상한에 잘림), STREAK 50. STREAK 제외 합 100, 전체 합 150
    *   정산(STREAK): 연속 0일·6일 → STREAK 없음, 7일·14일 → STREAK 50
    *   정산 두 번 호출 → 두 번째 추가 지급 0, `items` 동일
    *   단계: 누적 99에서 +5 → BABY, `stageChanged` true. 누적 100에서 해제 -5 → EGG, `stageChanged` true
    *   졸업: 누적 3999에서 +5 → GRADUATED, `graduated_at` = 고정 시각. 이어서 그 할 일 해제 → 누적 3999, 단계 GRADUATED 유지, `graduated_at` 유지
    *   동시성(상한): 같은 펫, 서로 다른 할 일 25개를 스레드 25개로 동시에 지급(`ExecutorService` + `CountDownLatch`). 요청 합 125 → 그날 합계 정확히 100, 로그 20행
    *   동시성(중복): 같은 할 일을 두 스레드가 동시에 지급 → 로그 1행, 합계 5
    *   불변식: 모든 테스트 끝에 다음을 확인한다
        *   `total_exp == SUM(exp_logs.amount)`
        *   `stage == (graduated_at != null ? GRADUATED : PetStage.of(total_exp))`

#### 21. `docs/designs/SITEMAP.md` (Modify)

*   **Type / Scope**: 문서
*   **Proposed Changes**: 이미 등록된 이 문서 행의 설명 칸을 승인 후 상태(Approved)로 바꾼다.

### Verification Plan

*   **Compilation/Build**: `cd backend` 후 `.\gradlew.bat build`(macOS/Linux는 `./gradlew build`). 통합 테스트가 포함되므로 Docker가 실행 중이어야 한다
*   **Unit Tests**: `PetStageTest`, `DayClockTest`, `ExpServiceCapTest`. AGENTS.md 7장의 필수 대상인 단계 경계, 하루 상한, 03:59/04:00, 계획 마감(12:00)을 다룬다
*   **Integration Tests**: `ExpServiceIntegrationTest`(Docker 필요). 할 일 체크/해제와 하루 마감의 엔드포인트 통합 테스트는 `daily-plan-and-tasks.md`에서 따로 작성한다. 이 문서의 서비스 테스트는 그대로 둔다
*   **Static Analysis & Linting**: 별도 도구 없음. `build` 출력에 `warning:`이 없는지 확인한다

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
