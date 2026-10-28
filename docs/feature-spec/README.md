# Feature spec จากระบบ Sila5School

spec ชุดนี้เขียนจากการอ่านโค้ด PHP ของ Sila5School ทีละบรรทัด เพื่อให้ทีมหรือ AI ที่ช่วยเขียนโค้ดนำแนวคิดไปสร้างใหม่ใน SkillWise (TypeScript + PostgreSQL) ได้ถูกต้อง

- **ใช้ทำอะไร:** เป็นต้นแบบ**แนวคิด**และ business rule · โค้ด production ของ SkillWise ต้องเขียนใหม่ตาม Context ข้อ 60.5 (ข้อ 60.1, 60.11)
- **ขอบเขต:** ฟีเจอร์ Must + Should ในหัวข้อ 8 ของ `docs/sila5school-study.md`
- **การอ้างอิง:**
  - `path:line` ทุกจุดเป็น path ใน repo เดิม (`RGTCenter/sila5school` commit `88a09c75`)
  - สำเนาโค้ดเก็บในเครื่องที่ `reference/sila5school/` ใช้ path เดียวกัน
  - โฟลเดอร์ `reference/` ไม่ขึ้น GitHub เพราะ repo ต้นทางเป็น private · ขอสำเนาจากทีม
- **ตารางใหม่ที่อ้างในหัวข้อ 9 ของแต่ละไฟล์:** อยู่ใน `docs/database/schema.sql`

## สารบัญ

| # | ไฟล์ | ฟีเจอร์ | ระดับ | ตารางหลักใน SkillWise |
|---|---|---|---|---|
| 01 | [01-identity-login-line.md](01-identity-login-line.md) | Login Google, remember-me, consent, login-as, ผูก LINE | Must | `users`, `user_identities`, `auth_sessions`, `user_consents` |
| 02 | [02-organization-team.md](02-organization-team.md) | สมัครองค์กร, เชิญครู, บทบาทในทีม, ห้องที่ครูดูแล | Must | `organizations`, `memberships`, `invitations`, `role_assignments`, `membership_org_units` |
| 03 | [03-students.md](03-students.md) | บันทึกนักเรียน, import Excel | Must | `students`, `student_enrollments`, `import_jobs` |
| 04 | [04-canvas.md](04-canvas.md) | Canvas 7 ช่อง, สถานะคะแนน, เกณฑ์พร้อมทำแผน | Must | `cases`, `canvases`, `canvas_revisions`, `canvas_feedbacks` |
| 05 | [05-ai-plan-synthesis.md](05-ai-plan-synthesis.md) | AI สังเคราะห์ Canvas เป็นแผน, โควตา | Must | `ai_jobs`, `usage_ledger` |
| 06 | [06-development-plan.md](06-development-plan.md) | แผนพัฒนาศักยภาพ, ส่งตรวจ, PDF | Must · PDF = Should | `development_plan_versions`, `plan_reviews`, `generated_documents` |
| 07 | [07-action-plan.md](07-action-plan.md) | แปลงเป็นแผนลงมือทำ, กิจวัตร, to-do รายสัปดาห์ | Must | `action_plans`, `action_items`, `practice_sessions`, `practice_templates` |
| 08 | [08-practice-log-story.md](08-practice-log-story.md) | บันทึกทำแล้ว/เลื่อน, รูปหลักฐาน, เรื่องราว | Must · การแชร์ = Later | `practice_logs`, `practice_log_*` |
| 09 | [09-outcome-report-dashboard.md](09-outcome-report-dashboard.md) | Timeline รายเด็ก, รายงาน, dashboard | Should | `student_progress_summaries`, view `org_activity_summary` |
| 10 | [10-notification-content.md](10-notification-content.md) | แจ้งเตือน email/LINE, ลิงก์นับคลิก, ข่าวหน้าเว็บ | Should | `notification_*`, `contents` |

## โครงของแต่ละไฟล์

ทุกไฟล์ใช้หัวข้อเดียวกัน อ่านเฉพาะส่วนที่ต้องการได้

1. ฟีเจอร์นี้ทำอะไร
2. ผู้ใช้และสิทธิ์ในระบบเดิม
3. ข้อมูลในระบบเดิม
4. Flow และลำดับสถานะ (mermaid)
5. Business rule พร้อม `path:line`
6. การตรวจข้อมูลขาเข้า
7. Edge case
8. **สิ่งที่ห้ามทำตาม** (bug, ช่องโหว่, tech debt, ของเฉพาะ Sila5School)
9. **แนวทางใน SkillWise:** ตารางใหม่, permission, สิ่งที่ต้องเปลี่ยนตาม Context
10. คำถามที่ยัง OPEN

## วิธีใช้กับ AI ที่ช่วยเขียนโค้ด

ให้ AI อ่านตามลำดับนี้ก่อนเขียนฟีเจอร์ใด ๆ:
1. `CLAUDE.md` หรือ `AGENTS.md`
2. Context ข้อที่เกี่ยวข้อง
3. spec ของฟีเจอร์นั้น
4. `docs/database/README.md`

**ข้อควรระวัง:** หัวข้อ 5–7 บอกว่า "ระบบเดิมทำอะไร" ไม่ใช่ "SkillWise ต้องทำอะไร" · สิ่งที่ SkillWise ต้องทำอยู่ในหัวข้อ 9 และ Context · ถ้าสองส่วนนี้ขัดกัน ให้เชื่อ Context
