-- =============================================================================
-- SkillWise — ฐานข้อมูลสำหรับ MVP (Phase 1)
-- =============================================================================
-- ฐานข้อมูล : PostgreSQL 16 ขึ้นไป (Context ข้อ 60.5, 60.11)
-- สถานะ     : [DIRECTION] ร่างออกแบบให้ทีมตรวจ ยังไม่ใช่ migration ที่ใช้จริง
--              เมื่อสร้าง apps/api ให้แปลงเป็น schema.prisma แล้วให้ Prisma สร้าง migration
-- ขอบเขต    : ฟีเจอร์ Must + Should ในหัวข้อ 8 ของ docs/sila5school-study.md
--              ตารางของ Should ติดป้าย [Should] ไว้ที่ comment ของตาราง
-- เอกสาร    : docs/database/README.md (ER diagram, บทบาทและสิทธิ์, ตารางเทียบระบบเดิม)
--
-- หลักที่ใช้ออกแบบ
--   1. แยกตาม domain ในข้อ 46 · ตัวตน ≠ สมาชิกองค์กร (ข้อ 33) · ตำแหน่ง ≠ สิทธิ์ (ข้อ 32)
--   2. ไม่ hard-code โครงสร้างโรงเรียนไทย, 7 กิจวัตร, แพ็กเกจ หรือประเภท Tool (ข้อ 47, 53)
--      ของเหล่านี้เป็น "ข้อมูล" ในตาราง ไม่ใช่คอลัมน์หรือค่าคงที่
--   3. ไม่เก็บ id หลายค่าใน 1 ช่อง (ระบบเดิมเก็บเป็น CSV) ใช้ตารางเชื่อมแทน
--   4. ข้อมูลที่ต้องย้อนดูพัฒนาการเก็บเป็น version / revision ไม่เขียนทับ
--   5. ข้อมูลนักเรียน (ผู้เยาว์) เป็นของบัญชีองค์กร มี pseudonym_key ไว้ส่ง AI แทนชื่อจริง
--   6. ค่าที่ยัง [OPEN] เช่น โควตา เกณฑ์คะแนน จำนวน Canvas สูงสุด เก็บเป็นค่าตั้ง ไม่ใช่ constraint
--
-- ข้อตกลงในไฟล์นี้
--   - primary key เป็น uuid (gen_random_uuid) ยกเว้นตาราง log ที่โตเร็วใช้ bigint identity
--   - เวลาใช้ timestamptz ทั้งหมด · วันที่ที่ไม่มีเวลาใช้ date
--   - สถานะของระบบใช้ text + CHECK (แก้ได้ด้วย migration ง่ายกว่า enum)
--   - ชื่อตารางเป็นพหูพจน์ snake_case
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;      -- อีเมลที่ไม่สนตัวพิมพ์ใหญ่/เล็ก
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- ใช้กับ EXCLUDE กันช่วงวันที่ซ้อนกัน

-- -----------------------------------------------------------------------------
-- ฟังก์ชันกลาง
-- -----------------------------------------------------------------------------

-- อัปเดต updated_at อัตโนมัติ
CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ตารางที่ห้ามแก้ไข (append-only) เช่น revision และ audit log
CREATE FUNCTION forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ตาราง % เป็นแบบเพิ่มอย่างเดียว ห้าม % (Context ข้อ 60.7, 60.10.5)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END $$;


-- =============================================================================
-- 1. Identity — ตัวตนของผู้ใช้ (ไม่ผูกกับองค์กร · ข้อ 33, 34)
-- =============================================================================

CREATE TABLE users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email          citext,                       -- login ด้วย LINE อาจไม่มีอีเมล
  display_name   text NOT NULL,
  first_name     text,
  last_name      text,
  phone          text,
  avatar_url     text,                         -- รูปจาก Google / LINE
  locale         text NOT NULL DEFAULT 'th',
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),
  last_login_at  timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CHECK ((status = 'deleted') = (deleted_at IS NOT NULL))
);
CREATE UNIQUE INDEX users_email_key ON users (email) WHERE email IS NOT NULL AND deleted_at IS NULL;
COMMENT ON TABLE users IS 'บัญชีผู้ใช้ 1 คน = 1 แถว ไม่ว่าจะอยู่กี่องค์กร หรือไม่อยู่องค์กรไหนเลย (ครูอิสระ)';

CREATE TABLE user_identities (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES users (id),
  provider              text NOT NULL CHECK (provider IN ('google', 'line')),
  provider_subject      text NOT NULL,         -- sub ของ Google / userId ของ LINE
  email_at_provider     citext,
  can_receive_messages  boolean NOT NULL DEFAULT false,  -- LINE: เพิ่มเพื่อน OA แล้ว ส่ง push ได้
  linked_at             timestamptz NOT NULL DEFAULT now(),
  unlinked_at           timestamptz
);
CREATE UNIQUE INDEX user_identities_subject_key ON user_identities (provider, provider_subject) WHERE unlinked_at IS NULL;
CREATE UNIQUE INDEX user_identities_one_per_provider ON user_identities (user_id, provider) WHERE unlinked_at IS NULL;
COMMENT ON TABLE user_identities IS 'บัญชี Google / LINE ที่ใช้ login และใช้รับข้อความ LINE (ข้อ 60.5, 60.10.6)';

CREATE TABLE auth_sessions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES users (id),
  kind                  text NOT NULL CHECK (kind IN ('session', 'remember')),
  token_hash            bytea NOT NULL UNIQUE,  -- เก็บแค่ SHA-256 ของ token
  -- token ที่หมุนต่อกันอยู่ family เดียว ถ้า token เก่าถูกใช้ซ้ำให้ revoke ทั้ง family
  family_id             uuid NOT NULL DEFAULT gen_random_uuid(),
  impersonator_user_id  uuid REFERENCES users (id),  -- มีค่าเมื่อแอดมิน login-as
  ip                    inet,
  user_agent            text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_seen_at          timestamptz,
  expires_at            timestamptz NOT NULL,
  -- อายุสูงสุดของ family ระบบเดิมหมุนแล้วได้อายุใหม่ 7 วันเรื่อย ๆ จึงไม่มีวันหมด
  absolute_expires_at   timestamptz NOT NULL,
  rotated_to_id         uuid REFERENCES auth_sessions (id),  -- remember-me หมุน token ทุกครั้งที่ใช้
  revoked_at            timestamptz,
  CHECK (expires_at > created_at),
  CHECK (expires_at <= absolute_expires_at)
);
CREATE INDEX auth_sessions_user_idx ON auth_sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX auth_sessions_family_idx ON auth_sessions (family_id);
COMMENT ON TABLE auth_sessions IS 'session และ remember-me token แบบหมุน (ระบบเดิม library/rgt/siteAuth.php)';

CREATE TABLE policy_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL,                 -- เช่น privacy, terms, marketing (เพิ่มได้)
  version       text NOT NULL,
  title         text NOT NULL,
  body          text NOT NULL,
  is_required   boolean NOT NULL DEFAULT true, -- false = ผู้ใช้เลือกไม่ยินยอมได้ เช่น การตลาด
  effective_at  timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, version)
);
COMMENT ON TABLE policy_documents IS 'นโยบายแต่ละฉบับมี version · ระบบเดิมเก็บความยินยอม 2 ค่าที่ไม่เคยแยกกันจริง';

CREATE TABLE user_consents (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES users (id),
  policy_document_id  uuid NOT NULL REFERENCES policy_documents (id),
  decision            text NOT NULL CHECK (decision IN ('granted', 'declined', 'withdrawn')),
  decided_at          timestamptz NOT NULL DEFAULT now(),
  ip                  inet,
  user_agent          text
);
CREATE INDEX user_consents_lookup_idx ON user_consents (user_id, policy_document_id, decided_at DESC);
COMMENT ON TABLE user_consents IS 'ประวัติการให้/ถอนความยินยอม เพิ่มแถวใหม่ทุกครั้ง แถวล่าสุดคือสถานะปัจจุบัน';


-- =============================================================================
-- 2. Organization — องค์กร โครงสร้างภายใน และสมาชิก (ข้อ 33, 35)
-- =============================================================================

CREATE TABLE organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  org_kind      text NOT NULL DEFAULT 'school',  -- เป็นข้อมูล ไม่ใช่โครงสร้างตายตัว
  attributes    jsonb NOT NULL DEFAULT '{}',     -- ข้อมูลเสริมที่ไม่บังคับ เช่น สังกัด เขต ขนาด
  address_line  text,
  subdistrict   text,
  district      text,
  province      text,
  postal_code   text,
  country_code  char(2) NOT NULL DEFAULT 'TH',
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_by    uuid REFERENCES users (id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE organizations IS 'โรงเรียนหรือองค์กรอื่น ไม่บังคับว่าครูต้องมีองค์กร (ข้อ 34, 53)';

CREATE TABLE org_units (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  parent_id        uuid,
  kind             text NOT NULL,          -- องค์กรตั้งเอง เช่น level, classroom, group
  name             text NOT NULL,          -- เช่น "ป.4", "ป.4/1", "ชมรมดนตรี"
  sort_order       integer NOT NULL DEFAULT 0,
  archived_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, organization_id),
  -- parent ต้องอยู่องค์กรเดียวกัน
  FOREIGN KEY (parent_id, organization_id) REFERENCES org_units (id, organization_id),
  CHECK (parent_id IS DISTINCT FROM id)
);
CREATE INDEX org_units_parent_idx ON org_units (organization_id, parent_id);
COMMENT ON TABLE org_units IS 'โครงสร้างภายในองค์กรแบบต้นไม้ (ระดับ → ห้อง → กลุ่ม) ตั้งค่าได้ ไม่ fix ป.4 ขึ้นไป (ข้อ 35)';

CREATE TABLE memberships (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users (id),
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  position_title   text,                   -- ตำแหน่งงานเพื่อแสดงผล ไม่ใช่สิทธิ์ (ข้อ 32)
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left', 'removed')),
  joined_at        timestamptz NOT NULL DEFAULT now(),
  ended_at         timestamptz,
  created_by       uuid REFERENCES users (id),
  CHECK ((status = 'active') = (ended_at IS NULL))
);
CREATE UNIQUE INDEX memberships_active_key ON memberships (user_id, organization_id) WHERE status = 'active';
CREATE UNIQUE INDEX memberships_id_org_key ON memberships (id, organization_id);
COMMENT ON TABLE memberships IS 'คน × องค์กร · คนหนึ่งอยู่หลายองค์กรได้ และออกแล้วประวัติไม่หาย';

CREATE TABLE membership_org_units (
  membership_id    uuid NOT NULL,
  org_unit_id      uuid NOT NULL,
  organization_id  uuid NOT NULL,
  PRIMARY KEY (membership_id, org_unit_id),
  -- ห้องต้องอยู่องค์กรเดียวกับ membership
  FOREIGN KEY (membership_id, organization_id) REFERENCES memberships (id, organization_id) ON DELETE CASCADE,
  FOREIGN KEY (org_unit_id, organization_id) REFERENCES org_units (id, organization_id)
);
COMMENT ON TABLE membership_org_units IS 'ห้อง/กลุ่มที่ครูดูแล ใช้กรองหน้าจอ ไม่ใช่การให้สิทธิ์ (ระบบเดิมเก็บเป็น CSV ใน stk_class)';


-- =============================================================================
-- 3. Role & Permission — บทบาทประกอบจากสิทธิ์ที่ตั้งชื่อชัด (ข้อ 32, 60.7)
-- =============================================================================

CREATE TABLE permissions (
  code          text PRIMARY KEY CHECK (code ~ '^[a-z_]+(\.[a-z_]+)+$'),
  scope         text NOT NULL CHECK (scope IN ('platform', 'organization', 'self')),
  description   text NOT NULL,
  is_sensitive  boolean NOT NULL DEFAULT false  -- true = ใช้เมื่อไรต้องบันทึก audit_logs
);
COMMENT ON TABLE permissions IS 'รายการสิทธิ์ทั้งหมด · endpoint ทุกตัวต้องประกาศว่าใช้สิทธิ์ไหน ค่าเริ่มต้นคือปฏิเสธ';

CREATE TABLE roles (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code             text NOT NULL,
  name             text NOT NULL,
  description      text,
  scope            text NOT NULL CHECK (scope IN ('platform', 'organization')),
  organization_id  uuid REFERENCES organizations (id),  -- null = บทบาทมาตรฐาน · มีค่า = องค์กรสร้างเอง (อนาคต)
  is_system        boolean NOT NULL DEFAULT false,      -- บทบาทที่ระบบต้องมี ห้ามลบ
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, scope),
  CHECK (scope = 'organization' OR organization_id IS NULL)
);
CREATE UNIQUE INDEX roles_standard_code_key ON roles (code) WHERE organization_id IS NULL;
CREATE UNIQUE INDEX roles_org_code_key ON roles (organization_id, code) WHERE organization_id IS NOT NULL;
COMMENT ON TABLE roles IS 'บทบาท · แอดมินปรับสิทธิ์ในบทบาทได้จากหน้าแอดมิน (ข้อ 60.7) · ไม่ใช้ตัวเลขระดับ 1–9 แบบระบบเดิม';

CREATE TABLE role_permissions (
  role_id          uuid NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
  permission_code  text NOT NULL REFERENCES permissions (code),
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE role_assignments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users (id),
  role_id          uuid NOT NULL,
  role_scope       text NOT NULL,
  organization_id  uuid REFERENCES organizations (id),
  granted_by       uuid REFERENCES users (id),
  granted_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz,
  revoked_at       timestamptz,
  revoked_by       uuid REFERENCES users (id),
  -- บทบาทระดับ platform ต้องไม่มีองค์กร · บทบาทระดับองค์กรต้องมีองค์กร
  FOREIGN KEY (role_id, role_scope) REFERENCES roles (id, scope),
  CHECK ((role_scope = 'platform') = (organization_id IS NULL))
);
CREATE UNIQUE INDEX role_assignments_active_key
  ON role_assignments (user_id, role_id, organization_id) NULLS NOT DISTINCT WHERE revoked_at IS NULL;
COMMENT ON TABLE role_assignments IS 'มอบบทบาทให้คน ระดับทั้งระบบ (แอดมิน, โค้ช) หรือรายองค์กร';

CREATE TABLE invitations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  email            citext,                 -- null = เชิญด้วยลิงก์
  role_id          uuid NOT NULL,
  role_scope       text NOT NULL DEFAULT 'organization' CHECK (role_scope = 'organization'),
  token_hash       bytea NOT NULL UNIQUE,
  invited_by       uuid NOT NULL REFERENCES users (id),
  expires_at       timestamptz NOT NULL,
  accepted_at      timestamptz,
  accepted_by      uuid REFERENCES users (id),
  revoked_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (role_id, role_scope) REFERENCES roles (id, scope),
  CHECK ((accepted_at IS NULL) = (accepted_by IS NULL))
);
CREATE UNIQUE INDEX invitations_pending_email_key ON invitations (organization_id, email)
  WHERE email IS NOT NULL AND accepted_at IS NULL AND revoked_at IS NULL;
COMMENT ON TABLE invitations IS 'เชิญเข้าองค์กรด้วยอีเมลหรือลิงก์ ผูกเข้าองค์กรตอน login ครั้งแรก';


-- =============================================================================
-- 4. File — ไฟล์เป็น private โดยค่าเริ่มต้น
-- =============================================================================

CREATE TABLE files (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id          uuid REFERENCES users (id),
  organization_id        uuid REFERENCES organizations (id),
  storage_bucket         text NOT NULL,
  storage_key            text NOT NULL,
  original_name          text,
  mime_type              text NOT NULL,
  size_bytes             bigint NOT NULL CHECK (size_bytes >= 0),
  checksum_sha256        bytea,
  access_level           text NOT NULL DEFAULT 'private' CHECK (access_level IN ('private', 'organization', 'public')),
  contains_student_data  boolean NOT NULL DEFAULT false,
  uploaded_at            timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  UNIQUE (storage_bucket, storage_key),
  -- ไฟล์ที่มีข้อมูลนักเรียนห้ามเป็น public
  CHECK (NOT (access_level = 'public' AND contains_student_data))
);
COMMENT ON TABLE files IS 'ไฟล์ทุกชนิด (R2/S3) ดาวน์โหลดผ่าน API ที่ตรวจสิทธิ์ · ระบบเดิมคุมสิทธิ์แค่ระดับ bucket';

ALTER TABLE organizations
  ADD COLUMN logo_file_id uuid REFERENCES files (id);  -- แก้ได้ด้วยสิทธิ์ org.profile.manage


-- =============================================================================
-- 5. Access — สินค้า seat สิทธิ์ใช้งาน และโควตา (ข้อ 36, 42, 60.8)
--    การเข้าถึงฟีเจอร์ดูจาก entitlements ที่เดียว ไม่ผูกกับสถานะการจ่ายเงินโดยตรง
-- =============================================================================

CREATE TABLE features (
  code         text PRIMARY KEY,           -- เช่น tool.canvas, ai.plan_synthesis
  description  text NOT NULL,
  unit         text                        -- หน่วยของโควตา เช่น job, session · null = เปิด/ปิดอย่างเดียว
);
COMMENT ON TABLE features IS 'ความสามารถที่ขายหรือให้สิทธิ์ได้';

CREATE TABLE products (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text NOT NULL UNIQUE,
  name          text NOT NULL,
  product_type  text NOT NULL CHECK (product_type IN ('seat_subscription', 'credit_pack', 'course', 'physical')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE products IS 'สินค้า/แพ็กเกจเป็นข้อมูล ไม่ hard-code (ข้อ 47) · ราคายัง OPEN จึงไม่มีคอลัมน์ราคา';

CREATE TABLE product_features (
  product_id    uuid NOT NULL REFERENCES products (id) ON DELETE CASCADE,
  feature_code  text NOT NULL REFERENCES features (code),
  quota         integer CHECK (quota >= 0),   -- null = ไม่จำกัด
  quota_period  text CHECK (quota_period IN ('month', 'year', 'lifetime')),
  PRIMARY KEY (product_id, feature_code),
  CHECK ((quota IS NULL) = (quota_period IS NULL))
);
COMMENT ON TABLE product_features IS 'สินค้าแต่ละตัวให้ feature อะไร โควตาเท่าไร · ตัวเลขโควตายัง OPEN (ข้อ 36)';

CREATE TABLE seat_pools (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id             uuid NOT NULL REFERENCES products (id),
  purchase_type          text NOT NULL CHECK (purchase_type IN ('individual', 'set', 'b2b')),  -- ข้อ 60.8 [CONFIRMED]
  owner_organization_id  uuid REFERENCES organizations (id),
  owner_user_id          uuid REFERENCES users (id),
  seat_count             integer NOT NULL CHECK (seat_count > 0),
  source                 text NOT NULL CHECK (source IN ('purchase', 'manual_grant', 'trial', 'promotion')),
  order_item_id          uuid,             -- FK เพิ่มในส่วน Billing
  starts_at              timestamptz NOT NULL,
  ends_at                timestamptz,      -- อายุ seat ยัง OPEN
  created_by             uuid REFERENCES users (id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(owner_organization_id, owner_user_id) = 1),
  CHECK (purchase_type <> 'individual' OR seat_count = 1),
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
COMMENT ON TABLE seat_pools IS 'ก้อน seat ที่ซื้อหรือได้รับ (รายคน / ชุด / B2B) · ขนาดชุด 10-20-30 อยู่ที่ข้อมูล ไม่ใช่ constraint';

CREATE TABLE seat_assignments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seat_pool_id  uuid NOT NULL REFERENCES seat_pools (id),
  user_id       uuid NOT NULL REFERENCES users (id),
  assigned_by   uuid REFERENCES users (id),
  assigned_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  revoked_by    uuid REFERENCES users (id),
  revoke_reason text                       -- การดึง seat คืน/ย้ายยัง OPEN (ข้อ 36)
);
CREATE UNIQUE INDEX seat_assignments_active_key ON seat_assignments (seat_pool_id, user_id) WHERE revoked_at IS NULL;
COMMENT ON TABLE seat_assignments IS 'แจก seat ให้ครู · trigger กันแจกเกินจำนวน seat แม้มีคนกดพร้อมกัน';

-- กันแจก seat เกินจำนวน: ล็อกแถว pool ก่อนนับ จึงไม่เกิด race condition แบบระบบเดิม (study หัวข้อ 6.3)
CREATE FUNCTION enforce_seat_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  capacity integer;
  used     integer;
BEGIN
  IF NEW.revoked_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT seat_count INTO capacity FROM seat_pools WHERE id = NEW.seat_pool_id FOR UPDATE;
  SELECT count(*) INTO used FROM seat_assignments
   WHERE seat_pool_id = NEW.seat_pool_id AND revoked_at IS NULL AND id <> NEW.id;
  IF used >= capacity THEN
    RAISE EXCEPTION 'seat pool % เต็มแล้ว (% ที่)', NEW.seat_pool_id, capacity USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seat_assignments_capacity
  BEFORE INSERT OR UPDATE OF seat_pool_id, revoked_at ON seat_assignments
  FOR EACH ROW EXECUTE FUNCTION enforce_seat_capacity();

CREATE TABLE entitlements (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES users (id),
  product_id          uuid NOT NULL REFERENCES products (id),
  organization_id     uuid REFERENCES organizations (id),  -- องค์กรที่ให้สิทธิ์ (ถ้ามี)
  source              text NOT NULL CHECK (source IN ('seat', 'manual_grant', 'trial', 'promotion', 'course')),
  seat_assignment_id  uuid REFERENCES seat_assignments (id),
  starts_at           timestamptz NOT NULL,
  ends_at             timestamptz,
  granted_by          uuid REFERENCES users (id),
  revoked_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((source = 'seat') = (seat_assignment_id IS NOT NULL)),
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX entitlements_user_idx ON entitlements (user_id) WHERE revoked_at IS NULL;
COMMENT ON TABLE entitlements IS 'สิทธิ์ใช้งานของแต่ละคน · API ตรวจสิทธิ์ใช้ฟีเจอร์จากตารางนี้ที่เดียว (ข้อ 42)';

CREATE TABLE usage_ledger (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES users (id),
  feature_code    text NOT NULL REFERENCES features (code),
  entitlement_id  uuid REFERENCES entitlements (id),
  delta           integer NOT NULL CHECK (delta <> 0),
  reason          text NOT NULL CHECK (reason IN ('trial_grant', 'quota_grant', 'purchase', 'usage', 'refund', 'manual_adjust', 'expire')),
  ai_job_id       uuid,                    -- FK เพิ่มในส่วน AI
  note            text,
  created_by      uuid REFERENCES users (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- การใช้และการหมดอายุต้องติดลบ ส่วนการเติมต้องเป็นบวก
  CHECK (reason = 'manual_adjust' OR (reason IN ('usage', 'expire')) = (delta < 0))
);
CREATE UNIQUE INDEX usage_ledger_one_charge_per_job ON usage_ledger (ai_job_id) WHERE reason = 'usage';
CREATE INDEX usage_ledger_balance_idx ON usage_ledger (user_id, feature_code);
COMMENT ON TABLE usage_ledger IS 'บัญชีเครดิต/โควตาแบบบันทึกเพิ่มอย่างเดียว ยอดคงเหลือ = SUM(delta) · ลองฟรี 1 ครั้ง = trial_grant (ข้อ 60.10.4)';

CREATE VIEW usage_balances AS
SELECT user_id, feature_code, sum(delta)::integer AS balance
FROM usage_ledger
GROUP BY user_id, feature_code;


-- =============================================================================
-- 6. Billing [Should] — ใบสั่งซื้อและการชำระเงิน แยกจาก Entitlement (ข้อ 39–41)
--    เริ่มจากโอนเงิน/แนบสลิปแล้วแอดมินยืนยัน · payment gateway ยัง OPEN
-- =============================================================================

CREATE TABLE billing_profiles (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid REFERENCES organizations (id),
  user_id          uuid REFERENCES users (id),
  billing_name     text NOT NULL,
  tax_id           text,
  branch_code      text,
  billing_address  text NOT NULL,
  email            citext,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(organization_id, user_id) = 1)
);
COMMENT ON TABLE billing_profiles IS '[Should] ชื่อและที่อยู่ออกเอกสาร · workflow ใบกำกับภาษียัง OPEN (ข้อ 41)';

CREATE TABLE orders (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_no            text NOT NULL UNIQUE,
  billing_profile_id  uuid NOT NULL REFERENCES billing_profiles (id),
  buyer_user_id       uuid NOT NULL REFERENCES users (id),
  status              text NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft', 'quoted', 'awaiting_payment', 'paid', 'cancelled')),
  currency            char(3) NOT NULL DEFAULT 'THB',
  subtotal            numeric(12, 2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount            numeric(12, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  vat_amount          numeric(12, 2) NOT NULL DEFAULT 0 CHECK (vat_amount >= 0),
  total               numeric(12, 2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  invoice_no          text UNIQUE,
  invoiced_at         timestamptz,
  due_at              timestamptz,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE orders IS '[Should] ใบเสนอราคา/ใบแจ้งหนี้ ตามขั้นตอน B2B ในข้อ 40';

CREATE TABLE order_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  product_id   uuid NOT NULL REFERENCES products (id),
  quantity     integer NOT NULL CHECK (quantity > 0),       -- จำนวน seat หรือจำนวนชิ้น
  unit_price   numeric(12, 2) NOT NULL CHECK (unit_price >= 0),
  amount       numeric(12, 2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  description  text
);
COMMENT ON TABLE order_items IS '[Should] รายการในใบสั่งซื้อ · ราคาเก็บ ณ วันที่ขาย';

ALTER TABLE seat_pools
  ADD CONSTRAINT seat_pools_order_item_fk FOREIGN KEY (order_item_id) REFERENCES order_items (id);

CREATE TABLE payments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id           uuid NOT NULL REFERENCES orders (id),
  method             text NOT NULL CHECK (method IN ('bank_transfer', 'promptpay', 'card', 'gateway', 'other')),
  amount             numeric(12, 2) NOT NULL CHECK (amount > 0),
  status             text NOT NULL DEFAULT 'pending_verification'
                     CHECK (status IN ('pending_verification', 'verified', 'rejected', 'refunded')),
  slip_file_id       uuid REFERENCES files (id),
  gateway_reference  text,
  paid_at            timestamptz,
  verified_by        uuid REFERENCES users (id),
  verified_at        timestamptz,
  rejection_reason   text,
  created_by         uuid REFERENCES users (id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (status = 'pending_verification' OR verified_at IS NOT NULL),
  CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL)
);
COMMENT ON TABLE payments IS '[Should] การชำระเงิน · แอดมินยืนยันสลิปแล้วจึงสร้าง seat_pools (แยกจาก Entitlement)';


-- =============================================================================
-- 7. Student — ข้อมูลนักเรียน (ผู้เยาว์) เป็นของบัญชีองค์กร (ข้อ 44, 60.2)
--    เห็นได้: บุคลากรในองค์กร, โค้ชที่ดูแล case, แอดมินที่มีสิทธิ์ (บันทึก audit ทุกครั้ง)
--    ตัวอย่างการกันข้อมูลข้ามองค์กรในระดับฐานข้อมูลอยู่ใน rls.sql
-- =============================================================================

CREATE TABLE students (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  first_name       text NOT NULL,
  last_name        text,
  nickname         text,
  student_code     text,                   -- เลขประจำตัวในองค์กร (ถ้ามี)
  -- รหัสแทนชื่อสำหรับส่ง AI · ระบบแทนชื่อด้วยรหัสก่อนส่ง แล้วแปลงกลับตอนแสดงผล
  pseudonym_key    text NOT NULL UNIQUE
                   DEFAULT ('S-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  source           text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'import')),
  created_by       uuid REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  UNIQUE (id, organization_id)
);
CREATE UNIQUE INDEX students_code_key ON students (organization_id, student_code)
  WHERE student_code IS NOT NULL AND deleted_at IS NULL;
COMMENT ON TABLE students IS 'ระเบียนนักเรียนขององค์กร ไม่มี account ใน Phase 1 · รายการ field สุดท้ายยัง OPEN (ข้อ 60.2)';

CREATE TABLE student_enrollments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id       uuid NOT NULL,
  org_unit_id      uuid NOT NULL,
  organization_id  uuid NOT NULL,
  starts_on        date NOT NULL,
  ends_on          date,
  created_by       uuid REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- นักเรียนกับห้องต้องอยู่องค์กรเดียวกัน
  FOREIGN KEY (student_id, organization_id) REFERENCES students (id, organization_id),
  FOREIGN KEY (org_unit_id, organization_id) REFERENCES org_units (id, organization_id),
  CHECK (ends_on IS NULL OR ends_on >= starts_on),
  -- ห้ามมีช่วงเวลาซ้อนกันในห้องเดียวกัน
  EXCLUDE USING gist (student_id WITH =, org_unit_id WITH =, daterange(starts_on, ends_on, '[]') WITH &&)
);
COMMENT ON TABLE student_enrollments IS 'นักเรียนอยู่ห้อง/กลุ่มไหนช่วงไหน · ข้ามปีไม่ต้องกรอกนักเรียนใหม่ (ระบบเดิมกรอกใหม่ทุกปี)';

CREATE TABLE import_jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations (id),
  requested_by     uuid NOT NULL REFERENCES users (id),
  import_type      text NOT NULL,          -- เช่น students
  file_id          uuid REFERENCES files (id),  -- ไฟล์ต้นฉบับ ลบตาม expires_at
  status           text NOT NULL DEFAULT 'uploaded'
                   CHECK (status IN ('uploaded', 'previewed', 'importing', 'completed', 'failed', 'cancelled')),
  total_rows       integer CHECK (total_rows >= 0),
  imported_rows    integer CHECK (imported_rows >= 0),
  error_rows       integer CHECK (error_rows >= 0),
  row_errors       jsonb NOT NULL DEFAULT '[]',  -- [{row, column, message}] ห้ามเก็บข้อมูลนักเรียนทั้งแถว
  created_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz,
  expires_at       timestamptz NOT NULL    -- วันที่ต้องลบไฟล์ต้นฉบับ (study หัวข้อ 7.1 ข้อ 9)
);
COMMENT ON TABLE import_jobs IS 'งาน import ไฟล์ เช่น รายชื่อนักเรียนจาก Excel: อัปโหลด → preview → import ใน transaction';

ALTER TABLE students
  ADD COLUMN import_job_id uuid REFERENCES import_jobs (id),  -- import ครั้งไหน ใช้ไล่ตรวจหรือย้อนการ import
  ADD CONSTRAINT students_import_source CHECK (import_job_id IS NULL OR source = 'import');


-- =============================================================================
-- 8. Tool / Case / Canvas (ข้อ 7, 12, 13, 45)
--    ช่องของ Canvas เป็นข้อมูลใน tool_fields จึงเพิ่ม Tool อื่นหรือปรับช่องได้โดยไม่แก้ schema
-- =============================================================================

CREATE TABLE tools (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text NOT NULL UNIQUE,
  name         text NOT NULL,
  description  text,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE tools IS 'เครื่องมือคิดของครู · ตอนนี้มี Unlock Hidden Potential Canvas แต่ห้าม hard-code ว่ามีตัวเดียว (ข้อ 45)';

CREATE TABLE tool_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_id       uuid NOT NULL REFERENCES tools (id),
  version       integer NOT NULL CHECK (version > 0),
  -- ค่าตั้งที่ยัง OPEN เช่น เกณฑ์คะแนนพร้อมทำแผน, จำนวน Canvas สูงสุดต่อการสังเคราะห์
  settings      jsonb NOT NULL DEFAULT '{}',
  published_at  timestamptz,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tool_id, version)
);
COMMENT ON TABLE tool_versions IS 'Tool แต่ละ version · Canvas ที่เขียนแล้วผูกกับ version เดิมเสมอ';

CREATE TABLE tool_fields (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_version_id  uuid NOT NULL REFERENCES tool_versions (id) ON DELETE CASCADE,
  field_key        text NOT NULL,          -- เช่น potential, reason, signals
  label            text NOT NULL,
  help_text        text,
  sort_order       integer NOT NULL,
  is_required      boolean NOT NULL DEFAULT true,
  is_signal_field  boolean NOT NULL DEFAULT false,  -- ช่องที่แตกเป็นสัญญาณความสำเร็จ
  max_score        numeric(4, 2),          -- คะแนนเต็มของช่อง (ถ้ามี rubric)
  config           jsonb NOT NULL DEFAULT '{}',     -- ค่าหน้าจอ เช่น placeholder, ความยาวสูงสุด
  UNIQUE (tool_version_id, field_key),
  UNIQUE (tool_version_id, sort_order),
  UNIQUE (id, tool_version_id)
);
COMMENT ON TABLE tool_fields IS 'ช่องของ Tool เช่น Canvas 7 ช่อง (ข้อ 7) · ชื่อช่องปรับตาม UX ได้';

CREATE TABLE cases (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id    uuid NOT NULL REFERENCES users (id),
  organization_id  uuid REFERENCES organizations (id),  -- null = ครูอิสระ
  title            text NOT NULL,
  situation        text NOT NULL,          -- เกิดอะไรขึ้น
  impact           text,                   -- ส่งผลอย่างไร
  scope            text NOT NULL CHECK (scope IN ('individual', 'group', 'classroom', 'other')),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_practice', 'closed', 'archived')),
  -- ใครในองค์กรเห็นได้: ค่าเริ่มต้นยัง OPEN (study หัวข้อ 9 ข้อ 3) จึงเริ่มที่ private ตามข้อ 31
  visibility       text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'organization')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, organization_id),
  CHECK (visibility = 'private' OR organization_id IS NOT NULL)
);
COMMENT ON TABLE cases IS 'สถานการณ์จริง/ประเด็นท้าทายที่ครูนำมาพัฒนา (Product Loop ข้อ 48)';

CREATE TABLE case_targets (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id          uuid NOT NULL,
  organization_id  uuid,
  student_id       uuid,
  org_unit_id      uuid,
  label            text,                   -- คำอธิบายกลุ่มเมื่อไม่ได้บันทึกรายชื่อ ห้ามใส่ชื่อจริง
  FOREIGN KEY (case_id) REFERENCES cases (id) ON DELETE CASCADE,
  -- นักเรียน/ห้องต้องอยู่องค์กรเดียวกับ case
  FOREIGN KEY (case_id, organization_id) REFERENCES cases (id, organization_id),
  FOREIGN KEY (student_id, organization_id) REFERENCES students (id, organization_id),
  FOREIGN KEY (org_unit_id, organization_id) REFERENCES org_units (id, organization_id),
  CHECK (num_nonnulls(student_id, org_unit_id, label) = 1),
  CHECK (num_nulls(student_id, org_unit_id) = 2 OR organization_id IS NOT NULL)
);
CREATE UNIQUE INDEX case_targets_student_key ON case_targets (case_id, student_id) WHERE student_id IS NOT NULL;
CREATE UNIQUE INDEX case_targets_unit_key ON case_targets (case_id, org_unit_id) WHERE org_unit_id IS NOT NULL;
COMMENT ON TABLE case_targets IS 'case นี้เกี่ยวกับนักเรียนหรือห้องไหน ผูกด้วย relation ไม่ใช่ค้นข้อความแบบระบบเดิม · ไม่บังคับต้องมีรายชื่อ';

CREATE TABLE canvases (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id          uuid NOT NULL REFERENCES cases (id),
  tool_version_id  uuid NOT NULL REFERENCES tool_versions (id),
  author_user_id   uuid NOT NULL REFERENCES users (id),
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'ready', 'locked', 'archived')),
  locked_at        timestamptz,
  lock_reason      text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,            -- ลบแบบ soft เพราะแผนและงาน AI ยังอ้าง revision อยู่
  UNIQUE (id, tool_version_id),
  CHECK ((status = 'locked') = (locked_at IS NOT NULL))
);
COMMENT ON TABLE canvases IS 'Canvas ของ case · เนื้อหาอยู่ใน canvas_revisions · ห้ามลบจริง';

CREATE TABLE canvas_revisions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canvas_id        uuid NOT NULL,
  tool_version_id  uuid NOT NULL,
  revision_no      integer NOT NULL CHECK (revision_no > 0),
  created_by       uuid NOT NULL REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (canvas_id, revision_no),
  UNIQUE (id, tool_version_id),
  FOREIGN KEY (canvas_id, tool_version_id) REFERENCES canvases (id, tool_version_id)
);
COMMENT ON TABLE canvas_revisions IS 'แก้ Canvas 1 ครั้ง = revision ใหม่ · เห็นพัฒนาการหลังได้ feedback (ระบบเดิม 57% ถูกแก้หลังได้คะแนน)';

CREATE TABLE canvas_field_values (
  canvas_revision_id  uuid NOT NULL,
  tool_version_id     uuid NOT NULL,
  tool_field_id       uuid NOT NULL,
  value_text          text NOT NULL,
  PRIMARY KEY (canvas_revision_id, tool_field_id),
  -- ช่องต้องเป็นของ Tool version เดียวกับ Canvas
  FOREIGN KEY (canvas_revision_id, tool_version_id) REFERENCES canvas_revisions (id, tool_version_id) ON DELETE CASCADE,
  FOREIGN KEY (tool_field_id, tool_version_id) REFERENCES tool_fields (id, tool_version_id)
);
COMMENT ON TABLE canvas_field_values IS 'คำตอบรายช่องของแต่ละ revision';

CREATE TRIGGER canvas_revisions_immutable BEFORE UPDATE ON canvas_revisions
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER canvas_field_values_immutable BEFORE UPDATE ON canvas_field_values
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

CREATE TABLE canvas_feedbacks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canvas_revision_id  uuid NOT NULL REFERENCES canvas_revisions (id),
  source              text NOT NULL CHECK (source IN ('ai', 'coach', 'self')),
  ai_job_id           uuid,                -- FK เพิ่มในส่วน AI
  author_user_id      uuid REFERENCES users (id),
  total_score         numeric(5, 2),
  summary             text,
  -- ผลจาก AI ต้องผ่านการตรวจก่อนแสดงให้ครู (ข้อ 60.10.4) · คะแนนเป็นเงื่อนไขบังคับหรือไม่ยัง OPEN
  status              text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'discarded')),
  published_at        timestamptz,
  reviewed_by         uuid REFERENCES users (id),  -- คนที่ตรวจผล AI ก่อนเผยแพร่ (ถ้าทีมตัดสินให้มีคนตรวจ · OPEN)
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((source = 'ai') = (ai_job_id IS NOT NULL)),
  CHECK (source = 'ai' OR author_user_id IS NOT NULL),
  CHECK ((status = 'published') = (published_at IS NOT NULL))
);
COMMENT ON TABLE canvas_feedbacks IS 'feedback ต่อ Canvas จาก AI, โค้ช หรือครูประเมินตัวเอง · AI เป็นผู้ช่วย ไม่ใช่ผู้ตัดสิน (ข้อ 12)';

CREATE TABLE canvas_feedback_items (
  canvas_feedback_id  uuid NOT NULL REFERENCES canvas_feedbacks (id) ON DELETE CASCADE,
  tool_field_id       uuid NOT NULL REFERENCES tool_fields (id),
  score               numeric(4, 2),
  comment             text,
  PRIMARY KEY (canvas_feedback_id, tool_field_id),
  CHECK (score IS NOT NULL OR comment IS NOT NULL)
);
COMMENT ON TABLE canvas_feedback_items IS 'คะแนน/ความเห็นรายช่อง (แทน sc_score_c1–c7 ของระบบเดิม)';

CREATE TABLE success_signals (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canvas_id           uuid NOT NULL REFERENCES canvases (id),
  source_revision_id  uuid REFERENCES canvas_revisions (id),
  description         text NOT NULL,
  sort_order          integer NOT NULL DEFAULT 0,
  retired_at          timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE success_signals IS 'สัญญาณความสำเร็จ (ช่อง 7) แตกเป็นแถว ให้บันทึกการลงมือทำอ้างถึงได้ (ระบบเดิมค้นข้อความ)';


-- =============================================================================
-- 9. AI — งาน AI ทุกประเภทใช้โครงเดียว (ข้อ 12, 60.2, 60.10.4)
-- =============================================================================

CREATE TABLE ai_jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type         text NOT NULL,          -- เช่น canvas_feedback, plan_synthesis, progress_summary
  requested_by     uuid NOT NULL REFERENCES users (id),
  organization_id  uuid REFERENCES organizations (id),
  status           text NOT NULL DEFAULT 'queued'
                   CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled', 'expired')),
  attempts         smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts     smallint NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
  idempotency_key  text UNIQUE,            -- กันกดซ้ำแล้วได้ 2 งาน
  input_fingerprint text,                  -- hash ของ input (เช่น canvas revision ที่เรียงแล้ว) ใช้ตรวจงานซ้ำ
  input_snapshot   jsonb NOT NULL,         -- ข้อมูลที่ส่งจริงหลัง pseudonymize แล้ว ห้ามมีชื่อจริง
  output           jsonb,
  error_code       text,
  error_message    text,                   -- ข้อความที่ครูอ่านเข้าใจ
  provider         text,                   -- AI Provider ยัง OPEN
  model            text,
  prompt_version   text,
  input_tokens     integer,
  output_tokens    integer,
  cost_estimate    numeric(10, 4),
  queued_at        timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  expires_at       timestamptz,
  CHECK (status IN ('queued', 'running') OR finished_at IS NOT NULL),
  CHECK (status <> 'succeeded' OR output IS NOT NULL),
  CHECK (status <> 'failed' OR error_code IS NOT NULL)
);
CREATE INDEX ai_jobs_queue_idx ON ai_jobs (queued_at) WHERE status = 'queued';
-- งานชนิดเดียวกันจาก input ชุดเดียวกันต้องไม่ค้างซ้อนกัน
CREATE UNIQUE INDEX ai_jobs_one_open_per_input ON ai_jobs (requested_by, job_type, input_fingerprint)
  WHERE status IN ('queued', 'running') AND input_fingerprint IS NOT NULL;
CREATE INDEX ai_jobs_requester_idx ON ai_jobs (requested_by, queued_at DESC);
COMMENT ON TABLE ai_jobs IS 'งาน AI เบื้องหลังที่มีสถานะให้ครูเห็น · ระบบเดิมล้มเหลว 30% จึงต้องมี retry และข้อความ error ที่ชัด';

CREATE TABLE ai_job_canvas_revisions (
  ai_job_id           uuid NOT NULL REFERENCES ai_jobs (id) ON DELETE CASCADE,
  canvas_revision_id  uuid NOT NULL REFERENCES canvas_revisions (id),
  PRIMARY KEY (ai_job_id, canvas_revision_id)
);
COMMENT ON TABLE ai_job_canvas_revisions IS 'Canvas revision ที่ใช้เป็น input ของงาน AI · ใช้ retry ได้แม้งานล้มเหลว';

ALTER TABLE usage_ledger
  ADD CONSTRAINT usage_ledger_ai_job_fk FOREIGN KEY (ai_job_id) REFERENCES ai_jobs (id);
ALTER TABLE canvas_feedbacks
  ADD CONSTRAINT canvas_feedbacks_ai_job_fk FOREIGN KEY (ai_job_id) REFERENCES ai_jobs (id);

-- หักเครดิตได้เฉพาะงาน AI ที่สำเร็จ งานที่ล้มเหลวไม่ถูกหัก (study หัวข้อ 7.1 ข้อ 3)
CREATE FUNCTION usage_requires_succeeded_job() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.reason = 'usage' AND NEW.ai_job_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ai_jobs WHERE id = NEW.ai_job_id AND status = 'succeeded') THEN
    RAISE EXCEPTION 'หักเครดิตได้เฉพาะงาน AI ที่สำเร็จ (job %)', NEW.ai_job_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER usage_ledger_charge_check BEFORE INSERT ON usage_ledger
  FOR EACH ROW EXECUTE FUNCTION usage_requires_succeeded_job();


-- =============================================================================
-- 10. Development Plan — แผนพัฒนาศักยภาพ มี version (ข้อ 13, 14)
-- =============================================================================

CREATE TABLE development_plans (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id    uuid NOT NULL REFERENCES users (id),
  organization_id  uuid REFERENCES organizations (id),
  title            text NOT NULL,
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'archived')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE development_plans IS 'แผนพัฒนา 1 เรื่อง · เนื้อหาอยู่ใน development_plan_versions · current_version_id คือ version ที่ครูเลือกใช้';

CREATE TABLE development_plan_versions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  development_plan_id  uuid NOT NULL REFERENCES development_plans (id),
  version_no           integer NOT NULL CHECK (version_no > 0),
  source               text NOT NULL CHECK (source IN ('ai', 'teacher')),
  ai_job_id            uuid REFERENCES ai_jobs (id),
  based_on_version_id  uuid REFERENCES development_plan_versions (id),
  created_by           uuid NOT NULL REFERENCES users (id),
  submitted_at         timestamptz,        -- ส่งให้ผู้ตรวจ/โค้ช (ถ้ามีขั้นตอนนี้)
  created_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (development_plan_id, version_no),
  UNIQUE (id, development_plan_id),
  CHECK ((source = 'ai') = (ai_job_id IS NOT NULL))
);
COMMENT ON TABLE development_plan_versions IS 'ร่างจาก AI และฉบับที่ครูแก้ แยกเป็น version · ครูเป็นผู้ตัดสินใจสุดท้าย (ข้อ 12)';

-- version ที่ครูเลือกใช้ ต้องเป็น version ของแผนเดียวกัน
ALTER TABLE development_plans
  ADD COLUMN current_version_id uuid,
  ADD CONSTRAINT development_plans_current_version_fk
    FOREIGN KEY (current_version_id, id) REFERENCES development_plan_versions (id, development_plan_id);

CREATE TABLE development_plan_sections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_version_id  uuid NOT NULL REFERENCES development_plan_versions (id) ON DELETE CASCADE,
  section_key      text NOT NULL,          -- เช่น context, goals, methods, measures
  title            text NOT NULL,
  body             text NOT NULL,          -- ช่อง ____ ที่ครูต้องเติม นับจากข้อความนี้
  is_editable      boolean NOT NULL DEFAULT true,  -- false = ข้อสังเกตจาก AI ที่ครูอ่านอย่างเดียว
  sort_order       integer NOT NULL,
  UNIQUE (plan_version_id, section_key),
  UNIQUE (plan_version_id, sort_order)
);

CREATE TABLE development_plan_canvases (
  plan_version_id     uuid NOT NULL REFERENCES development_plan_versions (id) ON DELETE CASCADE,
  canvas_revision_id  uuid NOT NULL REFERENCES canvas_revisions (id),
  PRIMARY KEY (plan_version_id, canvas_revision_id)
);
COMMENT ON TABLE development_plan_canvases IS 'Canvas Pool ที่ใช้สร้างแผน version นี้ · จำนวนสูงสุดเป็นค่าตั้ง ไม่ fix 5 ใบ (ข้อ 13)';

CREATE TABLE plan_reviews (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_version_id  uuid NOT NULL REFERENCES development_plan_versions (id),
  reviewer_user_id uuid NOT NULL REFERENCES users (id),
  outcome          text NOT NULL CHECK (outcome IN ('approved', 'changes_requested')),
  comment          text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE plan_reviews IS 'ผลตรวจแผน (ไม่บังคับใช้) · จะยังมีการตรวจผ่าน/ไม่ผ่านหรือไม่ยัง OPEN (study หัวข้อ 9 ข้อ 2)';


-- =============================================================================
-- 11. Practice — แผนลงมือทำและตารางกิจกรรม (ข้อ 14, 60.10.4)
--    กิจวัตรเป็นข้อมูลใน practice_sets / practice_templates ไม่ hard-code 7 กิจวัตร (ข้อ 9, 53)
-- =============================================================================

CREATE TABLE practice_sets (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid REFERENCES organizations (id),  -- null = ชุดกลางของ SkillWise
  name             text NOT NULL,
  description      text,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE practice_sets IS 'ชุดกิจวัตร/แนวปฏิบัติ เช่น 7 กิจวัตรเป็น 1 ชุด (ข้อ 10.1)';

CREATE TABLE practice_templates (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_set_id          uuid NOT NULL REFERENCES practice_sets (id),
  name                     text NOT NULL,
  description              text,
  default_recurrence_rule  text,           -- RRULE ตาม RFC 5545
  sort_order               integer NOT NULL DEFAULT 0,
  is_active                boolean NOT NULL DEFAULT true
);

CREATE TABLE action_plans (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_version_id  uuid NOT NULL REFERENCES development_plan_versions (id),
  owner_user_id    uuid NOT NULL REFERENCES users (id),
  organization_id  uuid REFERENCES organizations (id),
  title            text NOT NULL,
  starts_on        date NOT NULL,
  ends_on          date NOT NULL,          -- ระยะขั้นต่ำ (ระบบเดิม 8 สัปดาห์) เป็นค่าตั้ง
  timezone         text NOT NULL DEFAULT 'Asia/Bangkok',
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'completed', 'cancelled')),
  activated_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_on > starts_on),
  CHECK (status NOT IN ('active', 'completed') OR activated_at IS NOT NULL)
);
COMMENT ON TABLE action_plans IS 'แผนลงมือทำ อ้าง plan version ที่ใช้สร้าง (snapshot) แทนการล็อกถาวร เพื่อรองรับ Revision → Next Cycle';

CREATE TABLE action_plan_members (
  action_plan_id   uuid NOT NULL REFERENCES action_plans (id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES users (id),
  member_role      text NOT NULL CHECK (member_role IN ('owner', 'co_teacher')),
  acknowledged_at  timestamptz,            -- ครูร่วมกดยืนยันว่าอ่านแผนแล้ว
  added_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (action_plan_id, user_id)
);
COMMENT ON TABLE action_plan_members IS 'ครูเจ้าของและครูร่วม (ระบบเดิมเก็บเป็น CSV)';

CREATE TABLE action_items (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_plan_id           uuid NOT NULL REFERENCES action_plans (id) ON DELETE CASCADE,
  item_type                text NOT NULL CHECK (item_type IN ('routine', 'from_canvas', 'custom')),
  practice_template_id     uuid REFERENCES practice_templates (id),
  source_canvas_id         uuid REFERENCES canvases (id),
  source_tool_field_id     uuid REFERENCES tool_fields (id),  -- ไอเดียมาจากช่องไหนของ Canvas
  title                    text NOT NULL,
  description              text,
  expected_result          text,           -- คาดว่าจะเห็นอะไรในตัวเด็ก
  recurrence_rule          text,           -- RRULE เช่น FREQ=WEEKLY;BYDAY=MO,WE · null = ทำครั้งเดียววันที่ starts_on
  starts_on                date,           -- null = เริ่มพร้อมแผน · ใช้กับกิจกรรมที่เพิ่มกลางแผนหรือทำครั้งเดียว
  ends_on                  date,           -- null = จบพร้อมแผน
  time_of_day              time,
  duration_minutes         integer CHECK (duration_minutes > 0),
  reminder_offset_minutes  integer CHECK (reminder_offset_minutes >= 0),  -- null = ไม่เตือน
  sort_order               integer NOT NULL DEFAULT 0,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CHECK (item_type <> 'routine' OR practice_template_id IS NOT NULL),
  CHECK (item_type <> 'from_canvas' OR source_canvas_id IS NOT NULL),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),
  CHECK (recurrence_rule IS NOT NULL OR starts_on IS NOT NULL)  -- ทำครั้งเดียวต้องระบุวัน
);
COMMENT ON TABLE action_items IS 'กิจกรรมในแผน: กิจวัตรจาก template / จากไอเดียใน Canvas / ครูคิดเอง';

CREATE TABLE action_item_org_units (
  action_item_id  uuid NOT NULL REFERENCES action_items (id) ON DELETE CASCADE,
  org_unit_id     uuid NOT NULL REFERENCES org_units (id),
  PRIMARY KEY (action_item_id, org_unit_id)
);
COMMENT ON TABLE action_item_org_units IS 'กิจกรรมนี้ทำกับห้อง/กลุ่มไหน (ระบบเดิมเก็บเป็น CSV)';

CREATE TABLE action_item_assignees (
  action_item_id  uuid NOT NULL REFERENCES action_items (id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users (id),
  PRIMARY KEY (action_item_id, user_id)
);
COMMENT ON TABLE action_item_assignees IS 'ครูที่รับผิดชอบกิจกรรมนี้ (ระบบเดิมเก็บเป็น CSV)';

CREATE TABLE practice_sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_item_id       uuid NOT NULL REFERENCES action_items (id) ON DELETE CASCADE,
  original_planned_at  timestamptz NOT NULL,   -- เวลาตามแผนเดิม
  planned_at           timestamptz NOT NULL,   -- เวลาปัจจุบัน (เลื่อนได้ตลอด)
  status               text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'done', 'postponed', 'skipped')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (action_item_id, original_planned_at)
);
CREATE INDEX practice_sessions_upcoming_idx ON practice_sessions (planned_at) WHERE status = 'planned';
COMMENT ON TABLE practice_sessions IS 'to-do รายครั้งที่สร้างจาก recurrence_rule · ใช้เตือนและผูกกับบันทึก';


-- =============================================================================
-- 12. Evidence — บันทึกการลงมือทำแบบ "ทำไปบันทึกไป" (ข้อ 15, 60.10.5)
--    เวลาบันทึกมาจากระบบ · บันทึกย้อนหลังติดป้าย · แก้ไขได้แต่เก็บประวัติทุกครั้ง
--    บันทึกย้อนหลังเป็นแนวคิด ยังไม่ได้คุยรายละเอียด (ข้อ 60.12) · ถ้าทีมไม่ให้ย้อนหลังเลย
--    ให้ API ตั้งระยะเป็น 0 วัน (happened_on = วันที่บันทึก) โดยไม่ต้องแก้ตารางนี้
-- =============================================================================

CREATE TABLE practice_logs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_item_id       uuid NOT NULL REFERENCES action_items (id),
  practice_session_id  uuid REFERENCES practice_sessions (id),
  author_user_id       uuid NOT NULL REFERENCES users (id),
  outcome              text NOT NULL CHECK (outcome IN ('done', 'postponed')),
  happened_on          date NOT NULL,      -- วันที่ครูบอกว่าทำ
  recorded_at          timestamptz NOT NULL DEFAULT now(),  -- เวลาจากระบบ trigger บังคับ แก้ไม่ได้
  timezone             text NOT NULL DEFAULT 'Asia/Bangkok',
  is_backdated         boolean GENERATED ALWAYS AS (happened_on < (recorded_at AT TIME ZONE timezone)::date) STORED,
  note                 text,
  channel              text NOT NULL DEFAULT 'web' CHECK (channel IN ('web', 'line')),
  revision_no          integer NOT NULL DEFAULT 1,
  updated_by           uuid REFERENCES users (id),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  -- ห้ามบันทึกล่วงหน้า · จะให้ย้อนหลังได้หรือไม่และกี่วันยัง OPEN (ข้อ 60.12) จึงเป็นค่าตั้งใน API
  CHECK (happened_on <= (recorded_at AT TIME ZONE timezone)::date)
);
CREATE INDEX practice_logs_item_idx ON practice_logs (action_item_id, happened_on);
-- นัดหนึ่งครั้งมีบันทึก "ทำแล้ว" ได้แถวเดียว (ระบบเดิมไม่กันบันทึกซ้ำ)
CREATE UNIQUE INDEX practice_logs_one_done_per_session ON practice_logs (practice_session_id)
  WHERE outcome = 'done' AND practice_session_id IS NOT NULL;
COMMENT ON TABLE practice_logs IS 'บันทึกทำแล้ว/เลื่อน · ระบบเดิมแก้หรือลบไม่ได้ ส่วน SkillWise แก้ได้แต่เก็บประวัติ';

CREATE TABLE practice_log_revisions (
  practice_log_id  uuid NOT NULL REFERENCES practice_logs (id),
  revision_no      integer NOT NULL,
  outcome          text NOT NULL,
  happened_on      date NOT NULL,
  note             text,
  edited_by        uuid NOT NULL REFERENCES users (id),
  edited_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (practice_log_id, revision_no)
);
COMMENT ON TABLE practice_log_revisions IS 'สำเนาทุกครั้งที่สร้างหรือแก้บันทึก trigger เขียนให้อัตโนมัติ';

-- บังคับเวลาจากระบบ: ผู้ใช้ส่ง recorded_at มาเองไม่ได้ และแก้ภายหลังไม่ได้
CREATE FUNCTION practice_logs_system_time() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.recorded_at := now();
    NEW.revision_no := 1;
  ELSE
    NEW.recorded_at := OLD.recorded_at;
    NEW.author_user_id := OLD.author_user_id;
    IF (NEW.outcome, NEW.happened_on, NEW.note) IS DISTINCT FROM (OLD.outcome, OLD.happened_on, OLD.note) THEN
      NEW.revision_no := OLD.revision_no + 1;
    END IF;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER practice_logs_system_time BEFORE INSERT OR UPDATE ON practice_logs
  FOR EACH ROW EXECUTE FUNCTION practice_logs_system_time();

CREATE FUNCTION practice_logs_keep_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.revision_no <> OLD.revision_no THEN
    INSERT INTO practice_log_revisions (practice_log_id, revision_no, outcome, happened_on, note, edited_by)
    VALUES (NEW.id, NEW.revision_no, NEW.outcome, NEW.happened_on, NEW.note,
            COALESCE(NEW.updated_by, NEW.author_user_id));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER practice_logs_keep_history AFTER INSERT OR UPDATE ON practice_logs
  FOR EACH ROW EXECUTE FUNCTION practice_logs_keep_history();
CREATE TRIGGER practice_log_revisions_append_only BEFORE UPDATE OR DELETE ON practice_log_revisions
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- รายการที่ผูกกับบันทึก (ครูร่วม, นักเรียน, ไฟล์แนบ, สัญญาณ) เก็บประวัติด้วยวิธีเดียวกัน:
--   เพิ่ม = แถวใหม่ (added_by, added_at) · เอาออก = ติด removed_at / removed_by
--   แก้ข้อความ = เอาแถวเดิมออกแล้วเพิ่มแถวใหม่ · trigger กันการแก้ทับ (ข้อ 60.10.5)
--   API ห้ามลบแถว แต่ฐานข้อมูลไม่บล็อก DELETE เพื่อให้ลบตามคำขอลบข้อมูลส่วนบุคคลได้
CREATE FUNCTION link_row_remove_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.removed_at IS NOT NULL
     OR NEW.removed_at IS NULL
     OR (to_jsonb(NEW) - 'removed_at' - 'removed_by') IS DISTINCT FROM (to_jsonb(OLD) - 'removed_at' - 'removed_by') THEN
    RAISE EXCEPTION 'ตาราง % แก้ได้แค่การเอาออก (ตั้ง removed_at) ถ้าจะแก้ให้เอาออกแล้วเพิ่มแถวใหม่', TG_TABLE_NAME
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

CREATE TABLE practice_log_participants (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_log_id  uuid NOT NULL REFERENCES practice_logs (id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES users (id),
  added_by         uuid NOT NULL REFERENCES users (id),
  added_at         timestamptz NOT NULL DEFAULT now(),
  removed_by       uuid REFERENCES users (id),
  removed_at       timestamptz,
  CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
CREATE UNIQUE INDEX practice_log_participants_active_key ON practice_log_participants (practice_log_id, user_id)
  WHERE removed_at IS NULL;
COMMENT ON TABLE practice_log_participants IS 'ครูคนอื่นที่ร่วมทำในครั้งนี้ นับเป็นหลักฐานของครูทุกคน (ระบบเดิมเก็บเป็น CSV)';

CREATE TABLE practice_log_students (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_log_id  uuid NOT NULL REFERENCES practice_logs (id) ON DELETE CASCADE,
  student_id       uuid NOT NULL REFERENCES students (id),
  observation      text,
  added_by         uuid NOT NULL REFERENCES users (id),
  added_at         timestamptz NOT NULL DEFAULT now(),
  removed_by       uuid REFERENCES users (id),
  removed_at       timestamptz,
  CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
CREATE UNIQUE INDEX practice_log_students_active_key ON practice_log_students (practice_log_id, student_id)
  WHERE removed_at IS NULL;
COMMENT ON TABLE practice_log_students IS 'นักเรียนที่ครูสังเกตเห็นการเปลี่ยนแปลงในครั้งนี้ ใช้สร้าง timeline รายเด็ก';

CREATE TABLE practice_log_attachments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_log_id  uuid NOT NULL REFERENCES practice_logs (id) ON DELETE CASCADE,
  kind             text NOT NULL CHECK (kind IN ('image', 'video', 'file', 'link')),  -- ชนิดสุดท้ายยัง OPEN (ข้อ 15)
  file_id          uuid REFERENCES files (id),
  url              text,
  caption          text,
  sort_order       integer NOT NULL DEFAULT 0,
  added_by         uuid NOT NULL REFERENCES users (id),
  added_at         timestamptz NOT NULL DEFAULT now(),
  removed_by       uuid REFERENCES users (id),
  removed_at       timestamptz,
  CHECK (CASE WHEN kind = 'link' THEN url IS NOT NULL AND file_id IS NULL
              ELSE file_id IS NOT NULL AND url IS NULL END),
  CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
COMMENT ON TABLE practice_log_attachments IS 'หลักฐานแนบ · จำนวนรูปสูงสุด (ระบบเดิม 3) เป็นค่าตั้งใน API';

CREATE TABLE practice_log_signals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_log_id    uuid NOT NULL REFERENCES practice_logs (id) ON DELETE CASCADE,
  success_signal_id  uuid NOT NULL REFERENCES success_signals (id),
  note               text,
  added_by           uuid NOT NULL REFERENCES users (id),
  added_at           timestamptz NOT NULL DEFAULT now(),
  removed_by         uuid REFERENCES users (id),
  removed_at         timestamptz,
  CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
CREATE UNIQUE INDEX practice_log_signals_active_key ON practice_log_signals (practice_log_id, success_signal_id)
  WHERE removed_at IS NULL;
COMMENT ON TABLE practice_log_signals IS 'สัญญาณความสำเร็จที่เห็นในครั้งนี้';

CREATE TRIGGER practice_log_participants_remove_only BEFORE UPDATE ON practice_log_participants
  FOR EACH ROW EXECUTE FUNCTION link_row_remove_only();
CREATE TRIGGER practice_log_students_remove_only BEFORE UPDATE ON practice_log_students
  FOR EACH ROW EXECUTE FUNCTION link_row_remove_only();
CREATE TRIGGER practice_log_attachments_remove_only BEFORE UPDATE ON practice_log_attachments
  FOR EACH ROW EXECUTE FUNCTION link_row_remove_only();
CREATE TRIGGER practice_log_signals_remove_only BEFORE UPDATE ON practice_log_signals
  FOR EACH ROW EXECUTE FUNCTION link_row_remove_only();


-- =============================================================================
-- 13. Reflection & Coaching — เป็นส่วนตัวโดยค่าเริ่มต้น (ข้อ 16, 31, 60.3)
--    ผู้บริหารไม่เห็น เว้นแต่ครูแชร์เองรายชิ้นผ่าน share_grants
-- =============================================================================

CREATE TABLE reflections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_user_id   uuid NOT NULL REFERENCES users (id),
  case_id          uuid REFERENCES cases (id),
  action_plan_id   uuid REFERENCES action_plans (id),
  practice_log_id  uuid REFERENCES practice_logs (id),
  body             text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE reflections IS 'การสะท้อนคิดของครู ต่อ case / รอบ / ครั้งที่ทำ · เห็นได้แค่เจ้าของ โค้ชที่ดูแล และคนที่ครูแชร์ให้';

CREATE TABLE coach_assignments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_user_id    uuid NOT NULL REFERENCES users (id),
  teacher_user_id  uuid NOT NULL REFERENCES users (id),
  organization_id  uuid REFERENCES organizations (id),
  case_id          uuid REFERENCES cases (id),  -- null = ดูแลครูทั้งคน · มีค่า = เฉพาะ case (logic ยัง OPEN)
  starts_on        date NOT NULL,
  ends_on          date,
  assigned_by      uuid REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (coach_user_id <> teacher_user_id),
  CHECK (ends_on IS NULL OR ends_on >= starts_on)
);
CREATE INDEX coach_assignments_coach_idx ON coach_assignments (coach_user_id) WHERE ends_on IS NULL;
COMMENT ON TABLE coach_assignments IS 'โค้ชดูแลครูหรือ case ไหน · สัดส่วนครูต่อโค้ชและวิธีจับคู่ยัง OPEN (ข้อ 50)';

CREATE TABLE coach_feedbacks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coach_assignment_id uuid REFERENCES coach_assignments (id),
  teacher_user_id     uuid NOT NULL REFERENCES users (id),  -- เจ้าของพื้นที่พัฒนา
  author_user_id      uuid NOT NULL REFERENCES users (id),  -- โค้ช หรือครูที่ตอบกลับ
  parent_id           uuid REFERENCES coach_feedbacks (id),
  kind                text NOT NULL CHECK (kind IN ('question', 'comment', 'recommendation', 'reflection_prompt', 'next_practice', 'reply')),
  case_id             uuid REFERENCES cases (id),
  canvas_revision_id  uuid REFERENCES canvas_revisions (id),
  action_plan_id      uuid REFERENCES action_plans (id),
  practice_log_id     uuid REFERENCES practice_logs (id),
  reflection_id       uuid REFERENCES reflections (id),
  body                text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'reply') = (parent_id IS NOT NULL))
);
CREATE INDEX coach_feedbacks_teacher_idx ON coach_feedbacks (teacher_user_id, created_at DESC);
COMMENT ON TABLE coach_feedbacks IS 'Coach Feedback เพื่อการพัฒนา ไม่ใช่การประเมินผลงาน (ข้อ 16, 54) · ห้ามเปิดให้ผู้บริหารโดยค่าเริ่มต้น';

CREATE TABLE share_grants (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id      uuid NOT NULL REFERENCES users (id),
  organization_id    uuid NOT NULL REFERENCES organizations (id),
  audience           text NOT NULL CHECK (audience IN ('organization_managers', 'organization_members')),
  reflection_id      uuid REFERENCES reflections (id),
  coach_feedback_id  uuid REFERENCES coach_feedbacks (id),
  practice_log_id    uuid REFERENCES practice_logs (id),
  canvas_id          uuid REFERENCES canvases (id),
  granted_at         timestamptz NOT NULL DEFAULT now(),
  revoked_at         timestamptz,
  CHECK (num_nonnulls(reflection_id, coach_feedback_id, practice_log_id, canvas_id) = 1)
);
COMMENT ON TABLE share_grants IS 'ครูเลือกแชร์รายชิ้นให้คนในองค์กรเห็น (opt-in) · ขอบเขตและการยกเลิกการแชร์ยัง OPEN (ข้อ 60.3)';


-- =============================================================================
-- 14. [Should] Timeline รายเด็ก, เอกสาร PDF, การแจ้งเตือน และเนื้อหาหน้าเว็บ
-- =============================================================================

CREATE TABLE student_progress_summaries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id      uuid NOT NULL REFERENCES students (id),
  case_id         uuid REFERENCES cases (id),
  author_user_id  uuid NOT NULL REFERENCES users (id),
  period_start    date NOT NULL,
  period_end      date NOT NULL,
  before_text     text,
  after_text      text,
  ai_job_id       uuid REFERENCES ai_jobs (id),  -- AI ช่วยร่างได้ ครูแก้ได้ทั้งหมด
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'final')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end >= period_start)
);
COMMENT ON TABLE student_progress_summaries IS '[Should] สรุปก่อน/หลังรายเด็ก · ตัว timeline คือ query จาก practice_log_students';

CREATE TABLE generated_documents (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id    uuid NOT NULL REFERENCES users (id),
  document_type    text NOT NULL,          -- เช่น development_plan_pdf
  plan_version_id  uuid REFERENCES development_plan_versions (id),
  file_id          uuid NOT NULL REFERENCES files (id),
  template_version text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE generated_documents IS '[Should] เอกสารที่ระบบสร้าง เช่น แผนแบบราชการ PDF (ข้อ 60.10.5)';

CREATE TABLE notification_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL,               -- เช่น practice_reminder
  channel     text NOT NULL CHECK (channel IN ('email', 'line', 'in_app')),
  version     integer NOT NULL CHECK (version > 0),
  subject     text,
  body        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (code, channel, version)
);
CREATE UNIQUE INDEX notification_templates_one_active ON notification_templates (code, channel) WHERE is_active;
COMMENT ON TABLE notification_templates IS '[Should] แม่แบบข้อความรายช่องทาง มี version';

CREATE TABLE notification_jobs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid REFERENCES users (id),
  recipient_email      citext,             -- ผู้รับที่ยังไม่มีบัญชี เช่น อีเมลเชิญเข้าองค์กร
  invitation_id        uuid REFERENCES invitations (id),
  template_id          uuid NOT NULL REFERENCES notification_templates (id),
  channel              text NOT NULL CHECK (channel IN ('email', 'line', 'in_app')),
  payload              jsonb NOT NULL DEFAULT '{}',
  dedupe_key           text NOT NULL UNIQUE,  -- กันส่งซ้ำ เช่น session:<id>:reminder
  practice_session_id  uuid REFERENCES practice_sessions (id),
  target_url           text,               -- ปลายทางของลิงก์ในข้อความ
  click_token_hash     bytea UNIQUE,       -- hash ของ token ลิงก์นับคลิก redirect ไป target_url เท่านั้น
  scheduled_for        timestamptz NOT NULL,
  status               text NOT NULL DEFAULT 'scheduled'
                       CHECK (status IN ('scheduled', 'sending', 'sent', 'failed', 'cancelled')),
  attempts             smallint NOT NULL DEFAULT 0,
  sent_at              timestamptz,
  read_at              timestamptz,        -- ใช้กับ in_app
  error_message        text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  CHECK (num_nonnulls(user_id, recipient_email) = 1),
  CHECK (recipient_email IS NULL OR channel = 'email')
);
CREATE INDEX notification_jobs_due_idx ON notification_jobs (scheduled_for) WHERE status = 'scheduled';
COMMENT ON TABLE notification_jobs IS '[Should] คิวแจ้งเตือน เช่น เตือนตามแผนลงมือทำผ่าน LINE (ข้อ 60.10.6) · ระบบเดิมเก็บค่าเตือนแต่ไม่เคยส่ง';

CREATE TABLE notification_events (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  notification_job_id  uuid NOT NULL REFERENCES notification_jobs (id) ON DELETE CASCADE,
  event                text NOT NULL CHECK (event IN ('sent', 'delivered', 'opened', 'clicked', 'failed')),
  occurred_at          timestamptz NOT NULL DEFAULT now(),
  metadata             jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX notification_events_job_idx ON notification_events (notification_job_id);
COMMENT ON TABLE notification_events IS '[Should] ผลการส่ง เปิด และคลิก';

CREATE TABLE contents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_type   text NOT NULL,            -- เช่น news, page, faq
  slug           text NOT NULL UNIQUE,
  title          text NOT NULL,
  summary        text,
  body           text NOT NULL,
  cover_file_id  uuid REFERENCES files (id),
  status         text NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'in_review', 'approved', 'published', 'archived')),
  publish_at     timestamptz,
  approved_by    uuid REFERENCES users (id),
  approved_at    timestamptz,
  created_by     uuid NOT NULL REFERENCES users (id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  -- ไม่มีอะไรขึ้นหน้าสาธารณะได้โดยไม่ผ่านการอนุมัติ
  CHECK (status NOT IN ('approved', 'published') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
COMMENT ON TABLE contents IS '[Should] เนื้อหาหน้าเว็บสาธารณะ (Free Layer ข้อ 27)';


-- =============================================================================
-- 15. Audit — บันทึกการเปิดดูข้อมูลอ่อนไหวและการกระทำของแอดมิน (ข้อ 60.7)
-- =============================================================================

CREATE TABLE audit_logs (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at           timestamptz NOT NULL DEFAULT now(),
  actor_user_id         uuid REFERENCES users (id),
  impersonator_user_id  uuid REFERENCES users (id),  -- มีค่าเมื่อทำผ่าน login-as
  actor_type            text NOT NULL CHECK (actor_type IN ('user', 'admin', 'coach', 'system')),
  action                text NOT NULL,      -- เช่น student.view, reflection.view, role.grant
  permission_code       text REFERENCES permissions (code),
  resource_type         text NOT NULL,
  resource_id           text,
  organization_id       uuid REFERENCES organizations (id),
  ip                    inet,
  user_agent            text,
  metadata              jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX audit_logs_resource_idx ON audit_logs (resource_type, resource_id);
CREATE INDEX audit_logs_actor_idx ON audit_logs (actor_user_id, occurred_at DESC);
CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
COMMENT ON TABLE audit_logs IS 'ใคร ดูหรือทำอะไร เมื่อไร · เพิ่มอย่างเดียว แก้หรือลบไม่ได้';


-- =============================================================================
-- 16. View ข้อมูลรวมสำหรับผู้บริหาร — ไม่มีชื่อนักเรียนและเนื้อหาส่วนตัว (ข้อ 31, 43)
-- =============================================================================

CREATE VIEW org_activity_summary AS
SELECT
  o.id AS organization_id,
  (SELECT count(*) FROM memberships m
    WHERE m.organization_id = o.id AND m.status = 'active')                         AS active_members,
  (SELECT count(DISTINCT c.owner_user_id) FROM cases c
    WHERE c.organization_id = o.id)                                                 AS teachers_with_cases,
  (SELECT count(*) FROM canvases cv JOIN cases c ON c.id = cv.case_id
    WHERE c.organization_id = o.id AND cv.status <> 'archived')                     AS canvases,
  (SELECT count(*) FROM action_plans ap
    WHERE ap.organization_id = o.id AND ap.status = 'active')                       AS active_action_plans,
  (SELECT count(*) FROM practice_logs pl
     JOIN action_items ai ON ai.id = pl.action_item_id
     JOIN action_plans ap ON ap.id = ai.action_plan_id
    WHERE ap.organization_id = o.id AND pl.outcome = 'done'
      AND pl.recorded_at >= now() - interval '30 days')                             AS practice_done_30d
FROM organizations o;
COMMENT ON VIEW org_activity_summary IS 'ตัวเลขรวมระดับองค์กร ไม่เปิดเผยข้อมูลรายคน (Management Data ≠ Development Data)';


-- -----------------------------------------------------------------------------
-- trigger updated_at ของทุกตารางที่มีคอลัมน์นี้ (ยกเว้น practice_logs ที่มี trigger ของตัวเอง)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.table_name FROM information_schema.columns c
    JOIN information_schema.tables tb ON tb.table_name = c.table_name AND tb.table_schema = c.table_schema
    WHERE c.table_schema = 'public' AND c.column_name = 'updated_at'
      AND tb.table_type = 'BASE TABLE' AND c.table_name <> 'practice_logs'
  LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
                   t || '_set_updated_at', t);
  END LOOP;
END $$;

COMMIT;
