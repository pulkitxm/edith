import { afterEach, describe, expect, test } from "bun:test";
import {
  effectiveAllowance,
  readCeilings,
  validatePlanAllowance,
} from "@/lib/plans";

afterEach(() => {
  delete process.env.LICENSE_STANDARD_MAX_MACHINES_CAP;
  delete process.env.LICENSE_CUSTOM_MAX_MACHINES_CAP;
});

describe("plan ceilings", () => {
  test("defaults both caps to 5", () => {
    expect(readCeilings()).toEqual({
      standardMaxMachinesCap: 5,
      customMaxMachinesCap: 5,
    });
  });

  test("reads caps from the environment", () => {
    process.env.LICENSE_STANDARD_MAX_MACHINES_CAP = "3";
    process.env.LICENSE_CUSTOM_MAX_MACHINES_CAP = "10";

    expect(readCeilings()).toEqual({
      standardMaxMachinesCap: 3,
      customMaxMachinesCap: 10,
    });
  });

  test("rejects non-positive or non-integer caps", () => {
    process.env.LICENSE_STANDARD_MAX_MACHINES_CAP = "0";
    expect(() => readCeilings()).toThrow();

    process.env.LICENSE_STANDARD_MAX_MACHINES_CAP = "2.5";
    expect(() => readCeilings()).toThrow();

    process.env.LICENSE_STANDARD_MAX_MACHINES_CAP = "lots";
    expect(() => readCeilings()).toThrow();
  });
});

describe("plan allowance validation", () => {
  const ceilings = { standardMaxMachinesCap: 5, customMaxMachinesCap: 3 };

  test("accepts catalog plans within the standard cap", () => {
    expect(() =>
      validatePlanAllowance("individual_1", 1, ceilings),
    ).not.toThrow();
    expect(() => validatePlanAllowance("personal_3", 3, ceilings)).not.toThrow();
    expect(() => validatePlanAllowance("power_5", 5, ceilings)).not.toThrow();
  });

  test("throws instead of clamping above the cap", () => {
    expect(() => validatePlanAllowance("power_5", 6, ceilings)).toThrow();
    expect(() => validatePlanAllowance("custom", 4, ceilings)).toThrow();
  });

  test("uses the custom cap for custom allowances", () => {
    expect(() => validatePlanAllowance("custom", 3, ceilings)).not.toThrow();
  });

  test("rejects unknown plans and invalid allowances", () => {
    expect(() => validatePlanAllowance("mystery_9", 1, ceilings)).toThrow();
    expect(() => validatePlanAllowance("personal_3", 0, ceilings)).toThrow();
    expect(() => validatePlanAllowance("personal_3", 1.5, ceilings)).toThrow();
  });
});

describe("effective allowance", () => {
  test("prefers the custom override", () => {
    expect(effectiveAllowance({ customMaxMachines: 4, maxMachines: 3 })).toBe(4);
  });

  test("falls back to the snapshot", () => {
    expect(effectiveAllowance({ customMaxMachines: null, maxMachines: 3 })).toBe(
      3,
    );
  });
});
