-- =============================================================================
-- SkillWise — ตัวอย่าง Row-Level Security (RLS) สำหรับข้อมูลนักเรียน
-- =============================================================================
-- สถานะ: [DIRECTION] ชั้นป้องกันที่สองต่อจาก guard ของ NestJS ไม่ได้ใช้แทน guard
--   ถ้าโค้ด API ลืมใส่เงื่อนไของค์กร ฐานข้อมูลยังกันไม่ให้เห็นนักเรียนขององค์กรอื่น
--
-- กติกาที่ใช้ (ข้อ 60.2, 60.7)
--   - บุคลากรที่เป็นสมาชิก active ขององค์กร เห็นนักเรียนขององค์กรนั้น
--   - โค้ชเห็นเฉพาะนักเรียนที่อยู่ใน case ของครูที่ตัวเองดูแล
--   - แอดมินที่มีสิทธิ์ admin.sensitive.student.view เห็นได้ เมื่อ API ตรวจสิทธิ์
--     และบันทึก audit_logs แล้วเท่านั้น (API ตั้ง app.sensitive_access = 'on')
--
-- วิธีใช้ใน API (ทุก transaction):
--   SET LOCAL app.user_id = '<uuid ของผู้ใช้>';
--   SET LOCAL app.sensitive_access = 'on';   -- เฉพาะกรณีแอดมินที่ผ่านการตรวจแล้ว
-- API ต้องเชื่อมฐานด้วย role ที่ไม่ใช่เจ้าของตาราง (เช่น skillwise_app)
-- เพราะเจ้าของตารางข้าม RLS ได้
--
-- วิธีรัน: หลัง schema.sql และ seed.sql
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skillwise_app') THEN
    CREATE ROLE skillwise_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO skillwise_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO skillwise_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO skillwise_app;

CREATE FUNCTION app_current_user_id() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

CREATE FUNCTION app_sensitive_access() RETURNS boolean LANGUAGE sql STABLE AS
$$ SELECT coalesce(current_setting('app.sensitive_access', true), '') = 'on' $$;

-- SECURITY DEFINER: อ่านตาราง membership / case ได้โดยไม่ติด RLS ของตารางอื่นในอนาคต
CREATE FUNCTION app_is_org_member(p_org_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM memberships m
    WHERE m.organization_id = p_org_id
      AND m.user_id = app_current_user_id()
      AND m.status = 'active')
$$;

CREATE FUNCTION app_is_assigned_coach_of_student(p_student_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM case_targets ct
    JOIN cases c ON c.id = ct.case_id
    JOIN coach_assignments ca
      ON ca.coach_user_id = app_current_user_id()
     AND ca.teacher_user_id = c.owner_user_id
     AND (ca.case_id IS NULL OR ca.case_id = c.id)
     AND ca.starts_on <= current_date
     AND (ca.ends_on IS NULL OR ca.ends_on >= current_date)
    WHERE ct.student_id = p_student_id)
$$;

-- students -------------------------------------------------------------------
ALTER TABLE students ENABLE ROW LEVEL SECURITY;

CREATE POLICY students_read ON students FOR SELECT
  USING (app_sensitive_access()
         OR app_is_org_member(organization_id)
         OR app_is_assigned_coach_of_student(id));

-- เพิ่ม/แก้/ลบนักเรียนได้เฉพาะสมาชิกขององค์กรนั้น (สิทธิ์ org.students.manage ตรวจที่ API)
CREATE POLICY students_write ON students FOR ALL
  USING (app_is_org_member(organization_id))
  WITH CHECK (app_is_org_member(organization_id));

-- student_enrollments ----------------------------------------------------------
ALTER TABLE student_enrollments ENABLE ROW LEVEL SECURITY;

CREATE POLICY student_enrollments_read ON student_enrollments FOR SELECT
  USING (app_sensitive_access()
         OR app_is_org_member(organization_id)
         OR app_is_assigned_coach_of_student(student_id));

CREATE POLICY student_enrollments_write ON student_enrollments FOR ALL
  USING (app_is_org_member(organization_id))
  WITH CHECK (app_is_org_member(organization_id));

COMMIT;
