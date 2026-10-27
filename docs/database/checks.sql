-- =============================================================================
-- SkillWise — ตรวจว่ากฎในฐานข้อมูลทำงานจริง
-- =============================================================================
-- รันหลัง schema.sql → seed.sql → rls.sql ทุกข้อ (27 ข้อ) ต้องขึ้น NOTICE "OK"
-- ถ้าข้อไหนไม่เป็นตามคาด จะขึ้น ERROR "FAIL ..." แล้วหยุด
-- ไฟล์นี้ ROLLBACK ตอนจบ จึงไม่เปลี่ยนข้อมูลในฐาน
--
-- วิธีรัน: psql -v ON_ERROR_STOP=1 -f checks.sql
-- =============================================================================

BEGIN;

-- 1. แจก seat เกินจำนวนไม่ได้ (pool รายคนมี 1 ที่ ใช้ไปแล้ว)
DO $$ BEGIN
  INSERT INTO seat_assignments (seat_pool_id, user_id)
  VALUES ('d2000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000008');
  RAISE EXCEPTION 'FAIL 1: แจก seat เกินจำนวนได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 1: แจก seat เกินจำนวนไม่ได้';
END $$;

-- 2. หักเครดิตจากงาน AI ที่ล้มเหลวไม่ได้
DO $$ BEGIN
  INSERT INTO usage_ledger (user_id, feature_code, delta, reason, ai_job_id)
  VALUES ('a1000000-0000-4000-8000-000000000004', 'ai.plan_synthesis', -1, 'usage', '71000000-0000-4000-8000-000000000002');
  RAISE EXCEPTION 'FAIL 2: หักเครดิตงานที่ล้มเหลวได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 2: งาน AI ที่ล้มเหลวไม่ถูกหักเครดิต';
END $$;

-- 3. หักเครดิตงานเดียวกันซ้ำไม่ได้
DO $$ BEGIN
  INSERT INTO usage_ledger (user_id, feature_code, delta, reason, ai_job_id)
  VALUES ('a1000000-0000-4000-8000-000000000004', 'ai.plan_synthesis', -1, 'usage', '71000000-0000-4000-8000-000000000003');
  RAISE EXCEPTION 'FAIL 3: หักเครดิตซ้ำได้';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'OK 3: หักเครดิตงานเดียวกันได้ครั้งเดียว';
END $$;

-- 4. ยอดเครดิตคงเหลือคำนวณจาก ledger
DO $$
DECLARE b integer;
BEGIN
  SELECT balance INTO b FROM usage_balances
   WHERE user_id = 'a1000000-0000-4000-8000-000000000004' AND feature_code = 'ai.plan_synthesis';
  IF b <> 2 THEN RAISE EXCEPTION 'FAIL 4: ยอดคงเหลือ % (คาดว่า 2)', b; END IF;
  RAISE NOTICE 'OK 4: เครดิตสังเคราะห์แผนเหลือ 2 (ลองฟรี 1 + โควตา 2 − ใช้ 1)';
END $$;

-- 5. audit log แก้หรือลบไม่ได้
DO $$ BEGIN
  DELETE FROM audit_logs;
  RAISE EXCEPTION 'FAIL 5: ลบ audit log ได้';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK 5: audit log เพิ่มได้อย่างเดียว';
END $$;

-- 6. เวลาบันทึกมาจากระบบ: ส่ง recorded_at ย้อนหลังมาเองไม่มีผล และบันทึกย้อนหลังถูกติดป้าย
DO $$
DECLARE r practice_logs;
BEGIN
  INSERT INTO practice_logs (action_item_id, author_user_id, outcome, happened_on, recorded_at, note)
  VALUES ('84000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000004', 'done',
          (now() AT TIME ZONE 'Asia/Bangkok')::date - 3, now() - interval '3 days', 'ทดสอบ')
  RETURNING * INTO r;
  IF r.recorded_at < now() - interval '1 minute' THEN RAISE EXCEPTION 'FAIL 6: ตั้ง recorded_at เองได้'; END IF;
  IF NOT r.is_backdated THEN RAISE EXCEPTION 'FAIL 6: ไม่ติดป้ายย้อนหลัง'; END IF;
  RAISE NOTICE 'OK 6: recorded_at มาจากระบบ และบันทึกย้อนหลัง 3 วันถูกติดป้าย';
END $$;

-- 7. บันทึกล่วงหน้าไม่ได้
DO $$ BEGIN
  INSERT INTO practice_logs (action_item_id, author_user_id, outcome, happened_on)
  VALUES ('84000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000004', 'done',
          (now() AT TIME ZONE 'Asia/Bangkok')::date + 1);
  RAISE EXCEPTION 'FAIL 7: บันทึกล่วงหน้าได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 7: บันทึกล่วงหน้าไม่ได้';
END $$;

-- 8. แก้บันทึกแล้วประวัติยังอยู่
DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM practice_log_revisions WHERE practice_log_id = '86000000-0000-4000-8000-000000000002';
  IF n <> 2 THEN RAISE EXCEPTION 'FAIL 8: มี revision % แถว (คาดว่า 2)', n; END IF;
  RAISE NOTICE 'OK 8: บันทึกที่แก้ 1 ครั้งมีประวัติ 2 revision';
END $$;

-- 9. ผูกนักเรียนกับห้องขององค์กรอื่นไม่ได้
DO $$ BEGIN
  INSERT INTO org_units (id, organization_id, kind, name)
  VALUES ('b2000000-0000-4000-8000-000000000099', 'b1000000-0000-4000-8000-000000000002', 'group', 'กลุ่มทดสอบ');
  INSERT INTO student_enrollments (student_id, org_unit_id, organization_id, starts_on)
  VALUES ('e1000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000099',
          'b1000000-0000-4000-8000-000000000002', current_date);
  RAISE EXCEPTION 'FAIL 9: ผูกนักเรียนข้ามองค์กรได้';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'OK 9: ผูกนักเรียนกับห้องขององค์กรอื่นไม่ได้';
END $$;

-- 10. นักเรียนอยู่ห้องเดียวกันในช่วงเวลาซ้อนกันไม่ได้
DO $$ BEGIN
  INSERT INTO student_enrollments (student_id, org_unit_id, organization_id, starts_on)
  VALUES ('e1000000-0000-4000-8000-000000000001', 'b2000000-0000-4000-8000-000000000002',
          'b1000000-0000-4000-8000-000000000001', current_date);
  RAISE EXCEPTION 'FAIL 10: ช่วงเวลาซ้อนกันได้';
EXCEPTION WHEN exclusion_violation THEN RAISE NOTICE 'OK 10: ช่วงเวลาในห้องเดียวกันซ้อนกันไม่ได้';
END $$;

-- 11. ไฟล์ที่มีข้อมูลนักเรียนเป็น public ไม่ได้
DO $$ BEGIN
  UPDATE files SET access_level = 'public' WHERE id = '91000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'FAIL 11: เปิดไฟล์ข้อมูลนักเรียนเป็น public ได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 11: ไฟล์ที่มีข้อมูลนักเรียนเป็น public ไม่ได้';
END $$;

-- 12. เนื้อหาขึ้นหน้าสาธารณะโดยไม่ผ่านอนุมัติไม่ได้
DO $$ BEGIN
  UPDATE contents SET status = 'published' WHERE id = '99000000-0000-4000-8000-000000000002';
  RAISE EXCEPTION 'FAIL 12: เผยแพร่โดยไม่อนุมัติได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 12: เผยแพร่เนื้อหาต้องผ่านการอนุมัติ';
END $$;

-- 13. คำตอบ Canvas ต้องเป็นช่องของ Tool version เดียวกัน
DO $$ BEGIN
  INSERT INTO tool_versions (id, tool_id, version) VALUES
    ('f2000000-0000-4000-8000-000000000099', 'f1000000-0000-4000-8000-000000000001', 99);
  INSERT INTO tool_fields (id, tool_version_id, field_key, label, sort_order) VALUES
    ('f3000000-0000-4000-8000-000000000099', 'f2000000-0000-4000-8000-000000000099', 'potential', 'ช่องทดสอบ', 1);
  INSERT INTO canvas_field_values (canvas_revision_id, tool_version_id, tool_field_id, value_text) VALUES
    ('f6000000-0000-4000-8000-000000000004', 'f2000000-0000-4000-8000-000000000001', 'f3000000-0000-4000-8000-000000000099', 'x');
  RAISE EXCEPTION 'FAIL 13: ใส่คำตอบในช่องของ Tool version อื่นได้';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'OK 13: คำตอบต้องตรงกับช่องของ Tool version ที่ Canvas ใช้';
END $$;

-- 14. Canvas revision แก้ทับไม่ได้ (ต้องสร้าง revision ใหม่)
DO $$ BEGIN
  UPDATE canvas_field_values SET value_text = 'แก้ทับ'
   WHERE canvas_revision_id = 'f6000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'FAIL 14: แก้ revision ทับได้';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK 14: Canvas revision แก้ทับไม่ได้';
END $$;

-- 15. บทบาทระดับองค์กรต้องมีองค์กร และบทบาท platform ต้องไม่มีองค์กร
DO $$ BEGIN
  INSERT INTO role_assignments (user_id, role_id, role_scope, organization_id)
  VALUES ('a1000000-0000-4000-8000-000000000007', 'c1000000-0000-4000-8000-000000000013', 'organization', NULL);
  RAISE EXCEPTION 'FAIL 15: มอบบทบาทองค์กรโดยไม่ระบุองค์กรได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 15: บทบาทองค์กรต้องระบุองค์กร';
END $$;

-- 16. ผู้บริหารไม่มีสิทธิ์ดูข้อมูลอ่อนไหว (ข้อ 31)
DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n
  FROM role_assignments ra JOIN role_permissions rp ON rp.role_id = ra.role_id
  JOIN permissions p ON p.code = rp.permission_code
  WHERE ra.user_id = 'a1000000-0000-4000-8000-000000000006' AND ra.revoked_at IS NULL
    AND (p.is_sensitive OR p.code IN ('org.students.view', 'coach.feedback.write'));
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL 16: ผู้บริหารได้สิทธิ์อ่อนไหว % รายการ', n; END IF;
  RAISE NOTICE 'OK 16: บทบาทผู้บริหารเห็นแค่ dashboard ข้อมูลรวม';
END $$;

-- 17–20. Row-Level Security: ทดสอบด้วย role ของแอป ไม่ใช่เจ้าของตาราง
SET LOCAL ROLE skillwise_app;

SELECT set_config('app.user_id', 'a1000000-0000-4000-8000-000000000004', true);  -- ครูในโรงเรียน
DO $$ BEGIN
  IF (SELECT count(*) FROM students) <> 10 THEN RAISE EXCEPTION 'FAIL 17: ครูในองค์กรเห็นนักเรียนไม่ครบ'; END IF;
  RAISE NOTICE 'OK 17: ครูในองค์กรเห็นนักเรียนขององค์กร 10 คน';
END $$;

SELECT set_config('app.user_id', 'a1000000-0000-4000-8000-000000000007', true);  -- ครูอิสระ
DO $$ BEGIN
  IF (SELECT count(*) FROM students) <> 0 THEN RAISE EXCEPTION 'FAIL 18: คนนอกองค์กรเห็นนักเรียน'; END IF;
  RAISE NOTICE 'OK 18: คนนอกองค์กรไม่เห็นนักเรียนเลย';
END $$;

SELECT set_config('app.user_id', 'a1000000-0000-4000-8000-000000000003', true);  -- โค้ช
DO $$ BEGIN
  IF (SELECT count(*) FROM students) <> 3 THEN RAISE EXCEPTION 'FAIL 19: โค้ชเห็นนักเรียนผิดจำนวน'; END IF;
  RAISE NOTICE 'OK 19: โค้ชเห็นเฉพาะนักเรียน 3 คนที่อยู่ใน case ของครูที่ดูแล';
END $$;

SELECT set_config('app.user_id', 'a1000000-0000-4000-8000-000000000003', true);
DO $$ BEGIN
  INSERT INTO students (organization_id, first_name) VALUES ('b1000000-0000-4000-8000-000000000001', 'ทดสอบ');
  RAISE EXCEPTION 'FAIL 20: โค้ชเพิ่มนักเรียนได้';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK 20: โค้ชเพิ่มนักเรียนในองค์กรที่ไม่ได้เป็นสมาชิกไม่ได้';
END $$;

RESET ROLE;

-- 21. view ข้อมูลรวมของผู้บริหารไม่มีคอลัมน์ชื่อคน
DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_name = 'org_activity_summary' AND column_name ~ '(name|student|note|body)';
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL 21: view ข้อมูลรวมมีคอลัมน์รายคน'; END IF;
  RAISE NOTICE 'OK 21: org_activity_summary มีแค่ตัวเลขรวม';
END $$;

-- 22. นัดเดียวกันบันทึก "ทำแล้ว" ซ้ำไม่ได้
DO $$ BEGIN
  INSERT INTO practice_logs (action_item_id, practice_session_id, author_user_id, outcome, happened_on)
  VALUES ('84000000-0000-4000-8000-000000000001', '85000000-0000-4000-8000-000000000001',
          'a1000000-0000-4000-8000-000000000004', 'done', (now() AT TIME ZONE 'Asia/Bangkok')::date - 17);
  RAISE EXCEPTION 'FAIL 22: บันทึกทำแล้วซ้ำในนัดเดียวกันได้';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'OK 22: นัดหนึ่งครั้งมีบันทึกทำแล้วได้แถวเดียว';
END $$;

-- 23. รายการที่ผูกกับบันทึกแก้ทับไม่ได้ ต้องเอาออกแล้วเพิ่มใหม่
DO $$ BEGIN
  UPDATE practice_log_students SET observation = 'แก้ทับ' WHERE id = '86100000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'FAIL 23: แก้ข้อสังเกตทับได้';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK 23: รายการที่ผูกกับบันทึกแก้ทับไม่ได้';
END $$;

-- 24. เอานักเรียนออกจากบันทึกแล้ว ประวัติยังอยู่
DO $$
DECLARE total integer; active integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE removed_at IS NULL) INTO total, active
  FROM practice_log_students
  WHERE practice_log_id = '86000000-0000-4000-8000-000000000002' AND student_id = 'e1000000-0000-4000-8000-000000000003';
  IF total <> 2 OR active <> 1 THEN RAISE EXCEPTION 'FAIL 24: มี % แถว ใช้งานอยู่ % แถว (คาดว่า 2 และ 1)', total, active; END IF;
  RAISE NOTICE 'OK 24: แก้รายการที่ผูกกับบันทึกแล้วประวัติเดิมยังอยู่';
END $$;

-- 25. version ที่เลือกใช้ต้องเป็นของแผนเดียวกัน
DO $$ BEGIN
  INSERT INTO development_plans (id, owner_user_id, title) VALUES
    ('72000000-0000-4000-8000-000000000099', 'a1000000-0000-4000-8000-000000000007', 'แผนทดสอบ');
  INSERT INTO development_plan_versions (id, development_plan_id, version_no, source, created_by) VALUES
    ('73000000-0000-4000-8000-000000000099', '72000000-0000-4000-8000-000000000099', 1, 'teacher', 'a1000000-0000-4000-8000-000000000007');
  UPDATE development_plans SET current_version_id = '73000000-0000-4000-8000-000000000099'
   WHERE id = '72000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'FAIL 25: เลือก version ของแผนอื่นได้';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'OK 25: version ที่เลือกใช้ต้องเป็นของแผนเดียวกัน';
END $$;

-- 26. งานแจ้งเตือนต้องมีผู้รับแบบเดียว (บัญชีผู้ใช้ หรืออีเมลของคนที่ยังไม่มีบัญชี)
DO $$ BEGIN
  INSERT INTO notification_jobs (template_id, channel, dedupe_key, scheduled_for)
  VALUES ('97000000-0000-4000-8000-000000000004', 'email', 'test:no-recipient', now());
  RAISE EXCEPTION 'FAIL 26: สร้างงานแจ้งเตือนที่ไม่มีผู้รับได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 26: งานแจ้งเตือนต้องมีผู้รับ';
END $$;

-- 27. กิจกรรมทำครั้งเดียวต้องระบุวัน
DO $$ BEGIN
  INSERT INTO action_items (action_plan_id, item_type, title)
  VALUES ('83000000-0000-4000-8000-000000000001', 'custom', 'ไม่มีวันและไม่มี RRULE');
  RAISE EXCEPTION 'FAIL 27: สร้างกิจกรรมที่ไม่มีทั้งวันและ RRULE ได้';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK 27: กิจกรรมทำครั้งเดียวต้องระบุวัน';
END $$;

SELECT organization_id, active_members, teachers_with_cases, canvases, active_action_plans, practice_done_30d
FROM org_activity_summary ORDER BY active_members DESC;

ROLLBACK;
