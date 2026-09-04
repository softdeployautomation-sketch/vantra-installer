/**
 * Typed environment configuration with validation.
 * Fails loudly at startup if any required value is missing.
 */

// Load .env from the generator/ directory before any process.env reads happen.
import "dotenv/config";

function required(key: string): string {
  const value = process.env[key];
  if (!value) {
    console.error(`Error: Environment variable ${key} is required but not set.`);
    process.exit(1);
  }
  return value;
}

function number(key: string, defaultValue: number): number {
  const value = process.env[key];
  if (!value) {
    return defaultValue;
  }
  const parsed = parseInt(value, 10);
  if (isNaN(parsed)) {
    console.error(
      `Error: Environment variable ${key}="${value}" is not a valid number.`
    );
    process.exit(1);
  }
  return parsed;
}

export const env = {
  PORT: number("PORT", 4000),
  GENERATOR_SECRET: required("GENERATOR_SECRET"),
  MSI_BUILDER_PATH: required("MSI_BUILDER_PATH"),
  PUBLIC_URL: required("PUBLIC_URL"),
  JOB_TTL_HOURS: number("JOB_TTL_HOURS", 72),
};
