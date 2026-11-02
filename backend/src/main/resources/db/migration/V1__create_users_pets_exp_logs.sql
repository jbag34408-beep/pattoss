-- 브리프 4장 스키마 중 users, pets, exp_logs만 만든다 (daily_plans, tasks는 daily-plan-and-tasks.md)

CREATE TABLE users (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  toss_user_key   VARCHAR(100) NOT NULL UNIQUE,
  nickname        VARCHAR(30),
  push_agreed_at  TIMESTAMPTZ,            -- 알림 동의 시각, null이면 푸시를 보내지 않음
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pets (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  species       VARCHAR(20) NOT NULL,   -- DOG, CAT, PENGUIN, HAMSTER
  name          VARCHAR(20) NOT NULL,
  stage         VARCHAR(20) NOT NULL DEFAULT 'EGG',
  total_exp     INT NOT NULL DEFAULT 0,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  graduated_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 유저당 활성 펫은 1마리만
CREATE UNIQUE INDEX uq_active_pet ON pets(user_id) WHERE is_active;

CREATE TABLE exp_logs (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pet_id      BIGINT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
  plan_date   DATE NOT NULL,
  amount      INT NOT NULL,
  reason      VARCHAR(30) NOT NULL,     -- PLAN, TASK, MAIN_GOAL, REFLECTION, BONUS_RATE, STREAK
  ref_id      BIGINT NOT NULL,          -- task id 또는 plan id
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (pet_id, reason, ref_id)       -- 중복 지급 방지 (ON CONFLICT 대상)
);
CREATE INDEX ix_exp_logs_pet_date ON exp_logs(pet_id, plan_date);
