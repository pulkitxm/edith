import { describe, expect, test } from "bun:test";
import { attachmentHeader } from "@/lib/http";

describe("attachmentHeader", () => {
  test("passes a plain filename through", () => {
    expect(attachmentHeader("Edith-v1.2.3.dmg")).toBe(
      'attachment; filename="Edith-v1.2.3.dmg"',
    );
  });

  test("neutralizes quotes, backslashes, CR, and LF", () => {
    expect(attachmentHeader('a"b\\c\rd\ne.dmg')).toBe(
      'attachment; filename="a_b_c_d_e.dmg"',
    );
  });

  test("result contains no CR, LF, or unescaped quote", () => {
    const header = attachmentHeader('evil"\r\nSet-Cookie: x=y');
    expect(header).toBe('attachment; filename="evil___Set-Cookie: x=y"');
    expect(header).not.toMatch(/[\r\n]/);
    expect(header.split('"')).toHaveLength(3);
  });
});
