# CLAUDE.md — SkillWise

## อ่านก่อนเริ่มงานทุกครั้ง

1. `docs/SkillWise-Canonical-Context-updated.md` — **source of truth** ของ product และระบบ
   - ป้ายความน่าเชื่อถือ: ข้อ 0 · กฎการทำงาน: ข้อ 52 · สิ่งที่ห้ามทำ: ข้อ 53 · ขั้นตอนก่อนเขียนโค้ด: ข้อ 59
   - Decision log ล่าสุดอยู่ข้อ 60 · Tech stack อยู่ข้อ 60.5 · ผลประชุมครั้งที่ 1 อยู่ข้อ 60.10 · โค้ดอ้างอิงและฐานข้อมูลอยู่ข้อ 60.11
2. `docs/sila5school-study.md` — ผลศึกษาระบบ Sila5School เดิม
   - ใช้ได้เฉพาะ**แนวคิด** ห้ามนำโค้ดเดิมไปใช้เป็นโค้ด production (ข้อ 60.1, 60.11)
   - ร่างฟีเจอร์ Phase 1 อยู่หัวข้อ 8 · คำถามที่ทีมยังต้องตัดสินอยู่หัวข้อ 9
3. `docs/feature-spec/` — spec รายฟีเจอร์จากโค้ดเดิม · หัวข้อ 9 ของแต่ละไฟล์คือแนวทางใน SkillWise
4. `docs/database/` — ร่าง schema PostgreSQL ของ MVP · อ่าน `README.md` ก่อนแก้ schema

สำเนาโค้ด PHP ของ Sila5School อยู่ที่ `reference/sila5school/` **ในเครื่องเท่านั้น** (อยู่ใน `.gitignore`) ห้าม commit, push หรือย้ายไปที่สาธารณะ

ถ้า requirement ใหม่ขัดกับ Context **ห้ามแก้เงียบ ๆ** ให้ชี้ conflict แล้วถามก่อน

## Stack (ข้อ 60.5)

```
monorepo: pnpm + Turborepo
├─ apps/web          Next.js (React) — หน้าบ้านอย่างเดียว ห้ามแตะ DB ห้ามมี business logic
├─ apps/api          NestJS — business logic, สิทธิ์, DB (Prisma + PostgreSQL), AI, LINE, งานเบื้องหลัง, PDF
└─ packages/shared   Zod schema + type ที่ใช้ร่วมกันทั้งสองฝั่ง
```

- TypeScript strict ทั้งระบบ · BullMQ + Redis สำหรับ queue/scheduler
- Login: Passport (Google, LINE) เก็บ session ใน httpOnly cookie · web กับ api อยู่โดเมนเดียวกันผ่าน reverse proxy
- Test: Vitest + Supertest + Playwright · CI ต้องผ่าน typecheck, lint และ test ก่อน merge
- ยัง OPEN: Hosting, AI Provider, Payment Gateway

## กฎที่ห้ามพลาด

**ความปลอดภัย**
- ทุก endpoint ต้องประกาศสิทธิ์ที่ใช้และตรวจด้วย guard · ค่าเริ่มต้นคือปฏิเสธ
- ตรวจสิทธิ์ที่ API เสมอ หน้าบ้านซ่อนเมนูได้แต่ไม่นับเป็นการกันสิทธิ์
- secret อยู่ฝั่ง server เท่านั้น · อัปเดต dependency ทันทีเมื่อมี security advisory

**ข้อมูลส่วนบุคคล** (ข้อ 31, 60.2, 60.3, 60.7)
- ข้อมูลนักเรียนเป็นของผู้เยาว์: เห็นได้เฉพาะบุคลากรในองค์กร, โค้ชที่ดูแล case และแอดมินที่มีสิทธิ์ (บันทึก audit log ทุกครั้งที่เปิดดู)
- **ตัดชื่อจริงออกก่อนส่งข้อมูลให้ AI ทุกครั้ง** (pseudonymize) แล้วแปลงกลับตอนแสดงผล
- Reflection และ Coach Feedback เป็นส่วนตัวโดยค่าเริ่มต้น · ผู้บริหารเห็นแค่ข้อมูลรวม · ครูเลือกแชร์เองรายชิ้น
- ไม่มีอะไรขึ้นหน้าสาธารณะได้โดยไม่ผ่านการอนุมัติ · ไฟล์เป็น private โดยค่าเริ่มต้น

**ขอบเขต**
- รายการฟีเจอร์ Phase 1 ยังไม่ final (ข้อ 50 #30) อย่าสร้างฟีเจอร์นอกรายการที่ตกลงแล้ว
- ห้าม hard-code 7 กิจวัตร, โครงสร้างโรงเรียนไทย, แพ็กเกจ subscription หรือประเภท Tool (ข้อ 47, 53)
- AI เป็นผู้ช่วย ไม่ใช่ผู้ตัดสิน (ข้อ 12)

## การเขียนเอกสาร

- ห้ามใส่ path เฉพาะเครื่อง (ทีมทำงานหลายเครื่อง) · path ภายใน repo ใช้ได้
- เน้นเรื่องระบบ ไม่ต้องใส่ชื่อคนหรือว่าใครพูดอะไร
- เมื่อทีมตัดสินเรื่องใหม่ ให้บันทึกลง Context ข้อ 60 พร้อมวันที่และป้าย ([CONFIRMED] / [DIRECTION] / [OPEN])
- หลังแก้โค้ดทุกครั้ง สรุปตามข้อ 59 ข้อ 10: สิ่งที่เปลี่ยน, business rule ที่ใช้, ไฟล์ที่แก้, migration/config ที่ต้องทำ, open issue ที่เหลือ
