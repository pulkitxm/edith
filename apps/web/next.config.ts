import type { NextConfig } from "next";
import { assertRequiredEnv } from "./lib/required-env";

if (process.env.NODE_ENV === "production" || process.env.VERCEL) {
  assertRequiredEnv();
}

const nextConfig: NextConfig = {
  poweredByHeader: false,
};

export default nextConfig;
