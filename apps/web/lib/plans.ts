import { z } from "zod";

export type Plan = {
  id: string;
  name: string;
  provider: string;
  maxMachines: number;
  billingModel: string;
};

const planCatalog: Record<string, Plan> = {
  individual_1: {
    id: "individual_1",
    name: "Individual",
    provider: "lemonsqueezy",
    maxMachines: 1,
    billingModel: "one_time",
  },
  personal_3: {
    id: "personal_3",
    name: "Personal",
    provider: "lemonsqueezy",
    maxMachines: 3,
    billingModel: "one_time",
  },
  power_5: {
    id: "power_5",
    name: "Power",
    provider: "lemonsqueezy",
    maxMachines: 5,
    billingModel: "one_time",
  },
};

export type Ceilings = {
  standardMaxMachinesCap: number;
  customMaxMachinesCap: number;
};

const capSchema = z.coerce.number().int().positive();

function readCap(name: string): number {
  const raw = process.env[name];

  if (raw === undefined || raw === "") {
    return 5;
  }

  return capSchema.parse(raw);
}

export function readCeilings(): Ceilings {
  return {
    standardMaxMachinesCap: readCap("LICENSE_STANDARD_MAX_MACHINES_CAP"),
    customMaxMachinesCap: readCap("LICENSE_CUSTOM_MAX_MACHINES_CAP"),
  };
}

export function getPlan(planId: string): Plan | null {
  return planCatalog[planId] ?? null;
}

export function validatePlanAllowance(
  planId: string,
  allowance: number,
  ceilings: Ceilings,
): void {
  if (!Number.isInteger(allowance) || allowance < 1) {
    throw new Error(`Plan ${planId} allowance must be a positive integer`);
  }

  if (planId === "custom") {
    if (allowance > ceilings.customMaxMachinesCap) {
      throw new Error(
        `Custom allowance ${allowance} exceeds cap ${ceilings.customMaxMachinesCap}`,
      );
    }

    return;
  }

  if (!getPlan(planId)) {
    throw new Error(`Unknown plan ${planId}`);
  }

  if (allowance > ceilings.standardMaxMachinesCap) {
    throw new Error(
      `Plan ${planId} allowance ${allowance} exceeds cap ${ceilings.standardMaxMachinesCap}`,
    );
  }
}

export function effectiveAllowance(license: {
  customMaxMachines: number | null;
  maxMachines: number;
}): number {
  return license.customMaxMachines ?? license.maxMachines;
}
