CREATE TABLE "users" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "email" text NOT NULL UNIQUE,
  "name" text,
  "phone" text,
  "created_at" timestamptz DEFAULT now(),
  "updated_at" timestamptz DEFAULT now()
);
ALTER TABLE "licenses" ADD COLUMN "user_id" uuid REFERENCES "users"("id");
INSERT INTO "users" ("email", "name", "phone")
  SELECT lower("email"), max("name"), max("phone")
  FROM "licenses" WHERE "email" IS NOT NULL GROUP BY lower("email");
UPDATE "licenses" SET "user_id" = "users"."id"
  FROM "users" WHERE lower("licenses"."email") = "users"."email";
ALTER TABLE "licenses" DROP COLUMN "name", DROP COLUMN "email", DROP COLUMN "phone";
